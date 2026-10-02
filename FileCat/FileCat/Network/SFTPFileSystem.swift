import CryptoKit
import Foundation

/// Files over SFTP. The source's path is the folder to start in: empty for the home folder,
/// relative to it, or absolute.
actor SFTPFileSystem: RemoteFileSystem {
    private let source: NetworkSource
    private let password: String
    private let key: Curve25519.Signing.PrivateKey?
    private var session: SFTPSession?
    private var connecting: Task<(SFTPSession, String), Error>?
    /// The start folder as an absolute path on the server.
    private var root = "/"

    private init(source: NetworkSource, password: String, key: Curve25519.Signing.PrivateKey?) {
        self.source = source
        self.password = password
        self.key = key
    }

    /// Signs in with FileCat's own key (`SSHClientKey`) when the server accepts it, otherwise
    /// with the password.
    static func connect(source: NetworkSource, password: String, key: Curve25519.Signing.PrivateKey? = SSHClientKey.load()) async throws -> any RemoteFileSystem {
        guard !source.username.isEmpty else {
            throw RemoteError.unsupported("Enter your user name on the server.")
        }
        let fileSystem = SFTPFileSystem(source: source, password: password, key: key)
        _ = try await fileSystem.list("/")
        return fileSystem
    }

    // MARK: Connection

    private func connectedSession() async throws -> SFTPSession {
        if let session, session.isAlive { return session }
        if let connecting { return try await connecting.value.0 }
        let task = Task { [source, password, key] in
            let session = try await SFTPSession.open(source: source, password: password, key: key)
            var start = source.path.trimmingCharacters(in: .whitespaces)
            if start.isEmpty || start == "~" {
                start = "."
            } else if start.hasPrefix("~/") {
                start = String(start.dropFirst(2))
            }
            return (session, try await session.realPath(start))
        }
        connecting = task
        defer { connecting = nil }
        let (session, root) = try await task.value
        self.session = session
        self.root = root
        return session
    }

    /// Runs `body` with a live session, reconnecting once if the connection dropped.
    private func withSession<T>(_ body: (SFTPSession) async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            let session = try await connectedSession()
            do {
                return try await body(session)
            } catch let error as RemoteError where attempt == 0 && !session.isAlive {
                switch error {
                case .connectionFailed, .timedOut:
                    self.session = nil
                    continue
                default:
                    throw error
                }
            }
        }
        throw RemoteError.connectionFailed("")
    }

    private func serverPath(_ path: String) -> String {
        let components = RemotePath.components(of: path)
        return components.isEmpty ? root : RemotePath.join(root, components.joined(separator: "/"))
    }

    // MARK: RemoteFileSystem

    func list(_ path: String) async throws -> [RemoteEntry] {
        try await entries(path).filter { !$0.name.hasPrefix(".") }
    }

    /// Everything in a folder, hidden files included.
    private func entries(_ path: String) async throws -> [RemoteEntry] {
        let full = serverPath(path)
        return try await withSession { session in
            let items = try await session.list(full, name: path)
            var entries: [RemoteEntry] = []
            var links: [String] = []
            for item in items where item.name != "." && item.name != ".." {
                if item.attributes.isLink {
                    links.append(item.name)
                } else {
                    entries.append(Self.entry(item.name, item.attributes))
                }
            }
            // Symbolic links: show what they point to. Broken ones are left out.
            try await withThrowingTaskGroup(of: RemoteEntry?.self) { group in
                for name in links {
                    group.addTask {
                        guard let target = try? await session.stat(RemotePath.join(full, name), name: name) else { return nil }
                        return Self.entry(name, target)
                    }
                }
                for try await entry in group {
                    if let entry { entries.append(entry) }
                }
            }
            return entries
        }
    }

    private static func entry(_ name: String, _ attributes: SFTPSession.Attributes) -> RemoteEntry {
        RemoteEntry(
            name: name, isDirectory: attributes.isDirectory,
            size: attributes.isDirectory ? nil : attributes.size.map { Int64(clamping: $0) },
            modified: attributes.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        let full = serverPath(path)
        return try await withSession { session in
            let handle = try await session.open(full, name: path, flags: SFTPSession.OpenFlags.read)
            do {
                var result = Data()
                try await session.readPipelined(handle, name: path, from: offset, length: Int64(length)) { result.append($0) }
                await session.close(handle)
                return result
            } catch {
                await session.close(handle)
                throw error
            }
        }
    }

    func download(_ path: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let full = serverPath(path)
        try await withSession { session in
            let handle = try await session.open(full, name: path, flags: SFTPSession.OpenFlags.read)
            do {
                FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
                let file = try FileHandle(forWritingTo: destination)
                defer { try? file.close() }
                var written: Int64 = 0
                try await session.readPipelined(handle, name: path, from: 0, length: nil) { data in
                    try file.write(contentsOf: data)
                    written += Int64(data.count)
                    progress(written)
                }
                await session.close(handle)
            } catch {
                await session.close(handle)
                throw error
            }
        }
    }

    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let full = serverPath(path)
        try await withSession { session in
            let handle = try await session.open(
                full, name: path,
                flags: SFTPSession.OpenFlags.write | SFTPSession.OpenFlags.create | SFTPSession.OpenFlags.truncate
            )
            var writes: [(task: Task<Void, Error>, end: Int64)] = []
            do {
                let file = try FileHandle(forReadingFrom: source)
                defer { try? file.close() }
                // Keep several writes in flight; each says where its data goes.
                let depth = max(4, min(64, (2 * 1024 * 1024) / session.maxWrite))
                var offset: Int64 = 0
                while let data = try file.read(upToCount: session.maxWrite), !data.isEmpty {
                    try Task.checkCancellation()
                    let start = offset
                    writes.append((Task { try await session.write(handle, name: path, offset: start, data: data) }, start + Int64(data.count)))
                    offset += Int64(data.count)
                    if writes.count >= depth {
                        let first = writes.removeFirst()
                        try await first.task.value
                        progress(first.end)
                    }
                }
                for write in writes {
                    try await write.task.value
                    progress(write.end)
                }
                try await session.close(handle, name: path)
            } catch {
                writes.forEach { $0.task.cancel() }
                await session.close(handle)
                throw error
            }
        }
    }

    func createFolder(_ path: String) async throws {
        let full = serverPath(path)
        try await withSession { session in
            do {
                try await session.simple(SFTPSession.Request.makeDirectory, full, name: path) { $0.u32be(0) }
            } catch RemoteError.protocolError(let message) {
                // Servers report an existing folder as a plain failure.
                if (try? await session.stat(full, name: path)) != nil {
                    throw RemoteError.alreadyExists(RemotePath.name(of: path))
                }
                throw RemoteError.protocolError(message)
            }
        }
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        let full = serverPath(path)
        if isDirectory {
            for entry in try await entries(path) {
                try await delete(RemotePath.join(path, entry.name), isDirectory: entry.isDirectory)
            }
            try await withSession { session in
                try await session.simple(SFTPSession.Request.removeDirectory, full, name: path)
            }
        } else {
            try await withSession { session in
                try await session.simple(SFTPSession.Request.remove, full, name: path)
            }
        }
    }

    func move(_ path: String, to newPath: String) async throws {
        let from = serverPath(path)
        let to = serverPath(newPath)
        try await withSession { session in
            do {
                try await session.simple(SFTPSession.Request.rename, from, name: path) { $0.sshString(to) }
            } catch RemoteError.protocolError(let message) {
                if (try? await session.stat(to, name: newPath)) != nil {
                    throw RemoteError.alreadyExists(RemotePath.name(of: newPath))
                }
                throw RemoteError.protocolError(message)
            }
        }
    }

    func close() async {
        if let session { await session.ssh.close() }
        session = nil
    }
}

