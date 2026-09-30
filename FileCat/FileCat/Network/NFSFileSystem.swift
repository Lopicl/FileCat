import Foundation

/// ONC RPC (RFC 5531) over TCP with record marking. Calls can overlap; replies are matched by XID.
actor RPCClient {
    enum Program {
        static let portmap: UInt32 = 100_000
        static let nfs: UInt32 = 100_003
        static let mount: UInt32 = 100_005
    }

    private let connection: TCPConnection
    private let uid: UInt32
    private let gid: UInt32
    private var nextXID = UInt32.random(in: 1...UInt32.max / 2)
    private var pending: [UInt32: CheckedContinuation<ByteReader, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?
    private var failure: Error?

    private init(host: String, port: UInt16, uid: UInt32, gid: UInt32) {
        connection = TCPConnection(host: host, port: port)
        self.uid = uid
        self.gid = gid
    }

    static func connect(host: String, port: UInt16, uid: UInt32 = 0, gid: UInt32 = 0) async throws -> RPCClient {
        let client = RPCClient(host: host, port: port, uid: uid, gid: gid)
        try await client.start()
        return client
    }

    private func start() async throws {
        try await connection.open()
        let connection = connection
        receiveLoop = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    var record = Data()
                    var isLast = false
                    while !isLast {
                        let header = ByteReader(try await connection.receive(exactly: 4))
                        let mark = try header.u32be(at: 0)
                        isLast = mark & 0x8000_0000 != 0
                        record.append(try await connection.receive(exactly: Int(mark & 0x7FFF_FFFF)))
                    }
                    await self?.deliver(record)
                }
            } catch {
                await self?.fail(error)
            }
        }
    }

    var isAlive: Bool { failure == nil }

    func close() {
        receiveLoop?.cancel()
        connection.close()
        fail(RemoteError.connectionFailed("The connection was closed."))
    }

    private func deliver(_ record: Data) {
        var reader = ByteReader(record)
        guard let xid = try? reader.u32be(), let continuation = pending.removeValue(forKey: xid) else { return }
        do {
            guard try reader.u32be() == 1 else { throw RemoteError.protocolError("Not an RPC reply.") }
            if try reader.u32be() != 0 {
                // Denied: 0 = version mismatch, 1 = authentication error.
                let reason = try reader.u32be()
                throw reason == 1 ? RemoteError.accessDenied : RemoteError.protocolError("RPC version mismatch.")
            }
            _ = try reader.u32be() // Verifier flavor
            let verifierLength = Int(try reader.u32be())
            try reader.skip((verifierLength + 3) & ~3)
            switch try reader.u32be() {
            case 0: continuation.resume(returning: reader)
            case 1, 2: throw RemoteError.unsupported("The server doesn't offer this service (NFS version 3 over TCP is required).")
            case 3: throw RemoteError.unsupported("The server doesn't support this operation.")
            default: throw RemoteError.protocolError("The server couldn't process the request.")
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    func call(program: UInt32, version: UInt32, procedure: UInt32, arguments: Data, useUnixAuth: Bool = true) async throws -> ByteReader {
        if let failure { throw failure }
        let xid = nextXID
        nextXID &+= 1

        var message = ByteWriter()
        message.u32be(0) // Record mark, filled in below
        message.u32be(xid)
        message.u32be(0) // Call
        message.u32be(2) // RPC version
        message.u32be(program)
        message.u32be(version)
        message.u32be(procedure)
        if useUnixAuth {
            var credential = XDRWriter()
            credential.u32(UInt32(Date().timeIntervalSince1970) & 0x7FFF_FFFF)
            credential.string("filecat")
            credential.u32(uid)
            credential.u32(gid)
            credential.u32(1)
            credential.u32(gid)
            message.u32be(1) // AUTH_UNIX
            message.u32be(UInt32(credential.data.count))
            message.bytes(credential.data)
        } else {
            message.u32be(0)
            message.u32be(0)
        }
        message.u32be(0) // Verifier: AUTH_NONE
        message.u32be(0)
        message.bytes(arguments)
        message.set32be(0x8000_0000 | UInt32(message.count - 4), at: 0)
        let data = message.data

        return try await withCheckedThrowingContinuation { continuation in
            pending[xid] = continuation
            Task {
                do {
                    try await connection.send(data)
                } catch {
                    self.resolve(xid, with: error)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(60))
                self.resolve(xid, with: RemoteError.timedOut)
            }
        }
    }

    private func resolve(_ xid: UInt32, with error: Error) {
        pending.removeValue(forKey: xid)?.resume(throwing: error)
    }
}

/// XDR encoding (RFC 4506): big-endian, padded to four bytes.
struct XDRWriter {
    private var writer = ByteWriter()
    var data: Data { writer.data }

    mutating func u32(_ value: UInt32) { writer.u32be(value) }
    mutating func u64(_ value: UInt64) { writer.u64be(value) }
    mutating func bool(_ value: Bool) { writer.u32be(value ? 1 : 0) }

    mutating func opaque(_ value: Data) {
        writer.u32be(UInt32(value.count))
        writer.bytes(value)
        writer.align(4)
    }

    mutating func fixed(_ value: Data) {
        writer.bytes(value)
    }

    mutating func string(_ value: String) {
        opaque(Data(value.utf8))
    }
}

extension ByteReader {
    mutating func xdrBool() throws -> Bool { try u32be() != 0 }

    mutating func xdrOpaque() throws -> Data {
        let length = Int(try u32be())
        let value = try bytes(length)
        align(4)
        return value
    }

    mutating func xdrString() throws -> String {
        String(decoding: try xdrOpaque(), as: UTF8.self)
    }
}

/// NFS version 3 (RFC 1813) over TCP.
actor NFSFileSystem: RemoteFileSystem {
    private struct Attributes {
        let isDirectory: Bool
        let size: Int64
        let modified: Date
    }

    private enum Procedure: UInt32 {
        case getattr = 1, lookup = 3, read = 6, write = 7, create = 8, mkdir = 9
        case remove = 12, rmdir = 13, rename = 14, readdir = 16, readdirplus = 17, fsinfo = 19, commit = 21
    }

    private let source: NetworkSource
    private var rpc: RPCClient?
    private var rootHandle = Data()
    private var handles: [String: Data] = [:]
    private var readSize = 65_536
    private var writeSize = 65_536

    private init(source: NetworkSource) {
        self.source = source
    }

    static func connect(source: NetworkSource) async throws -> any RemoteFileSystem {
        let fileSystem = NFSFileSystem(source: source)
        try await fileSystem.mount()
        return fileSystem
    }

    private var exportPath: String {
        let path = source.path.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/" + path)
    }

    private var uid: UInt32 { UInt32(source.uid ?? 1000) }
    private var gid: UInt32 { UInt32(source.gid ?? 1000) }

    /// Ports for the mount and NFS services: the one the user set, or whatever the portmapper says.
    private static func ports(for source: NetworkSource) async throws -> (mount: UInt16, nfs: UInt16) {
        if let port = source.port { return (UInt16(port), UInt16(port)) }
        let portmap: RPCClient
        do {
            portmap = try await RPCClient.connect(host: source.host, port: 111)
        } catch {
            // No portmapper: servers like this usually run both services on 2049.
            return (2049, 2049)
        }
        defer { Task { await portmap.close() } }
        func lookup(_ program: UInt32, _ version: UInt32) async throws -> UInt16 {
            var arguments = XDRWriter()
            arguments.u32(program)
            arguments.u32(version)
            arguments.u32(6) // TCP
            arguments.u32(0)
            var reply = try await portmap.call(program: RPCClient.Program.portmap, version: 2, procedure: 3, arguments: arguments.data, useUnixAuth: false)
            return UInt16(truncatingIfNeeded: try reply.u32be())
        }
        let mount = try await lookup(RPCClient.Program.mount, 3)
        let nfs = try await lookup(RPCClient.Program.nfs, 3)
        guard mount != 0 else { throw RemoteError.unsupported("The server doesn't offer NFS version 3 over TCP.") }
        return (mount, nfs == 0 ? 2049 : nfs)
    }

    private func mount() async throws {
        let ports = try await Self.ports(for: source)
        let mountClient = try await RPCClient.connect(host: source.host, port: ports.mount, uid: uid, gid: gid)
        defer { Task { await mountClient.close() } }
        var arguments = XDRWriter()
        arguments.string(exportPath)
        var reply = try await mountClient.call(program: RPCClient.Program.mount, version: 3, procedure: 1, arguments: arguments.data)
        let status = try reply.u32be()
        guard status == 0 else {
            switch status {
            case 1, 13: throw RemoteError.accessDenied
            case 2: throw RemoteError.notFound(exportPath)
            default: throw RemoteError.protocolError("Mount failed with status \(status).")
            }
        }
        rootHandle = try reply.xdrOpaque()
        handles = ["/": rootHandle]

        rpc = try await RPCClient.connect(host: source.host, port: ports.nfs, uid: uid, gid: gid)
        await loadLimits()
    }

    private func client() async throws -> RPCClient {
        if let rpc, await rpc.isAlive { return rpc }
        try await mount()
        guard let rpc else { throw RemoteError.connectionFailed("") }
        return rpc
    }

    private func call(_ procedure: Procedure, _ arguments: XDRWriter, name: String) async throws -> ByteReader {
        let rpc = try await client()
        var reply = try await rpc.call(program: RPCClient.Program.nfs, version: 3, procedure: procedure.rawValue, arguments: arguments.data)
        let status = try reply.u32be()
        guard status == 0 else { throw Self.error(status, name: name) }
        return reply
    }

    private static func error(_ status: UInt32, name: String) -> RemoteError {
        switch status {
        case 1, 13: .accessDenied
        case 2: .notFound(name)
        case 17: .alreadyExists(name)
        case 28, 69: .unsupported("The server is out of space.")
        case 30: .unsupported("The export is read-only.")
        case 66: .folderNotEmpty(name)
        case 70, 10001: .connectionFailed("The server no longer recognizes this item.")
        case 10004: .unsupported("The server doesn't support this operation.")
        default: .protocolError("NFS error \(status).")
        }
    }

    private func loadLimits() async {
        var arguments = XDRWriter()
        arguments.opaque(rootHandle)
        guard var reply = try? await call(.fsinfo, arguments, name: "/") else { return }
        do {
            try skipPostOpAttributes(&reply)
            _ = try reply.u32be() // rtmax
            let readPreferred = Int(try reply.u32be())
            _ = try reply.u32be() // rtmult
            _ = try reply.u32be() // wtmax
            let writePreferred = Int(try reply.u32be())
            if readPreferred > 0 { readSize = min(readPreferred, 1_048_576) }
            if writePreferred > 0 { writeSize = min(writePreferred, 1_048_576) }
        } catch {}
    }

    // MARK: Attributes and handles

    private func readAttributes(_ reader: inout ByteReader) throws -> Attributes {
        let type = try reader.u32be()
        try reader.skip(16) // mode, nlink, uid, gid
        let size = try reader.u64be()
        try reader.skip(8 + 8 + 8 + 8 + 8) // used, rdev, fsid, fileid, atime
        let seconds = try reader.u32be()
        let nanoseconds = try reader.u32be()
        try reader.skip(8) // ctime
        return Attributes(isDirectory: type == 2, size: Int64(size), modified: Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1e9))
    }

    private func readPostOpAttributes(_ reader: inout ByteReader) throws -> Attributes? {
        try reader.xdrBool() ? try readAttributes(&reader) : nil
    }

    private func skipPostOpAttributes(_ reader: inout ByteReader) throws {
        if try reader.xdrBool() { try reader.skip(84) }
    }

    private func skipWeakCacheConsistency(_ reader: inout ByteReader) throws {
        if try reader.xdrBool() { try reader.skip(24) }
        try skipPostOpAttributes(&reader)
    }

    /// The file handle for a path, looking up each component the first time.
    private func handle(for path: String) async throws -> Data {
        let path = RemotePath.normalized(path)
        if let handle = handles[path] { return handle }
        let parent = try await handle(for: RemotePath.parent(of: path))
        let name = RemotePath.name(of: path)
        var arguments = XDRWriter()
        arguments.opaque(parent)
        arguments.string(name)
        var reply = try await call(.lookup, arguments, name: name)
        let handle = try reply.xdrOpaque()
        handles[path] = handle
        return handle
    }

    private func forget(_ path: String) {
        let path = RemotePath.normalized(path)
        handles = handles.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    // MARK: RemoteFileSystem

    func list(_ path: String) async throws -> [RemoteEntry] {
        let directory = try await handle(for: path)
        var entries: [RemoteEntry] = []
        var cookie: UInt64 = 0
        var verifier = Data(count: 8)
        var finished = false
        while !finished {
            var arguments = XDRWriter()
            arguments.opaque(directory)
            arguments.u64(cookie)
            arguments.fixed(verifier)
            arguments.u32(16_384) // dircount
            arguments.u32(65_536) // maxcount
            var reply = try await call(.readdirplus, arguments, name: RemotePath.name(of: path))
            try skipPostOpAttributes(&reply)
            verifier = try reply.bytes(8)
            while try reply.xdrBool() {
                _ = try reply.u64be() // fileid
                let name = try reply.xdrString()
                cookie = try reply.u64be()
                let attributes = try readPostOpAttributes(&reply)
                if try reply.xdrBool() {
                    let handle = try reply.xdrOpaque()
                    handles[RemotePath.normalized(RemotePath.join(path, name))] = handle
                }
                guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
                entries.append(RemoteEntry(
                    name: name,
                    isDirectory: attributes?.isDirectory ?? false,
                    size: attributes?.isDirectory == true ? nil : attributes?.size,
                    modified: attributes?.modified
                ))
            }
            finished = try reply.xdrBool()
        }
        return entries
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        let file = try await handle(for: path)
        var result = Data()
        while result.count < length {
            let (data, eof) = try await readChunk(file, offset: offset + Int64(result.count), count: min(readSize, length - result.count), name: RemotePath.name(of: path))
            result.append(data)
            if eof || data.isEmpty { break }
        }
        return result
    }

    private func readChunk(_ file: Data, offset: Int64, count: Int, name: String) async throws -> (Data, Bool) {
        var arguments = XDRWriter()
        arguments.opaque(file)
        arguments.u64(UInt64(offset))
        arguments.u32(UInt32(count))
        var reply = try await call(.read, arguments, name: name)
        try skipPostOpAttributes(&reply)
        _ = try reply.u32be() // count
        let eof = try reply.xdrBool()
        return (try reply.xdrOpaque(), eof)
    }

    func download(_ path: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let file = try await handle(for: path)
        let name = RemotePath.name(of: path)
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset: Int64 = 0
        // Several reads in flight at once, written back in order.
        let window = 4
        var inFlight: [(Int64, Task<(Data, Bool), Error>)] = []
        var nextOffset: Int64 = 0
        var reachedEnd = false
        func schedule() {
            let start = nextOffset
            nextOffset += Int64(readSize)
            let size = readSize
            inFlight.append((start, Task { try await self.readChunk(file, offset: start, count: size, name: name) }))
        }
        for _ in 0..<window { schedule() }
        defer { inFlight.forEach { $0.1.cancel() } }
        while !inFlight.isEmpty {
            try Task.checkCancellation()
            let (start, task) = inFlight.removeFirst()
            var (data, eof) = try await task.value
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            // Servers may return less than asked for; fill the gap before the next chunk.
            while !eof, !data.isEmpty, offset < start + Int64(readSize) {
                (data, eof) = try await readChunk(file, offset: offset, count: Int(start + Int64(readSize) - offset), name: name)
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
            }
            progress(offset)
            if eof || data.isEmpty {
                reachedEnd = true
                break
            }
            schedule()
        }
        if !reachedEnd {
            throw RemoteError.protocolError("The download stopped early.")
        }
    }

    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let parent = try await handle(for: RemotePath.parent(of: path))
        let name = RemotePath.name(of: path)
        var arguments = XDRWriter()
        arguments.opaque(parent)
        arguments.string(name)
        arguments.u32(0) // UNCHECKED: replace an existing file
        writeAttributes(&arguments, mode: 0o644, truncate: true)
        var reply = try await call(.create, arguments, name: name)
        forget(path)
        let file: Data
        if try reply.xdrBool() {
            file = try reply.xdrOpaque()
            handles[RemotePath.normalized(path)] = file
        } else {
            file = try await handle(for: path)
        }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var offset: Int64 = 0
        while let data = try input.read(upToCount: writeSize), !data.isEmpty {
            try Task.checkCancellation()
            var sent = 0
            while sent < data.count {
                var write = XDRWriter()
                write.opaque(file)
                write.u64(UInt64(offset) + UInt64(sent))
                let chunk = data.subdata(in: sent..<data.count)
                write.u32(UInt32(chunk.count))
                write.u32(0) // UNSTABLE, committed below
                write.opaque(chunk)
                var reply = try await call(.write, write, name: name)
                try skipWeakCacheConsistency(&reply)
                let count = Int(try reply.u32be())
                guard count > 0 else { throw RemoteError.protocolError("The server stopped accepting data.") }
                sent += count
            }
            offset += Int64(data.count)
            progress(offset)
        }
        var commit = XDRWriter()
        commit.opaque(file)
        commit.u64(0)
        commit.u32(0)
        _ = try await call(.commit, commit, name: name)
    }

    private func writeAttributes(_ writer: inout XDRWriter, mode: UInt32, truncate: Bool) {
        writer.bool(true)
        writer.u32(mode)
        writer.bool(false) // uid
        writer.bool(false) // gid
        writer.bool(truncate)
        if truncate { writer.u64(0) }
        writer.u32(1) // atime: server time
        writer.u32(1) // mtime: server time
    }

    func createFolder(_ path: String) async throws {
        let parent = try await handle(for: RemotePath.parent(of: path))
        let name = RemotePath.name(of: path)
        var arguments = XDRWriter()
        arguments.opaque(parent)
        arguments.string(name)
        writeAttributes(&arguments, mode: 0o755, truncate: false)
        _ = try await call(.mkdir, arguments, name: name)
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        if isDirectory {
            try await deleteRecursively(path) { child, isFolder in
                try await self.removeEntry(child, isDirectory: isFolder)
            }
        } else {
            try await removeEntry(path, isDirectory: false)
        }
    }

    private func removeEntry(_ path: String, isDirectory: Bool) async throws {
        let parent = try await handle(for: RemotePath.parent(of: path))
        let name = RemotePath.name(of: path)
        var arguments = XDRWriter()
        arguments.opaque(parent)
        arguments.string(name)
        _ = try await call(isDirectory ? .rmdir : .remove, arguments, name: name)
        forget(path)
    }

    func move(_ path: String, to newPath: String) async throws {
        let fromParent = try await handle(for: RemotePath.parent(of: path))
        let toParent = try await handle(for: RemotePath.parent(of: newPath))
        var arguments = XDRWriter()
        arguments.opaque(fromParent)
        arguments.string(RemotePath.name(of: path))
        arguments.opaque(toParent)
        arguments.string(RemotePath.name(of: newPath))
        _ = try await call(.rename, arguments, name: RemotePath.name(of: path))
        forget(path)
        forget(newPath)
    }

    func close() async {
        await rpc?.close()
        rpc = nil
        handles = [:]
    }

    // MARK: Exports

    /// The directories the server exports (MOUNT's EXPORT procedure).
    static func listExports(source: NetworkSource) async throws -> [String] {
        let ports = try await ports(for: source)
        let client = try await RPCClient.connect(host: source.host, port: ports.mount)
        defer { Task { await client.close() } }
        var reply = try await client.call(program: RPCClient.Program.mount, version: 3, procedure: 5, arguments: Data(), useUnixAuth: false)
        var exports: [String] = []
        while try reply.xdrBool() {
            exports.append(try reply.xdrString())
            while try reply.xdrBool() {
                _ = try reply.xdrString() // Allowed client group
            }
        }
        return exports.sorted()
    }
}
