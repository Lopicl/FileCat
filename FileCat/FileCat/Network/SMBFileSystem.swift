import Foundation

/// Files on an SMB share (Windows, macOS, Samba, NAS). If the source names no share, the root
/// lists the server's shares as folders.
actor SMBFileSystem: RemoteFileSystem {
    private let source: NetworkSource
    private let password: String
    /// The fixed share and folder inside it, if the source names one ("Media/Music").
    private let fixedShare: String?
    private let basePath: [String]
    private var client: SMB2Client?
    private var trees: [String: UInt32] = [:]

    private init(source: NetworkSource, password: String) {
        self.source = source
        self.password = password
        let parts = RemotePath.components(of: source.path.replacingOccurrences(of: "\\", with: "/"))
        fixedShare = parts.first
        basePath = Array(parts.dropFirst())
    }

    static func connect(source: NetworkSource, password: String) async throws -> any RemoteFileSystem {
        let fileSystem = SMBFileSystem(source: source, password: password)
        _ = try await fileSystem.list("/")
        return fileSystem
    }

    // MARK: Connection

    private func connectedClient() async throws -> SMB2Client {
        if let client, await client.isAlive { return client }
        trees = [:]
        let client = try await SMB2Client.connect(
            host: source.host, port: UInt16(source.port ?? 445),
            user: source.username, password: password, domain: source.domain
        )
        self.client = client
        return client
    }

    private func tree(_ share: String, on client: SMB2Client) async throws -> UInt32 {
        if let tree = trees[share.lowercased()] { return tree }
        let tree = try await client.treeConnect(share: share)
        trees[share.lowercased()] = tree
        return tree
    }

    /// Where a path lives: the share, and the backslash path inside it.
    private func locate(_ path: String) throws -> (share: String, path: String) {
        var parts = RemotePath.components(of: path)
        let share: String
        if let fixedShare {
            share = fixedShare
            parts = basePath + parts
        } else {
            guard !parts.isEmpty else { throw RemoteError.unsupported("Choose a share first.") }
            share = parts.removeFirst()
        }
        return (share, parts.joined(separator: "\\"))
    }

    /// Runs `body` with a live session, reconnecting once if the connection dropped.
    private func withTree<T>(_ path: String, _ body: (SMB2Client, UInt32, String) async throws -> T) async throws -> T {
        let location = try locate(path)
        for attempt in 0..<2 {
            do {
                let client = try await connectedClient()
                let tree = try await tree(location.share, on: client)
                return try await body(client, tree, location.path)
            } catch let error as RemoteError where attempt == 0 && Self.isConnectionError(error) {
                await client?.close()
                client = nil
                continue
            }
        }
        throw RemoteError.connectionFailed("")
    }

    private static func isConnectionError(_ error: RemoteError) -> Bool {
        switch error {
        case .connectionFailed, .timedOut: true
        default: false
        }
    }

    // MARK: RemoteFileSystem

    func list(_ path: String) async throws -> [RemoteEntry] {
        if fixedShare == nil && RemotePath.components(of: path).isEmpty {
            let client = try await connectedClient()
            return try await Self.shares(client: client).map {
                RemoteEntry(name: $0, isDirectory: true, size: nil, modified: nil)
            }
        }
        return try await withTree(path) { client, tree, smbPath in
            let directory = try await client.create(
                tree: tree, path: smbPath,
                access: SMB2Client.Access.listDirectory | SMB2Client.Access.readAttributes | SMB2Client.Access.synchronize,
                disposition: .open, options: SMB2Client.Options.directory
            )
            defer { Task { await client.close(tree: tree, file: directory.fileID) } }
            return try await client.queryDirectory(tree: tree, file: directory.fileID)
                .filter { !$0.isHidden && !$0.name.hasPrefix(".") }
                .map { RemoteEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.isDirectory ? nil : $0.size, modified: $0.modified) }
        }
    }

    func read(_ path: String, offset: Int64, length: Int) async throws -> Data {
        try await withTree(path) { client, tree, smbPath in
            let file = try await openForReading(client, tree, smbPath)
            defer { Task { await client.close(tree: tree, file: file.fileID) } }
            var result = Data()
            let chunk = await client.chunkSize(forWriting: false)
            while result.count < length {
                let data = try await client.read(tree: tree, file: file.fileID, offset: offset + Int64(result.count), length: min(chunk, length - result.count))
                if data.isEmpty { break }
                result.append(data)
            }
            return result
        }
    }

    func download(_ path: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTree(path) { client, tree, smbPath in
            let file = try await openForReading(client, tree, smbPath)
            defer { Task { await client.close(tree: tree, file: file.fileID) } }
            FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }

            // Keep several reads in flight; on a LAN that's what makes downloads fast.
            let chunk = Int64(await client.chunkSize(forWriting: false))
            let size = file.size
            var nextOffset: Int64 = 0
            var written: Int64 = 0
            try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
                var buffered: [Int64: Data] = [:]
                func schedule() {
                    guard nextOffset < size else { return }
                    let offset = nextOffset
                    let length = Int(min(chunk, size - offset))
                    nextOffset += Int64(length)
                    group.addTask { (offset, try await client.read(tree: tree, file: file.fileID, offset: offset, length: length)) }
                }
                for _ in 0..<4 { schedule() }
                while let (offset, data) = try await group.next() {
                    try Task.checkCancellation()
                    buffered[offset] = data
                    while let ready = buffered.removeValue(forKey: written) {
                        try handle.write(contentsOf: ready)
                        written += Int64(ready.count)
                        progress(written)
                        if ready.isEmpty { break }
                    }
                    schedule()
                }
            }
            // The file grew while we read it: fetch the rest.
            while true {
                let data = try await client.read(tree: tree, file: file.fileID, offset: written, length: Int(chunk))
                if data.isEmpty { break }
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                progress(written)
            }
        }
    }

    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTree(path) { client, tree, smbPath in
            let file = try await client.create(
                tree: tree, path: smbPath,
                access: SMB2Client.Access.genericWrite | SMB2Client.Access.readAttributes | SMB2Client.Access.synchronize,
                disposition: .overwriteIf, options: SMB2Client.Options.nonDirectory
            )
            defer { Task { await client.close(tree: tree, file: file.fileID) } }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let chunk = await client.chunkSize(forWriting: true)
            var offset: Int64 = 0
            while let data = try handle.read(upToCount: chunk), !data.isEmpty {
                try Task.checkCancellation()
                var sent = 0
                while sent < data.count {
                    let count = try await client.write(tree: tree, file: file.fileID, offset: offset + Int64(sent), data: data.subdata(in: sent..<data.count))
                    guard count > 0 else { throw RemoteError.protocolError("The server stopped accepting data.") }
                    sent += count
                }
                offset += Int64(data.count)
                progress(offset)
            }
        }
    }

    func createFolder(_ path: String) async throws {
        try await withTree(path) { client, tree, smbPath in
            let folder = try await client.create(
                tree: tree, path: smbPath,
                access: SMB2Client.Access.listDirectory | SMB2Client.Access.readAttributes | SMB2Client.Access.synchronize,
                disposition: .create, options: SMB2Client.Options.directory, attributes: 0x10
            )
            await client.close(tree: tree, file: folder.fileID)
        }
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        if isDirectory {
            try await deleteRecursively(path) { child, isFolder in
                try await self.deleteEmpty(child, isDirectory: isFolder)
            }
        } else {
            try await deleteEmpty(path, isDirectory: false)
        }
    }

    private func deleteEmpty(_ path: String, isDirectory: Bool) async throws {
        try await withTree(path) { client, tree, smbPath in
            let item = try await client.create(
                tree: tree, path: smbPath,
                access: SMB2Client.Access.delete | SMB2Client.Access.readAttributes | SMB2Client.Access.synchronize,
                disposition: .open,
                options: SMB2Client.Options.deleteOnClose | (isDirectory ? SMB2Client.Options.directory : SMB2Client.Options.nonDirectory)
            )
            await client.close(tree: tree, file: item.fileID)
        }
    }

    func move(_ path: String, to newPath: String) async throws {
        let from = try locate(path)
        let to = try locate(newPath)
        guard from.share.lowercased() == to.share.lowercased() else {
            throw RemoteError.unsupported("Items can only be moved within the same share.")
        }
        try await withTree(path) { client, tree, smbPath in
            let item = try await client.create(
                tree: tree, path: smbPath,
                access: SMB2Client.Access.delete | SMB2Client.Access.readAttributes | SMB2Client.Access.synchronize,
                disposition: .open, options: 0
            )
            defer { Task { await client.close(tree: tree, file: item.fileID) } }
            try await client.rename(tree: tree, file: item.fileID, to: to.path)
        }
    }

    func close() async {
        if let client {
            for tree in trees.values { await client.treeDisconnect(tree) }
            await client.logoff()
            await client.close()
        }
        client = nil
        trees = [:]
    }

    private func openForReading(_ client: SMB2Client, _ tree: UInt32, _ path: String) async throws -> SMB2Client.CreateResult {
        let file = try await client.create(
            tree: tree, path: path,
            access: SMB2Client.Access.readData | SMB2Client.Access.readAttributes | SMB2Client.Access.synchronize,
            disposition: .open, options: SMB2Client.Options.nonDirectory
        )
        return file
    }

    // MARK: Shares

    /// The server's disk shares, without hidden ones like `C$` or `IPC$`.
    static func listShares(source: NetworkSource, password: String) async throws -> [String] {
        let client = try await SMB2Client.connect(
            host: source.host, port: UInt16(source.port ?? 445),
            user: source.username, password: password, domain: source.domain
        )
        defer { Task { await client.close() } }
        return try await shares(client: client)
    }

    /// Calls NetrShareEnum (MS-SRVS) over the `srvsvc` named pipe.
    private static func shares(client: SMB2Client) async throws -> [String] {
        let tree = try await client.treeConnect(share: "IPC$")
        // Clean up in order: close the pipe, then leave IPC$.
        let reply: Result<Data, Error>
        do {
            let pipe = try await client.create(tree: tree, path: "srvsvc", access: SMB2Client.Access.pipe, disposition: .open, options: 0)
            do {
                let bindAck = try await client.transceive(tree: tree, file: pipe.fileID, input: DCERPC.bind())
                guard bindAck.count > 2, bindAck[2] == 12 else {
                    throw RemoteError.protocolError("The server didn't accept the share list request.")
                }
                reply = .success(try await client.transceive(tree: tree, file: pipe.fileID, input: DCERPC.netShareEnum(server: client.host)))
            } catch {
                reply = .failure(error)
            }
            await client.close(tree: tree, file: pipe.fileID)
        } catch {
            reply = .failure(error)
        }
        await client.treeDisconnect(tree)
        return try DCERPC.parseShares(try reply.get())
            .filter { $0.type & 0x0FFF_FFFF == 0 && $0.type & 0x8000_0000 == 0 && !$0.name.hasSuffix("$") }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// The small slice of DCE/RPC needed to list shares.
enum DCERPC {
    private static let srvsvc: [UInt8] = [0xC8, 0x4F, 0x32, 0x4B, 0x70, 0x16, 0xD3, 0x01, 0x12, 0x78, 0x5A, 0x47, 0xBF, 0x6E, 0xE1, 0x88]
    private static let ndr: [UInt8] = [0x04, 0x5D, 0x88, 0x8A, 0xEB, 0x1C, 0xC9, 0x11, 0x9F, 0xE8, 0x08, 0x00, 0x2B, 0x10, 0x48, 0x60]

    static func bind() -> Data {
        var body = ByteWriter()
        body.u16(4280) // Max transmit fragment
        body.u16(4280) // Max receive fragment
        body.u32(0) // Association group
        body.u8(1) // One context
        body.zeros(3)
        body.u16(0) // Context ID
        body.u8(1) // One transfer syntax
        body.u8(0)
        body.bytes(srvsvc)
        body.u16(3)
        body.u16(0)
        body.bytes(ndr)
        body.u32(2)
        return pdu(type: 11, callID: 1, body: body.data)
    }

    static func netShareEnum(server: String) -> Data {
        var stub = ByteWriter()
        // ServerName: unique pointer to a conformant varying string.
        stub.u32(0x0002_0000)
        let name = "\\\\" + server
        let characters = UInt32(name.utf16.count + 1)
        stub.u32(characters)
        stub.u32(0)
        stub.u32(characters)
        stub.bytes(name.utf16LittleEndian)
        stub.u16(0)
        stub.align(4)
        // InfoStruct: level 1, empty container.
        stub.u32(1)
        stub.u32(1)
        stub.u32(0x0002_0004)
        stub.u32(0)
        stub.u32(0)
        stub.u32(0xFFFF_FFFF) // Preferred maximum length
        stub.u32(0x0002_0008) // Resume handle
        stub.u32(0)

        var body = ByteWriter()
        body.u32(UInt32(stub.count)) // Allocation hint
        body.u16(0) // Context ID
        body.u16(15) // NetrShareEnum
        body.bytes(stub.data)
        return pdu(type: 0, callID: 2, body: body.data)
    }

    private static func pdu(type: UInt8, callID: UInt32, body: Data) -> Data {
        var writer = ByteWriter()
        writer.u8(5)
        writer.u8(0)
        writer.u8(type)
        writer.u8(0x03) // First and last fragment
        writer.bytes([0x10, 0, 0, 0]) // Little-endian, ASCII, IEEE
        writer.u16(UInt16(16 + body.count))
        writer.u16(0)
        writer.u32(callID)
        writer.bytes(body)
        return writer.data
    }

    struct Share {
        let name: String
        let type: UInt32
    }

    static func parseShares(_ response: Data) throws -> [Share] {
        // Reassemble the stub from the response fragments.
        var stub = Data()
        var reader = ByteReader(response)
        while reader.remaining >= 24 {
            let start = reader.offset
            guard try reader.u8(at: start + 2) == 2 else {
                throw RemoteError.protocolError("The share list request failed.")
            }
            let fragmentLength = Int(try reader.u16(at: start + 8))
            stub.append(try reader.bytes(at: start + 24, count: fragmentLength - 24))
            reader.offset = start + fragmentLength
        }

        var ndr = ByteReader(stub)
        _ = try ndr.u32() // Level
        _ = try ndr.u32() // Union tag
        guard try ndr.u32() != 0 else { return [] } // Container pointer
        let count = Int(try ndr.u32())
        guard try ndr.u32() != 0 else { return [] } // Array pointer
        _ = try ndr.u32() // Maximum count
        var types: [UInt32] = []
        var hasRemark: [Bool] = []
        for _ in 0..<count {
            _ = try ndr.u32() // Name pointer
            types.append(try ndr.u32())
            hasRemark.append(try ndr.u32() != 0)
        }
        func string() throws -> String {
            _ = try ndr.u32()
            _ = try ndr.u32()
            let actual = Int(try ndr.u32())
            let value = String(utf16LittleEndian: try ndr.bytes(actual * 2))
            ndr.align(4)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        var shares: [Share] = []
        for index in 0..<count {
            let name = try string()
            if hasRemark[index] { _ = try string() }
            shares.append(Share(name: name, type: types[index]))
        }
        return shares
    }
}