/// SFTP version 3 (draft-ietf-secsh-filexfer-02), which OpenSSH and nearly every server speak,
/// over an SSH channel. Requests can overlap; replies are matched up by their ID.
final class SFTPSession: @unchecked Sendable {
    enum Request {
        static let initialize: UInt8 = 1
        static let open: UInt8 = 3
        static let close: UInt8 = 4
        static let read: UInt8 = 5
        static let write: UInt8 = 6
        static let openDirectory: UInt8 = 11
        static let readDirectory: UInt8 = 12
        static let remove: UInt8 = 13
        static let makeDirectory: UInt8 = 14
        static let removeDirectory: UInt8 = 15
        static let realPath: UInt8 = 16
        static let stat: UInt8 = 17
        static let rename: UInt8 = 18
        static let extended: UInt8 = 200
    }

    enum Reply {
        static let version: UInt8 = 2
        static let status: UInt8 = 101
        static let handle: UInt8 = 102
        static let data: UInt8 = 103
        static let name: UInt8 = 104
        static let attributes: UInt8 = 105
        static let extended: UInt8 = 201
    }

    enum OpenFlags {
        static let read: UInt32 = 0x01
        static let write: UInt32 = 0x02
        static let create: UInt32 = 0x08
        static let truncate: UInt32 = 0x10
    }

