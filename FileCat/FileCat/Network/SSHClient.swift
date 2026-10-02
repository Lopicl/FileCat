import CryptoKit
import Foundation

/// An SSH 2 client (RFC 4253, 4252 and 4254) with one session channel running a subsystem,
/// which is all SFTP needs. A reader task handles everything the server sends, including key
/// re-exchanges, and hands the channel's data to `onData` in order.
actor SSHClient {
    private static let version = "SSH-2.0-FileCat_1.0"
    /// How much the server may send before we acknowledge it.
    private static let localWindow = 8 * 1024 * 1024
    private static let localMaxPacket = 256 * 1024
    /// Keys are renewed after this much traffic (RFC 4253 section 9).
    private static let rekeyAfter = 1 << 30

    let host: String
    private let tcp: TCPConnection
    private let trustedHostKey: String?

    // Transport
    private var serverVersion = ""
    private var sendCipher: any SSHPacketCipher = SSHPlainCipher()
    private var receiveCipher: any SSHPacketCipher = SSHPlainCipher()
    private var sendSequence: UInt32 = 0
    private var receiveSequence: UInt32 = 0
    private var bytesSinceKeyExchange = 0
    private var sessionID: Data?
    private var hostKeyBlob: Data?
    private var strictKeyExchange = false
    private var exchange: KeyExchange?
    /// Messages sent during a key exchange wait here until the new keys are in use.
    private var held: [Data] = []
    private var keyExchangeWaiters: [CheckedContinuation<Void, Error>] = []
    private var failure: Error?
    private var reader: Task<Void, Never>?

    /// Replies for the steps that wait for one: service request, sign-in, channel setup.
    private var inbox: [Data] = []
    private var inboxWaiter: CheckedContinuation<Data, Error>?

    // The session channel
    private var remoteChannel: UInt32 = 0
    private var remoteWindow = 0
    private var remoteMaxPacket = 32768
    private var localWindowLeft = localWindow
    private var windowWaiters: [CheckedContinuation<Void, Error>] = []
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var onData: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (Error) -> Void)?

    private struct KeyExchange {
        let ourInit: Data
        var theirInit: Data?
        var algorithm = ""
        var hostKeyAlgorithm = ""
        var ciphers = (send: "", receive: "")
        var macs: (send: String?, receive: String?) = (nil, nil)
        var ephemeral: SSHEphemeralKey?
        var nextReceiveCipher: (any SSHPacketCipher)?
        var sentNewKeys = false
        /// The server guessed the algorithms wrong and sent its first exchange message anyway.
        var ignoreNextMessage = false
    }

    private init(host: String, tcp: TCPConnection, trustedHostKey: String?) {
        self.host = host
        self.tcp = tcp
        self.trustedHostKey = trustedHostKey
    }

    /// Connects and agrees on keys. Throws `RemoteError.untrustedHostKey` unless the server's
    /// key has the fingerprint `trustedHostKey`.
    static func connect(host: String, port: UInt16, trustedHostKey: String?) async throws -> SSHClient {
        let tcp = TCPConnection(host: host, port: port)
        try await tcp.open()
        let client = SSHClient(host: host, tcp: tcp, trustedHostKey: trustedHostKey)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            await client.fail(RemoteError.timedOut)
        }
        defer { watchdog.cancel() }
        do {
            try await client.handshake()
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    var isAlive: Bool { failure == nil }

    func close() {
        if failure == nil, exchange == nil {
            var message = ByteWriter()
            message.u8(1) // DISCONNECT
            message.u32be(11) // By application
            message.sshString("Closed by FileCat")
            message.sshString("")
            write(message.data)
        }
        fail(RemoteError.connectionFailed("The connection was closed."))
    }

    // MARK: Handshake

    private func handshake() async throws {
        tcp.enqueue(Data((Self.version + "\r\n").utf8)) { _ in }
        serverVersion = try await readVersion()
        startKeyExchange(initial: true)
        reader = Task { await self.readLoop() }
        if let failure { throw failure }
        if exchange != nil {
            try await withCheckedThrowingContinuation { keyExchangeWaiters.append($0) }
        }
    }

    /// The server's identification line. Servers may send other lines before it.
    private func readVersion() async throws -> String {
        var line = Data()
        var total = 0
        while total < 8192 {
            let byte = try await tcp.receive(exactly: 1)
            total += 1
            if byte.first != 0x0A {
                line.append(byte)
                continue
            }
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            line = Data()
            if text.hasPrefix("SSH-2.0-") || text.hasPrefix("SSH-1.99-") { return text }
            if text.hasPrefix("SSH-") { throw RemoteError.unsupported("The server only speaks an old version of SSH.") }
        }
        throw RemoteError.protocolError("This isn't an SSH server. Check the port.")
    }

    /// Signs in: with FileCat's key if the server accepts it, then with the password.
    func authenticate(user: String, password: String, key: Curve25519.Signing.PrivateKey?) async throws {
        var service = ByteWriter()
        service.u8(5) // SERVICE_REQUEST
        service.sshString("ssh-userauth")
        send(service.data)
        guard try await nextMessage().first == 6 else {
            throw RemoteError.protocolError("The server didn't offer a way to sign in.")
        }

        func request(_ method: String, _ fields: (inout ByteWriter) -> Void = { _ in }) {
            var message = ByteWriter()
            message.u8(50) // USERAUTH_REQUEST
            message.sshString(user)
            message.sshString("ssh-connection")
            message.sshString(method)
            fields(&message)
            send(message.data)
        }

        request("none")
        guard case .failure(var methods) = try await authResult() else { return }
        var triedKey = false

        if let key, methods.contains("publickey"), let sessionID {
            triedKey = true
            let blob = SSHClientKey.publicKeyBlob(of: key)
            var signed = ByteWriter()
            signed.sshString(sessionID)
            signed.u8(50)
            signed.sshString(user)
            signed.sshString("ssh-connection")
            signed.sshString("publickey")
            signed.sshBool(true)
            signed.sshString("ssh-ed25519")
            signed.sshString(blob)
            var signature = ByteWriter()
            signature.sshString("ssh-ed25519")
            signature.sshString(try key.signature(for: signed.data))
            request("publickey") { message in
                message.sshBool(true)
                message.sshString("ssh-ed25519")
                message.sshString(blob)
                message.sshString(signature.data)
            }
            switch try await authResult() {
            case .success: return
            case .failure(let next): methods = next
            }
        }

        if !password.isEmpty, methods.contains("password") {
            request("password") { message in
                message.sshBool(false)
                message.sshString(password)
            }
            let result = try await authResult { message in
                guard message.first == 60 else { return false }
                throw RemoteError.unsupported("The server wants a new password. Sign in once with another SSH app to change it.")
            }
            switch result {
            case .success: return
            case .failure(let next) where next.contains("password"):
                // The password was wrong. Don't try it again as keyboard-interactive.
                throw RemoteError.authenticationFailed
            case .failure(let next): methods = next
            }
        }

        if !password.isEmpty, methods.contains("keyboard-interactive") {
            request("keyboard-interactive") { message in
                message.sshString("") // Language
                message.sshString("") // Submethods
            }
            var rounds = 0
            let result = try await authResult { message in
                guard message.first == 60 else { return false }
                // Answer every prompt with the password, once.
                var reader = ByteReader(message, offset: 1)
                _ = try reader.sshString() // Name
                _ = try reader.sshString() // Instruction
                _ = try reader.sshString() // Language
                let prompts = Int(try reader.u32be())
                if prompts > 0 { rounds += 1 }
                guard rounds <= 1 else { throw RemoteError.authenticationFailed }
                var response = ByteWriter()
                response.u8(61) // USERAUTH_INFO_RESPONSE
                response.u32be(UInt32(prompts))
                for _ in 0..<prompts { response.sshString(password) }
                self.send(response.data)
                return true
            }
            if case .success = result { return }
        }

        if methods == ["publickey"] {
            throw RemoteError.unsupported(triedKey
                ? "The server only accepts SSH keys and doesn't know FileCat's. Copy FileCat's key in the server's settings and add it to ~/.ssh/authorized_keys on the server."
                : "The server only accepts SSH keys.")
        }
        throw RemoteError.authenticationFailed
    }

    private enum AuthResult {
        case success
        case failure(methods: [String])
    }

    /// Waits for the outcome of a sign-in request. `handler` gets other messages and returns
    /// whether it dealt with them.
    private func authResult(_ handler: ((Data) throws -> Bool)? = nil) async throws -> AuthResult {
        while true {
            let message = try await nextMessage()
            switch message.first {
            case 52: // USERAUTH_SUCCESS
                return .success
            case 51: // USERAUTH_FAILURE
                var reader = ByteReader(message, offset: 1)
                return .failure(methods: try reader.sshNameList())
            case 53: // USERAUTH_BANNER
                continue
            default:
                if let handler, try handler(message) { continue }
                throw RemoteError.protocolError("The server sent an unexpected reply while signing in.")
            }
        }
    }

    /// Opens a session channel and starts `name` ("sftp") in it.
    func openSubsystem(_ name: String, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error) -> Void) async throws {
        var open = ByteWriter()
        open.u8(90) // CHANNEL_OPEN
        open.sshString("session")
        open.u32be(0) // Our channel number
        open.u32be(UInt32(Self.localWindow))
        open.u32be(UInt32(Self.localMaxPacket))
        send(open.data)
        let reply = try await nextMessage()
        var reader = ByteReader(reply, offset: 1)
        switch reply.first {
        case 91: // CHANNEL_OPEN_CONFIRMATION
            _ = try reader.u32be()
            remoteChannel = try reader.u32be()
            remoteWindow = Int(try reader.u32be())
            remoteMaxPacket = max(1024, Int(try reader.u32be()))
        case 92:
            throw RemoteError.unsupported("The server didn't open a session.")
        default:
            throw RemoteError.protocolError("The server sent an unexpected reply to opening a session.")
        }
        self.onData = onData
        self.onClose = onClose

        var request = ByteWriter()
        request.u8(98) // CHANNEL_REQUEST
        request.u32be(remoteChannel)
        request.sshString("subsystem")
        request.sshBool(true)
        request.sshString(name)
        send(request.data)
        switch try await nextMessage().first {
        case 99: return // CHANNEL_SUCCESS
        case 100: throw RemoteError.unsupported("SFTP isn't turned on for this server.")
        default: throw RemoteError.protocolError("The server sent an unexpected reply to starting SFTP.")
        }
    }

    /// Sends data on the channel, waiting for the server's window when it's full. Each call's
    /// data goes out in one piece, even when calls overlap.
    func sendChannelData(_ data: Data) async throws {
        if let failure { throw failure }
        if isWriting {
            await withCheckedContinuation { writeWaiters.append($0) }
        } else {
            isWriting = true
        }
        defer {
            if writeWaiters.isEmpty { isWriting = false } else { writeWaiters.removeFirst().resume() }
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            if let failure { throw failure }
            if remoteWindow <= 0 {
                try await withCheckedThrowingContinuation { windowWaiters.append($0) }
                continue
            }
            let count = min(data.endIndex - offset, remoteMaxPacket, remoteWindow)
            var message = ByteWriter()
            message.u8(94) // CHANNEL_DATA
            message.u32be(remoteChannel)
            message.sshString(data[offset..<offset + count])
            send(message.data)
            remoteWindow -= count
            offset += count
        }
    }

    // MARK: Sending

    /// Queues a message. During a key exchange, other messages wait until the new keys are in use.
    private func send(_ payload: Data) {
        if let exchange, !exchange.sentNewKeys, let type = payload.first,
           !((1...4).contains(type) || (20...49).contains(type)) {
            held.append(payload)
            return
        }
        write(payload)
    }

    private func write(_ payload: Data) {
        guard failure == nil else { return }
        let cipher = sendCipher
        let unpadded = payload.count + 1 + (cipher.alignsLength ? 4 : 0)
        var padding = cipher.blockSize - unpadded % cipher.blockSize
        if padding < 4 { padding += cipher.blockSize }
        var body = ByteWriter()
        body.u8(UInt8(padding))
        body.bytes(payload)
        body.bytes((0..<padding).map { _ in UInt8.random(in: .min ... .max) })
        do {
            let packet = try cipher.seal(body.data, sequence: sendSequence)
            sendSequence &+= 1
            bytesSinceKeyExchange += packet.count
            tcp.enqueue(packet) { [weak self] error in
                guard let error, let self else { return }
                Task { await self.fail(error) }
            }
        } catch {
            fail(error)
        }
        if exchange == nil, sessionID != nil, bytesSinceKeyExchange > Self.rekeyAfter {
            startKeyExchange(initial: false)
        }
    }

    // MARK: Receiving

    private func readLoop() async {
        while failure == nil {
            do {
                let payload = try await readPacket()
                try handle(payload)
            } catch {
                fail(error)
            }
        }
    }

    private func readPacket() async throws -> Data {
        let cipher = receiveCipher
        let header = try await tcp.receive(exactly: cipher.headerLength)
        let length = try cipher.packetLength(header: header)
        guard 4 + length >= cipher.headerLength, length <= 2 * 1024 * 1024 else {
            throw RemoteError.protocolError("A message from the server has an invalid length.")
        }
        let restLength = 4 + length - cipher.headerLength
        let tail = try await tcp.receive(exactly: restLength + cipher.trailerLength)
        let body = Data(try cipher.open(
            header: header, rest: Data(tail.prefix(restLength)), trailer: Data(tail.suffix(cipher.trailerLength)),
            sequence: receiveSequence
        ))
        receiveSequence &+= 1
        bytesSinceKeyExchange += header.count + tail.count
        guard let padding = body.first.map(Int.init), padding + 1 < body.count else {
            throw SSHCipherError.corrupted
        }
        if exchange == nil, sessionID != nil, bytesSinceKeyExchange > Self.rekeyAfter {
            startKeyExchange(initial: false)
        }
        return body.subdata(in: 1..<body.count - padding)
    }

    private func handle(_ payload: Data) throws {
        guard let type = payload.first else { return }
        if exchange?.ignoreNextMessage == true, (30...49).contains(type) {
            exchange?.ignoreNextMessage = false
            return
        }
        var reader = ByteReader(payload, offset: 1)
        switch type {
        case 1: // DISCONNECT
            let code = try reader.u32be()
            let description = (try? reader.sshText()) ?? ""
            throw code == 14 ? RemoteError.authenticationFailed
                : RemoteError.connectionFailed(description.isEmpty ? "The server ended the session." : "The server ended the session: \(description)")
        case 2, 3, 4, 7: // IGNORE, UNIMPLEMENTED, DEBUG, EXT_INFO
            return
        case 20:
            try receivedKeyExchangeInit(payload)
        case 31:
            try receivedKeyExchangeReply(payload)
        case 21:
            try receivedNewKeys()
        case 80: // GLOBAL_REQUEST
            _ = try reader.sshString()
            if try reader.sshBool() { send(Data([82])) } // REQUEST_FAILURE
        case 93: // CHANNEL_WINDOW_ADJUST
            _ = try reader.u32be()
            remoteWindow += Int(try reader.u32be())
            let waiters = windowWaiters
            windowWaiters = []
            waiters.forEach { $0.resume() }
        case 94: // CHANNEL_DATA
            _ = try reader.u32be()
            let data = try reader.sshString()
            consumeWindow(data.count)
            onData?(data)
        case 95: // CHANNEL_EXTENDED_DATA (stderr)
            _ = try reader.u32be()
            _ = try reader.u32be()
            consumeWindow(try reader.sshString().count)
        case 96, 97: // CHANNEL_EOF, CHANNEL_CLOSE
            throw RemoteError.connectionFailed("The server ended the session.")
        case 98: // CHANNEL_REQUEST, such as exit-status or keepalive@openssh.com
            _ = try reader.u32be()
            _ = try reader.sshString()
            if try reader.sshBool() {
                var reply = ByteWriter()
                reply.u8(100) // CHANNEL_FAILURE
                reply.u32be(remoteChannel)
                send(reply.data)
            }
        default:
            if let waiter = inboxWaiter {
                inboxWaiter = nil
                waiter.resume(returning: payload)
            } else {
                inbox.append(payload)
            }
        }
    }

    private func consumeWindow(_ count: Int) {
        localWindowLeft -= count
        guard localWindowLeft < Self.localWindow / 2 else { return }
        var adjust = ByteWriter()
        adjust.u8(93) // CHANNEL_WINDOW_ADJUST
        adjust.u32be(remoteChannel)
        adjust.u32be(UInt32(Self.localWindow - localWindowLeft))
        send(adjust.data)
        localWindowLeft = Self.localWindow
    }

    private func nextMessage() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { inboxWaiter = $0 }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        inboxWaiter?.resume(throwing: error)
        inboxWaiter = nil
        keyExchangeWaiters.forEach { $0.resume(throwing: error) }
        keyExchangeWaiters = []
        windowWaiters.forEach { $0.resume(throwing: error) }
        windowWaiters = []
        writeWaiters.forEach { $0.resume() }
        writeWaiters = []
        onClose?(error)
        onClose = nil
        onData = nil
        tcp.close()
    }

    // MARK: Key exchange

    private func startKeyExchange(initial: Bool) {
        var message = ByteWriter()
        message.u8(20) // KEXINIT
        message.bytes((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        // Ask for the server's extension list and strict key exchange (against the Terrapin attack).
        message.sshNameList(SSHAlgorithms.keyExchange + (initial ? ["ext-info-c", "kex-strict-c-v00@openssh.com"] : []))
        message.sshNameList(SSHAlgorithms.hostKey)
        message.sshNameList(SSHAlgorithms.ciphers)
        message.sshNameList(SSHAlgorithms.ciphers)
        message.sshNameList(SSHAlgorithms.macs)
        message.sshNameList(SSHAlgorithms.macs)
        message.sshNameList(["none"])
        message.sshNameList(["none"])
        message.sshNameList([])
        message.sshNameList([])
        message.sshBool(false)
        message.u32be(0)
        exchange = KeyExchange(ourInit: message.data)
        bytesSinceKeyExchange = 0
        write(message.data)
    }

    private func receivedKeyExchangeInit(_ payload: Data) throws {
        // The server can start a new exchange at any time.
        if exchange == nil { startKeyExchange(initial: false) }
        guard var exchange, exchange.theirInit == nil else {
            throw RemoteError.protocolError("The server started a second key exchange.")
        }
        var reader = ByteReader(payload, offset: 17)
        let algorithms = try reader.sshNameList()
        let hostKeys = try reader.sshNameList()
        let ciphersOut = try reader.sshNameList()
        let ciphersIn = try reader.sshNameList()
        let macsOut = try reader.sshNameList()
        let macsIn = try reader.sshNameList()
        let compressionOut = try reader.sshNameList()
        let compressionIn = try reader.sshNameList()
        _ = try reader.sshNameList()
        _ = try reader.sshNameList()
        let guessFollows = try reader.sshBool()

        func choose(_ ours: [String], _ theirs: [String], _ what: String) throws -> String {
            guard let match = ours.first(where: theirs.contains) else {
                throw RemoteError.unsupported("The server's \(what) methods aren't supported (\(theirs.prefix(4).joined(separator: ", "))).")
            }
            return match
        }
        exchange.algorithm = try choose(SSHAlgorithms.keyExchange, algorithms, "key exchange")
        exchange.hostKeyAlgorithm = try choose(SSHAlgorithms.hostKey, hostKeys, "host key")
        exchange.ciphers = (try choose(SSHAlgorithms.ciphers, ciphersOut, "encryption"), try choose(SSHAlgorithms.ciphers, ciphersIn, "encryption"))
        exchange.macs = (
            SSHAlgorithms.isAEAD(exchange.ciphers.send) ? nil : try choose(SSHAlgorithms.macs, macsOut, "message authentication"),
            SSHAlgorithms.isAEAD(exchange.ciphers.receive) ? nil : try choose(SSHAlgorithms.macs, macsIn, "message authentication")
        )
        guard compressionOut.contains("none"), compressionIn.contains("none") else {
            throw RemoteError.unsupported("The server requires compression, which FileCat doesn't support.")
        }
        if sessionID == nil, algorithms.contains("kex-strict-s-v00@openssh.com") {
            strictKeyExchange = true
        }
        if guessFollows, algorithms.first != exchange.algorithm || hostKeys.first != exchange.hostKeyAlgorithm {
            exchange.ignoreNextMessage = true
        }
        exchange.theirInit = payload
        let ephemeral = SSHEphemeralKey(for: exchange.algorithm)
        exchange.ephemeral = ephemeral
        self.exchange = exchange

        var message = ByteWriter()
        message.u8(30) // KEX_ECDH_INIT
        message.sshString(ephemeral.publicKey)
        send(message.data)
    }

    private func receivedKeyExchangeReply(_ payload: Data) throws {
        guard var exchange, let theirInit = exchange.theirInit, let ephemeral = exchange.ephemeral, !exchange.sentNewKeys else {
            throw RemoteError.protocolError("The server sent an unexpected key exchange reply.")
        }
        var reader = ByteReader(payload, offset: 1)
        let hostKey = try reader.sshString()
        let serverPublicKey = try reader.sshString()
        let signature = try reader.sshString()
        let secret = try ephemeral.sharedSecret(with: serverPublicKey)

        var exchangeHash = ByteWriter()
        exchangeHash.sshString(Self.version)
        exchangeHash.sshString(serverVersion)
        exchangeHash.sshString(exchange.ourInit)
        exchangeHash.sshString(theirInit)
        exchangeHash.sshString(hostKey)
        exchangeHash.sshString(ephemeral.publicKey)
        exchangeHash.sshString(serverPublicKey)
        exchangeHash.sshMPInt(secret)
        let hash = ephemeral.hash(exchangeHash.data)
        try SSHHostKey.verify(signature: signature, of: hash, blob: hostKey, algorithm: exchange.hostKeyAlgorithm)

        if let known = hostKeyBlob {
            guard known == hostKey else {
                throw RemoteError.protocolError("The server's identity changed during the session.")
            }
        } else {
            let fingerprint = SSHHostKey.fingerprint(of: hostKey)
            guard fingerprint == trustedHostKey else {
                throw RemoteError.untrustedHostKey(
                    fingerprint: fingerprint, keyType: SSHHostKey.typeName(of: hostKey), changed: trustedHostKey != nil
                )
            }
            hostKeyBlob = hostKey
        }
        let sessionID = self.sessionID ?? hash
        self.sessionID = sessionID

        // RFC 4253 section 7.2
        func derive(_ letter: String, _ count: Int) -> Data {
            var prefix = ByteWriter()
            prefix.sshMPInt(secret)
            prefix.bytes(hash)
            var input = prefix
            input.bytes(Data(letter.utf8))
            input.bytes(sessionID)
            var key = ephemeral.hash(input.data)
            while key.count < count {
                var more = prefix
                more.bytes(key)
                key += ephemeral.hash(more.data)
            }
            return Data(key.prefix(count))
        }
        let sendSizes = SSHAlgorithms.sizes(of: exchange.ciphers.send)
        let receiveSizes = SSHAlgorithms.sizes(of: exchange.ciphers.receive)
        let newSendCipher = try SSHAlgorithms.makeCipher(
            exchange.ciphers.send, mac: exchange.macs.send,
            key: derive("C", sendSizes.key), iv: derive("A", sendSizes.iv),
            macKey: derive("E", SSHAlgorithms.macKeyLength(of: exchange.macs.send))
        )
        exchange.nextReceiveCipher = try SSHAlgorithms.makeCipher(
            exchange.ciphers.receive, mac: exchange.macs.receive,
            key: derive("D", receiveSizes.key), iv: derive("B", receiveSizes.iv),
            macKey: derive("F", SSHAlgorithms.macKeyLength(of: exchange.macs.receive))
        )
        exchange.sentNewKeys = true
        self.exchange = exchange

        write(Data([21])) // NEWKEYS
        sendCipher = newSendCipher
        if strictKeyExchange { sendSequence = 0 }
        let waiting = held
        held = []
        waiting.forEach(write)
    }

    private func receivedNewKeys() throws {
        guard let next = exchange?.nextReceiveCipher else {
            throw RemoteError.protocolError("The server switched keys too early.")
        }
        receiveCipher = next
        if strictKeyExchange { receiveSequence = 0 }
        exchange = nil
        bytesSinceKeyExchange = 0
        let waiters = keyExchangeWaiters
        keyExchangeWaiters = []
        waiters.forEach { $0.resume() }
    }
}
