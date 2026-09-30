import CryptoKit
import Foundation

/// NTSTATUS values FileCat handles specially.
enum NTStatus {
    static let success: UInt32 = 0x0000_0000
    static let pending: UInt32 = 0x0000_0103
    static let noMoreFiles: UInt32 = 0x8000_0006
    static let bufferOverflow: UInt32 = 0x8000_0005
    static let moreProcessingRequired: UInt32 = 0xC000_0016
    static let endOfFile: UInt32 = 0xC000_0011
    static let noSuchFile: UInt32 = 0xC000_000F
    static let invalidParameter: UInt32 = 0xC000_000D
    static let accessDenied: UInt32 = 0xC000_0022
    static let objectNameNotFound: UInt32 = 0xC000_0034
    static let objectNameCollision: UInt32 = 0xC000_0035
    static let objectPathNotFound: UInt32 = 0xC000_003A
    static let sharingViolation: UInt32 = 0xC000_0043
    static let logonFailure: UInt32 = 0xC000_006D
    static let accountRestriction: UInt32 = 0xC000_006E
    static let passwordExpired: UInt32 = 0xC000_0071
    static let accountDisabled: UInt32 = 0xC000_0072
    static let diskFull: UInt32 = 0xC000_007F
    static let fileIsADirectory: UInt32 = 0xC000_00BA
    static let notSupported: UInt32 = 0xC000_00BB
    static let badNetworkName: UInt32 = 0xC000_00CC
    static let directoryNotEmpty: UInt32 = 0xC000_0101
    static let notADirectory: UInt32 = 0xC000_0103
    static let cannotDelete: UInt32 = 0xC000_0121
    static let userSessionDeleted: UInt32 = 0xC000_0203
    static let networkSessionExpired: UInt32 = 0xC000_035C
    static let accountLockedOut: UInt32 = 0xC000_0234

    static func error(_ status: UInt32, name: String) -> RemoteError {
        switch status {
        case logonFailure, accountRestriction, passwordExpired, accountDisabled, accountLockedOut:
            .authenticationFailed
        case accessDenied, cannotDelete:
            .accessDenied
        case objectNameNotFound, objectPathNotFound, noSuchFile, badNetworkName:
            .notFound(name)
        case objectNameCollision:
            .alreadyExists(name)
        case directoryNotEmpty:
            .folderNotEmpty(name)
        case sharingViolation:
            .unsupported("“\(name)” is in use on the server.")
        case diskFull:
            .unsupported("The server is out of space.")
        case userSessionDeleted, networkSessionExpired:
            .connectionFailed("The session expired.")
        default:
            .protocolError(String(format: "SMB status 0x%08X.", status))
        }
    }
}