    struct Attributes {
        var size: UInt64?
        var permissions: UInt32?
        var modified: UInt32?

        var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
        var isLink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }
    }

    private struct Message {
        let type: UInt8
        /// Everything after the request ID.
        let body: Data
    }

    let ssh: SSHClient
    private(set) var maxRead = 32768
    private(set) var maxWrite = 32768

    private let lock = NSLock()
    private var buffer = Data()
    private var nextID: UInt32 = 1
    private var waiting: [UInt32: CheckedContinuation<Message, Error>] = [:]
    /// Replies that came in before anyone waited for them. The version reply uses ID 0.
    private var arrived: [UInt32: Message] = [:]
    private var failure: Error?
    private var lastActivity = Date()

    private init(ssh: SSHClient) {
        self.ssh = ssh
    }

    static func open(source: NetworkSource, password: String, key: Curve25519.Signing.PrivateKey?) async throws -> SFTPSession {
        let ssh = try await SSHClient.connect(
            host: source.hostName, port: UInt16(exactly: source.port ?? 22) ?? 22, trustedHostKey: source.trustedCertificate
        )
        do {
            try await ssh.authenticate(user: source.username, password: password, key: key)
            let session = SFTPSession(ssh: ssh)
            try await ssh.openSubsystem(
                "sftp",
                onData: { [weak session] in session?.receive($0) },
                onClose: { [weak session] in session?.fail($0) }
            )
            try await session.start()
            return session
        } catch {
            await ssh.close()
            throw error
        }
    }

    var isAlive: Bool { lock.withLock { failure == nil } }

    private func start() async throws {
        var initialize = ByteWriter()
        initialize.u32be(5)
        initialize.u8(Request.initialize)
        initialize.u32be(3)
        try await ssh.sendChannelData(initialize.data)
        let version = try await reply(for: 0)
        guard version.type == Reply.version else {
            throw RemoteError.protocolError("The server didn't start SFTP.")
        }
        var reader = ByteReader(version.body)
        _ = try reader.u32be()
        var extensions: Set<String> = []
        while reader.remaining > 0 {
            extensions.insert(try reader.sshText())
            _ = try reader.sshString()
        }
        // OpenSSH says how much it reads and writes at once; otherwise stick to the safe 32 KB.
        if extensions.contains("limits@openssh.com") {
            let limits = try await call(Request.extended) { $0.sshString("limits@openssh.com") }
            if limits.type == Reply.extended {
                var reader = ByteReader(limits.body)
                _ = try reader.u64be() // Packet length
                let read = try reader.u64be()
                let write = try reader.u64be()
                if read > 0 { maxRead = Int(min(read, 256 * 1024)) }
                if write > 0 { maxWrite = Int(min(write, 256 * 1024)) }
            }
        }
        startWatchdog()
    }

    /// Fails the session when the server stops answering.
    private func startWatchdog() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.isAlive else { return }
                let stalled = self.lock.withLock { !self.waiting.isEmpty && Date().timeIntervalSince(self.lastActivity) > 60 }
                if stalled {
                    self.fail(RemoteError.timedOut)
                    await self.ssh.close()
                    return
                }
            }
        }
    }

    // MARK: Requests

    func realPath(_ path: String) async throws -> String {
        let reply = try await call(Request.realPath) { $0.sshString(path) }
        try Self.check(reply, name: path)
        var reader = ByteReader(reply.body)
        guard reply.type == Reply.name, try reader.u32be() >= 1 else {
            throw RemoteError.protocolError("The server didn't resolve the folder.")
        }
        return try reader.sshText()
    }

    func stat(_ path: String, name: String) async throws -> Attributes {
        let reply = try await call(Request.stat) { $0.sshString(path) }
        try Self.check(reply, name: name)
        guard reply.type == Reply.attributes else { throw Self.unexpected }
        var reader = ByteReader(reply.body)
        return try Self.attributes(&reader)
    }

    func list(_ path: String, name: String) async throws -> [(name: String, attributes: Attributes)] {
        let handle = try await handle(for: Request.openDirectory, name: name) { $0.sshString(path) }
        var items: [(name: String, attributes: Attributes)] = []
        do {
            while true {
                let reply = try await call(Request.readDirectory) { $0.sshString(handle) }
                if reply.type == Reply.status, try Self.status(of: reply).code == 1 { break } // End of folder
                try Self.check(reply, name: name)
                guard reply.type == Reply.name else { throw Self.unexpected }
                var reader = ByteReader(reply.body)
                let count = try reader.u32be()
                for _ in 0..<count {
                    let filename = try reader.sshText()
                    _ = try reader.sshString() // Long name, as `ls -l` shows it
                    items.append((filename, try Self.attributes(&reader)))
                }
            }
        } catch {
            await close(handle)
            throw error
        }
        await close(handle)
        return items
    }

    func open(_ path: String, name: String, flags: UInt32) async throws -> Data {
        try await handle(for: Request.open, name: name) { message in
            message.sshString(path)
            message.u32be(flags)
            message.u32be(0) // No attributes
        }
    }

    /// Reads up to `length` bytes; nil at the end of the file.
    func read(_ handle: Data, name: String, offset: Int64, length: Int) async throws -> Data? {
        let reply = try await call(Request.read) { message in
            message.sshString(handle)
            message.u64be(UInt64(offset))
            message.u32be(UInt32(length))
        }
        if reply.type == Reply.status, try Self.status(of: reply).code == 1 { return nil }
        try Self.check(reply, name: name)
        guard reply.type == Reply.data else { throw Self.unexpected }
        var reader = ByteReader(reply.body)
        return try reader.sshString()
    }

    /// Reads from `offset` until `length` bytes, or the rest of the file, have been handed to
    /// `deliver` in order, keeping several requests in flight.
    func readPipelined(_ handle: Data, name: String, from offset: Int64, length: Int64?, deliver: (Data) async throws -> Void) async throws {
        let end = length.map { offset + $0 }
        let depth = max(4, min(64, (2 * 1024 * 1024) / maxRead))
        var queue: [(offset: Int64, length: Int, task: Task<Data?, Error>)] = []
        defer { queue.forEach { $0.task.cancel() } }
        var next = offset
        func fill() {
            while queue.count < depth {
                if let end, next >= end { return }
                let start = next
                let size = Int(min(Int64(maxRead), (end ?? .max) - start))
                queue.append((start, size, Task { try await self.read(handle, name: name, offset: start, length: size) }))
                next += Int64(size)
            }
        }
        fill()
        while !queue.isEmpty {
            try Task.checkCancellation()
            let request = queue.removeFirst()
            guard let data = try await request.task.value, !data.isEmpty else { return }
            try await deliver(data)
            // A short read: fetch the rest of this piece before moving on.
            var position = request.offset + Int64(data.count)
            var missing = request.length - data.count
            while missing > 0 {
                guard let more = try await read(handle, name: name, offset: position, length: missing), !more.isEmpty else { return }
                try await deliver(more)
                position += Int64(more.count)
                missing -= more.count
            }
            fill()
        }
    }

    func write(_ handle: Data, name: String, offset: Int64, data: Data) async throws {
        let reply = try await call(Request.write) { message in
            message.sshString(handle)
            message.u64be(UInt64(offset))
            message.sshString(data)
        }
        try Self.check(reply, name: name)
    }

    /// Closes a handle, reporting errors (a failed close can mean the upload didn't arrive).
    func close(_ handle: Data, name: String) async throws {
        let reply = try await call(Request.close) { $0.sshString(handle) }
        try Self.check(reply, name: name)
    }

    func close(_ handle: Data) async {
        _ = try? await call(Request.close) { $0.sshString(handle) }
    }

    /// A request about one path that only answers with a status.
    func simple(_ type: UInt8, _ path: String, name: String, _ fields: (inout ByteWriter) -> Void = { _ in }) async throws {
        let reply = try await call(type) { message in
            message.sshString(path)
            fields(&message)
        }
        try Self.check(reply, name: name)
    }

    private func handle(for type: UInt8, name: String, _ fields: (inout ByteWriter) -> Void) async throws -> Data {
        let reply = try await call(type, fields)
        try Self.check(reply, name: name)
        guard reply.type == Reply.handle else { throw Self.unexpected }
        var reader = ByteReader(reply.body)
        return try reader.sshString()
    }

    // MARK: Messages

    private func call(_ type: UInt8, _ fields: (inout ByteWriter) -> Void) async throws -> Message {
        let id = lock.withLock {
            let id = nextID
            nextID = nextID == .max ? 1 : nextID + 1
            return id
        }
        var packet = ByteWriter()
        packet.u32be(0)
        packet.u8(type)
        packet.u32be(id)
        fields(&packet)
        packet.set32be(UInt32(packet.count - 4), at: 0)
        try await ssh.sendChannelData(packet.data)
        return try await reply(for: id)
    }

    private func reply(for id: UInt32) async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let message = arrived.removeValue(forKey: id) {
                lock.unlock()
                continuation.resume(returning: message)
            } else if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else {
                // The server only counts as stalled from when there's something to wait for.
                if waiting.isEmpty { lastActivity = Date() }
                waiting[id] = continuation
                lock.unlock()
            }
        }
    }

    /// Takes channel data, which may hold any number of messages or parts of one.
    private func receive(_ data: Data) {
        var ready: [(CheckedContinuation<Message, Error>, Message)] = []
        lock.lock()
        lastActivity = Date()
        buffer.append(data)
        var offset = 0
        var broken = false
        while buffer.count - offset >= 4 {
            let length = Int(UInt32(bigEndian: buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
            guard length >= 1, length <= 4 * 1024 * 1024 else {
                broken = true
                break
            }
            guard buffer.count - offset - 4 >= length else { break }
            let type = buffer[offset + 4]
            var id: UInt32 = 0
            var bodyStart = offset + 5
            if type != Reply.version {
                guard length >= 5 else {
                    broken = true
                    break
                }
                id = UInt32(bigEndian: buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 5, as: UInt32.self) })
                bodyStart += 4
            }
            let message = Message(type: type, body: buffer.subdata(in: bodyStart..<offset + 4 + length))
            if let continuation = waiting.removeValue(forKey: id) {
                ready.append((continuation, message))
            } else {
                arrived[id] = message
            }
            offset += 4 + length
        }
        if offset > 0 { buffer = buffer.subdata(in: offset..<buffer.count) }
        lock.unlock()
        ready.forEach { $0.0.resume(returning: $0.1) }
        if broken {
            fail(RemoteError.protocolError("The server sent a damaged SFTP message."))
            Task { await ssh.close() }
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            return
        }
        failure = error
        let pending = waiting.values
        waiting = [:]
        lock.unlock()
        pending.forEach { $0.resume(throwing: error) }
    }

    // MARK: Parsing

    private static var unexpected: RemoteError { .protocolError("The server sent an unexpected SFTP reply.") }

    private static func status(of reply: Message) throws -> (code: UInt32, message: String) {
        var reader = ByteReader(reply.body)
        let code = try reader.u32be()
        let message = (try? reader.sshText()) ?? ""
        return (code, message)
    }

    /// Throws if `reply` is an error status.
    private static func check(_ reply: Message, name: String) throws {
        guard reply.type == Reply.status else { return }
        let (code, message) = try status(of: reply)
        let display = RemotePath.name(of: name).isEmpty ? "/" : RemotePath.name(of: name)
        switch code {
        case 0: return
        case 2: throw RemoteError.notFound(display)
        case 3: throw RemoteError.accessDenied
        case 6, 7: throw RemoteError.connectionFailed(message)
        case 8: throw RemoteError.unsupported("The server doesn't support this.")
        default:
            throw RemoteError.protocolError(message.isEmpty || message == "Failure" ? "The server couldn't complete the request." : message)
        }
    }

    private static func attributes(_ reader: inout ByteReader) throws -> Attributes {
        let flags = try reader.u32be()
        var attributes = Attributes()
        if flags & 0x1 != 0 { attributes.size = try reader.u64be() }
        if flags & 0x2 != 0 { try reader.skip(8) } // User and group IDs
        if flags & 0x4 != 0 { attributes.permissions = try reader.u32be() }
        if flags & 0x8 != 0 {
            try reader.skip(4) // Access time
            attributes.modified = try reader.u32be()
        }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try reader.u32be()) {
                _ = try reader.sshString()
                _ = try reader.sshString()
            }
        }
        return attributes
    }
}