/// One SMB2/SMB3 connection: negotiate, NTLMv2 session setup, signing, and the file commands.
/// Requests can run concurrently; responses are matched to them by message ID.
actor SMB2Client {
    enum Command: UInt16 {
        case negotiate = 0, sessionSetup = 1, logoff = 2, treeConnect = 3, treeDisconnect = 4
        case create = 5, close = 6, read = 8, write = 9, ioctl = 0x0B, echo = 0x0D
        case queryDirectory = 0x0E, queryInfo = 0x10, setInfo = 0x11
    }

    struct Message {
        let data: Data
        var reader: ByteReader { ByteReader(data) }
        var status: UInt32 { (try? reader.u32(at: 8)) ?? 0 }
        var sessionID: UInt64 { (try? reader.u64(at: 40)) ?? 0 }
        var treeID: UInt32 { (try? reader.u32(at: 36)) ?? 0 }
    }

    struct FileID: Sendable {
        let raw: Data
    }

    struct CreateResult {
        let fileID: FileID
        let size: Int64
        let isDirectory: Bool
        let modified: Date?
    }

    struct DirectoryEntry {
        let name: String
        let isDirectory: Bool
        let isHidden: Bool
        let size: Int64
        let modified: Date?
    }

    let host: String
    private let connection: TCPConnection
    private(set) var dialect: UInt16 = 0
    private(set) var maxReadSize = 65_536
    private(set) var maxWriteSize = 65_536
    private(set) var maxTransactSize = 65_536
    private var supportsMultiCredit = false
    private var serverRequiresSigning = false
    private var signingKey: Data?
    private var sessionID: UInt64 = 0
    private var nextMessageID: UInt64 = 0
    private var credits = 1
    private var creditWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: [UInt64: CheckedContinuation<Message, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?
    private var failure: Error?
    private var preauthHash = Data(count: 64)

    private init(host: String, port: UInt16) {
        self.host = host
        connection = TCPConnection(host: host, port: port)
    }

    /// Connects and signs in. An empty user name and password signs in anonymously.
    static func connect(host: String, port: UInt16, user: String, password: String, domain: String) async throws -> SMB2Client {
        let client = SMB2Client(host: host, port: port)
        do {
            try await client.start()
            try await client.negotiate()
            try await client.authenticate(user: user, password: password, domain: domain)
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    private func start() async throws {
        try await connection.open()
        let connection = connection
        receiveLoop = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let header = try await connection.receive(exactly: 4)
                    let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                    let message = try await connection.receive(exactly: length)
                    await self?.deliver(message)
                }
            } catch {
                await self?.fail(error)
            }
        }
    }

    func close() async {
        receiveLoop?.cancel()
        connection.close()
        fail(RemoteError.connectionFailed("The connection was closed."))
    }

    var isAlive: Bool { failure == nil }

    // MARK: Sending and receiving

    private func deliver(_ data: Data) {
        let message = Message(data: data)
        let reader = message.reader
        guard let protocolID = try? reader.u32(at: 0) else { return }
        guard protocolID == 0x424D_53FE else {
            if protocolID == 0x424D_53FD {
                fail(RemoteError.unsupported("The server encrypts all traffic, which FileCat doesn't support yet. Turn off “Require encryption” for this share."))
            }
            return
        }
        let granted = Int((try? reader.u16(at: 14)) ?? 0)
        if granted > 0 {
            credits += granted
            let waiters = creditWaiters
            creditWaiters = []
            waiters.forEach { $0.resume() }
        }
        let flags = (try? reader.u32(at: 16)) ?? 0
        let messageID = (try? reader.u64(at: 24)) ?? 0
        // An interim "pending" reply: the real one follows later with the same ID.
        if message.status == NTStatus.pending, flags & 0x2 != 0 { return }
        pending.removeValue(forKey: messageID)?.resume(returning: message)
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
        let waiters = creditWaiters
        creditWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Sends a request and waits for its response. `payloadSize` sets the credit charge for large
    /// reads and writes.
    private func send(_ command: Command, body: Data, treeID: UInt32 = 0, payloadSize: Int = 0, sign: Bool? = nil) async throws -> Message {
        if let failure { throw failure }
        let charge = supportsMultiCredit ? max(1, (payloadSize - 1) / 65_536 + 1) : 1
        while credits < charge {
            await withCheckedContinuation { creditWaiters.append($0) }
            if let failure { throw failure }
        }
        credits -= charge
        let messageID = nextMessageID
        nextMessageID += UInt64(charge)

        let shouldSign = sign ?? (signingKey != nil && serverRequiresSigning)
        var writer = ByteWriter()
        writer.bytes([0xFE, 0x53, 0x4D, 0x42])
        writer.u16(64)
        writer.u16(dialect >= 0x0210 ? UInt16(charge) : 0)
        writer.u32(0) // Channel sequence / status
        writer.u16(command.rawValue)
        writer.u16(256) // Credits requested
        writer.u32(shouldSign ? 0x0000_0008 : 0)
        writer.u32(0) // Next command
        writer.u64(messageID)
        writer.u32(0xFEFF) // Process ID
        writer.u32(treeID)
        writer.u64(sessionID)
        writer.zeros(16) // Signature
        writer.bytes(body)
        var message = writer.data
        if shouldSign, let signingKey {
            message.replaceSubrange(48..<64, with: signature(of: message, key: signingKey))
        }
        if command == .negotiate || command == .sessionSetup {
            updatePreauthHash(message)
        }

        var frame = ByteWriter()
        frame.u32be(UInt32(message.count))
        frame.bytes(message)
        let data = frame.data

        let timeout = command == .read || command == .write ? 120 : 30
        return try await withCheckedThrowingContinuation { continuation in
            pending[messageID] = continuation
            Task {
                do {
                    try await connection.send(data)
                } catch {
                    self.resolve(messageID, with: error)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.resolve(messageID, with: RemoteError.timedOut)
            }
        }
    }

    private func resolve(_ messageID: UInt64, with error: Error) {
        guard let continuation = pending.removeValue(forKey: messageID) else { return }
        continuation.resume(throwing: error)
        if case RemoteError.timedOut = error {
            // The stream is out of step now; drop the connection so the next request reconnects.
            receiveLoop?.cancel()
            connection.close()
            fail(error)
        }
    }

    private func signature(of message: Data, key: Data) -> Data {
        if dialect >= 0x0300 {
            return aesCMAC(key: key, message: message)
        }
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac).prefix(16)
    }

    private func updatePreauthHash(_ message: Data) {
        guard dialect == 0 || dialect == 0x0311 else { return }
        preauthHash = Data(SHA512.hash(data: preauthHash + message))
    }

    private func check(_ message: Message, name: String, allowing allowed: Set<UInt32> = []) throws {
        let status = message.status
        guard status == NTStatus.success || allowed.contains(status) else {
            throw NTStatus.error(status, name: name)
        }
    }

    // MARK: Session

    private func negotiate() async throws {
        var body = ByteWriter()
        let dialects: [UInt16] = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311]
        body.u16(36)
        body.u16(UInt16(dialects.count))
        body.u16(0x0001) // Signing enabled
        body.u16(0)
        body.u32(0x0000_0004) // Large MTU
        body.bytes(randomBytes(16)) // Client GUID
        let contextOffsetPosition = body.count
        body.u32(0) // Negotiate context offset, filled in below
        body.u16(1) // Context count
        body.u16(0)
        for dialect in dialects { body.u16(dialect) }
        // Contexts start 8-byte aligned, measured from the start of the SMB2 header.
        while (64 + body.count) % 8 != 0 { body.u8(0) }
        body.set32(UInt32(64 + body.count), at: contextOffsetPosition)
        // Pre-authentication integrity: SHA-512 with a random salt.
        body.u16(0x0001)
        body.u16(38)
        body.u32(0)
        body.u16(1)
        body.u16(32)
        body.u16(0x0001)
        body.bytes(randomBytes(32))

        let response = try await send(.negotiate, body: body.data, sign: false)
        try check(response, name: host)
        let reader = response.reader
        dialect = try reader.u16(at: 68)
        updatePreauthHash(response.data)
        let securityMode = try reader.u16(at: 66)
        serverRequiresSigning = securityMode & 0x0002 != 0
        let capabilities = try reader.u32(at: 88)
        supportsMultiCredit = dialect >= 0x0210 && capabilities & 0x0000_0004 != 0
        maxTransactSize = Int(try reader.u32(at: 92))
        maxReadSize = Int(try reader.u32(at: 96))
        maxWriteSize = Int(try reader.u32(at: 100))
        guard [0x0202, 0x0210, 0x0300, 0x0302, 0x0311].contains(dialect) else {
            throw RemoteError.unsupported("The server only supports SMB 1, which is outdated and insecure. Enable SMB 2 or later on the server.")
        }
    }

    private func authenticate(user: String, password: String, domain: String) async throws {
        let first = try await sessionSetup(SPNEGO.initialToken(NTLM.negotiateMessage()))
        try check(first, name: host, allowing: [NTStatus.moreProcessingRequired])
        sessionID = first.sessionID
        guard let challengeData = SPNEGO.extractNTLM(try securityBuffer(of: first)) else {
            throw RemoteError.protocolError("The server didn't offer NTLM sign-in.")
        }
        let challenge = try NTLM.Challenge(challengeData)
        let authentication = NTLM.authenticateMessage(challenge: challenge, user: user, password: password, domain: domain)
        let final = try await sessionSetup(SPNEGO.responseToken(authentication.message))
        try check(final, name: host)

        let sessionFlags = try final.reader.u16(at: 66)
        if sessionFlags & 0x0004 != 0 {
            throw RemoteError.unsupported("The server encrypts all traffic, which FileCat doesn't support yet. Turn off “Require encryption” on the server.")
        }
        let isGuestOrAnonymous = sessionFlags & 0x0003 != 0
        guard !isGuestOrAnonymous else { return }
        let sessionKey = authentication.sessionKey
        switch dialect {
        case 0x0300, 0x0302:
            signingKey = smbKDF(key: sessionKey, label: Data("SMB2AESCMAC\0".utf8), context: Data("SmbSign\0".utf8))
        case 0x0311:
            signingKey = smbKDF(key: sessionKey, label: Data("SMBSigningKey\0".utf8), context: preauthHash)
        default:
            signingKey = sessionKey
        }
    }

    private func sessionSetup(_ token: Data) async throws -> Message {
        var body = ByteWriter()
        body.u16(25)
        body.u8(0)
        body.u8(0x01) // Signing enabled
        body.u32(0)
        body.u32(0)
        body.u16(64 + 24)
        body.u16(UInt16(token.count))
        body.u64(0)
        body.bytes(token)
        let response = try await send(.sessionSetup, body: body.data, sign: false)
        if response.status == NTStatus.moreProcessingRequired {
            updatePreauthHash(response.data)
        }
        return response
    }

    private func securityBuffer(of message: Message) throws -> Data {
        let reader = message.reader
        let offset = Int(try reader.u16(at: 68))
        let length = Int(try reader.u16(at: 70))
        return try reader.bytes(at: offset, count: length)
    }

    func logoff() async {
        _ = try? await send(.logoff, body: Data([4, 0, 0, 0]))
    }

    // MARK: Trees

    /// Connects to a share and returns its tree ID.
    func treeConnect(share: String) async throws -> UInt32 {
        let path = "\\\\\(host)\\\(share)".utf16LittleEndian
        var body = ByteWriter()
        body.u16(9)
        body.u16(0)
        body.u16(64 + 8)
        body.u16(UInt16(path.count))
        body.bytes(path)
        let response = try await send(.treeConnect, body: body.data)
        try check(response, name: share)
        let shareFlags = try response.reader.u32(at: 68)
        if shareFlags & 0x0000_8000 != 0 {
            throw RemoteError.unsupported("“\(share)” requires encryption, which FileCat doesn't support yet. Turn off “Encrypt data access” for this share.")
        }
        return response.treeID
    }

    func treeDisconnect(_ treeID: UInt32) async {
        _ = try? await send(.treeDisconnect, body: Data([4, 0, 0, 0]), treeID: treeID)
    }

    // MARK: Files

    struct Access {
        static let readData: UInt32 = 0x0000_0001
        static let listDirectory: UInt32 = 0x0000_0001
        static let writeData: UInt32 = 0x0000_0002
        static let appendData: UInt32 = 0x0000_0004
        static let readAttributes: UInt32 = 0x0000_0080
        static let writeAttributes: UInt32 = 0x0000_0100
        static let delete: UInt32 = 0x0001_0000
        static let readControl: UInt32 = 0x0002_0000
        static let synchronize: UInt32 = 0x0010_0000
        static let genericRead: UInt32 = 0x8000_0000
        static let genericWrite: UInt32 = 0x4000_0000
        static let pipe: UInt32 = 0x0012_019F
    }

    enum Disposition: UInt32 {
        case open = 1, create = 2, overwriteIf = 5
    }

    struct Options {
        static let directory: UInt32 = 0x0000_0001
        static let nonDirectory: UInt32 = 0x0000_0040
        static let deleteOnClose: UInt32 = 0x0000_1000
    }

    /// Opens or creates `path` (backslash-separated, relative to the share root).
    func create(tree: UInt32, path: String, access: UInt32, disposition: Disposition, options: UInt32, attributes: UInt32 = 0) async throws -> CreateResult {
        let name = path.utf16LittleEndian
        var body = ByteWriter()
        body.u16(57)
        body.u8(0)
        body.u8(0) // No oplock
        body.u32(2) // Impersonation
        body.u64(0)
        body.u64(0)
        body.u32(access)
        body.u32(attributes)
        body.u32(0x0000_0007) // Share read, write and delete
        body.u32(disposition.rawValue)
        body.u32(options)
        body.u16(64 + 56)
        body.u16(UInt16(name.count))
        body.u32(0)
        body.u32(0)
        body.bytes(name.isEmpty ? Data([0]) : name)
        let response = try await send(.create, body: body.data, treeID: tree)
        try check(response, name: path.split(separator: "\\").last.map(String.init) ?? path)
        let reader = response.reader
        let attributes = try reader.u32(at: 120)
        return CreateResult(
            fileID: FileID(raw: try reader.bytes(at: 128, count: 16)),
            size: Int64(try reader.u64(at: 112)),
            isDirectory: attributes & 0x10 != 0,
            modified: Self.date(fromFileTime: try reader.u64(at: 88))
        )
    }

    func close(tree: UInt32, file: FileID) async {
        var body = ByteWriter()
        body.u16(24)
        body.u16(0)
        body.u32(0)
        body.bytes(file.raw)
        _ = try? await send(.close, body: body.data, treeID: tree)
    }

    func queryDirectory(tree: UInt32, file: FileID) async throws -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        var restart = true
        let pattern = "*".utf16LittleEndian
        let bufferSize = min(65_536, maxTransactSize)
        while true {
            var body = ByteWriter()
            body.u16(33)
            body.u8(0x01) // FileDirectoryInformation
            body.u8(restart ? 0x01 : 0x00)
            body.u32(0)
            body.bytes(file.raw)
            body.u16(64 + 32)
            body.u16(UInt16(pattern.count))
            body.u32(UInt32(bufferSize))
            body.bytes(pattern)
            restart = false
            let response = try await send(.queryDirectory, body: body.data, treeID: tree, payloadSize: bufferSize)
            if response.status == NTStatus.noMoreFiles { break }
            try check(response, name: "folder")
            let reader = response.reader
            let offset = Int(try reader.u16(at: 66))
            let length = Int(try reader.u32(at: 68))
            let buffer = ByteReader(try reader.bytes(at: offset, count: length))
            var position = 0
            while true {
                let next = Int(try buffer.u32(at: position))
                let nameLength = Int(try buffer.u32(at: position + 60))
                let name = String(utf16LittleEndian: try buffer.bytes(at: position + 64, count: nameLength))
                let attributes = try buffer.u32(at: position + 56)
                if name != "." && name != ".." {
                    entries.append(DirectoryEntry(
                        name: name,
                        isDirectory: attributes & 0x10 != 0,
                        isHidden: attributes & 0x2 != 0,
                        size: Int64(try buffer.u64(at: position + 40)),
                        modified: Self.date(fromFileTime: try buffer.u64(at: position + 24))
                    ))
                }
                if next == 0 { break }
                position += next
            }
        }
        return entries
    }

    /// Reads up to `length` bytes; returns an empty result at the end of the file.
    func read(tree: UInt32, file: FileID, offset: Int64, length: Int) async throws -> Data {
        var body = ByteWriter()
        body.u16(49)
        body.u8(0x50)
        body.u8(0)
        body.u32(UInt32(length))
        body.u64(UInt64(offset))
        body.bytes(file.raw)
        body.u32(0)
        body.u32(0)
        body.u32(0)
        body.u16(0)
        body.u16(0)
        body.u8(0)
        let response = try await send(.read, body: body.data, treeID: tree, payloadSize: length)
        if response.status == NTStatus.endOfFile { return Data() }
        try check(response, name: "file")
        let reader = response.reader
        let dataOffset = Int(try reader.u8(at: 66))
        let dataLength = Int(try reader.u32(at: 68))
        return try reader.bytes(at: dataOffset, count: dataLength)
    }

    func write(tree: UInt32, file: FileID, offset: Int64, data: Data) async throws -> Int {
        var body = ByteWriter()
        body.u16(49)
        body.u16(64 + 48)
        body.u32(UInt32(data.count))
        body.u64(UInt64(offset))
        body.bytes(file.raw)
        body.u32(0)
        body.u32(0)
        body.u16(0)
        body.u16(0)
        body.u32(0)
        body.bytes(data)
        let response = try await send(.write, body: body.data, treeID: tree, payloadSize: data.count)
        try check(response, name: "file")
        return Int(try response.reader.u32(at: 68))
    }

    /// Renames or moves an open file within the share.
    func rename(tree: UInt32, file: FileID, to path: String) async throws {
        let name = path.utf16LittleEndian
        var info = ByteWriter()
        info.u8(0) // Don't replace
        info.zeros(7)
        info.u64(0)
        info.u32(UInt32(name.count))
        info.bytes(name)
        try await setInfo(tree: tree, file: file, infoClass: 10, buffer: info.data, name: path)
    }

    private func setInfo(tree: UInt32, file: FileID, infoClass: UInt8, buffer: Data, name: String) async throws {
        var body = ByteWriter()
        body.u16(33)
        body.u8(1) // File information
        body.u8(infoClass)
        body.u32(UInt32(buffer.count))
        body.u16(64 + 32)
        body.u16(0)
        body.u32(0)
        body.bytes(file.raw)
        body.bytes(buffer)
        let response = try await send(.setInfo, body: body.data, treeID: tree)
        try check(response, name: name.split(separator: "\\").last.map(String.init) ?? name)
    }

    /// Sends `input` to a named pipe and returns the reply (FSCTL_PIPE_TRANSCEIVE).
    func transceive(tree: UInt32, file: FileID, input: Data) async throws -> Data {
        let maxOutput = min(65_536, maxTransactSize)
        var body = ByteWriter()
        body.u16(57)
        body.u16(0)
        body.u32(0x0011_C017)
        body.bytes(file.raw)
        body.u32(64 + 56)
        body.u32(UInt32(input.count))
        body.u32(0)
        body.u32(0)
        body.u32(0)
        body.u32(UInt32(maxOutput))
        body.u32(1) // Is FSCTL
        body.u32(0)
        body.bytes(input)
        let response = try await send(.ioctl, body: body.data, treeID: tree, payloadSize: max(input.count, maxOutput))
        try check(response, name: "pipe", allowing: [NTStatus.bufferOverflow])
        let reader = response.reader
        let outputOffset = Int(try reader.u32(at: 96))
        let outputCount = Int(try reader.u32(at: 100))
        var output = try reader.bytes(at: outputOffset, count: outputCount)
        if response.status == NTStatus.bufferOverflow {
            // The rest of the reply waits in the pipe.
            while true {
                let chunk = try await read(tree: tree, file: file, offset: 0, length: maxOutput)
                output.append(chunk)
                if chunk.count < maxOutput { break }
            }
        }
        return output
    }

    static func date(fromFileTime value: UInt64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 10_000_000 - 11_644_473_600)
    }

    /// The largest read or write that fits the server's limits and the credits we hold.
    func chunkSize(forWriting: Bool) -> Int {
        let limit = forWriting ? maxWriteSize : maxReadSize
        guard supportsMultiCredit else { return min(limit, 65_536) }
        return min(limit, 1_048_576)
    }
}
