import Foundation

/// One entry in a remote folder listing.
struct RemoteEntry: Sendable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
}

enum RemoteError: LocalizedError, Equatable {
    case authenticationFailed
    case accessDenied
    case notFound(String)
    case alreadyExists(String)
    case folderNotEmpty(String)
    case connectionFailed(String)
    case protocolError(String)
    case unsupported(String)
    /// A self-signed or otherwise untrusted HTTPS certificate. The user can choose to trust it.
    case untrustedCertificate(fingerprint: String, summary: String)
    /// An SSH server FileCat hasn't connected to before, or whose key changed since. The user
    /// can choose to trust it.
    case untrustedHostKey(fingerprint: String, keyType: String, changed: Bool)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "The user name or password is incorrect."
        case .accessDenied:
            "You don't have permission to access this item on the server."
        case .notFound(let name):
            "“\(name)” couldn't be found on the server."
        case .alreadyExists(let name):
            "An item named “\(name)” already exists on the server."
        case .folderNotEmpty(let name):
            "“\(name)” isn't empty."
        case .connectionFailed(let reason):
            "Couldn't connect to the server. \(reason)"
        case .protocolError(let reason):
            "The server sent an unexpected response. \(reason)"
        case .unsupported(let reason):
            reason
        case .untrustedCertificate(_, let summary):
            "The server's certificate isn't trusted (\(summary))."
        case .untrustedHostKey(_, _, let changed):
            changed
                ? "The server's identity has changed since you last connected. Edit the server to check its new key."
                : "FileCat hasn't connected to this server before. Edit the server to check its key."
        case .timedOut:
            "The server stopped responding."
        }
    }
}

/// What every network protocol provides. Paths are absolute within the source ("/", "/Music/a.mp3").
protocol RemoteFileSystem: AnyObject, Sendable {
    func list(_ path: String) async throws -> [RemoteEntry]
    /// Reads part of a file; used to stream video. Returns fewer bytes at the end of the file.
    func read(_ path: String, offset: Int64, length: Int) async throws -> Data
    /// Downloads a whole file to `destination`, reporting the number of bytes received so far.
    func download(_ path: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    /// Uploads a local file, replacing anything already at `path`.
    func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    func createFolder(_ path: String) async throws
    /// Deletes a file, or a folder and everything in it.
    func delete(_ path: String, isDirectory: Bool) async throws
    func move(_ path: String, to newPath: String) async throws
    func close() async
}

extension RemoteFileSystem {
    /// Downloads by reading the file in chunks; for protocols without a streaming download.
    func downloadInChunks(_ path: String, to destination: URL, chunkSize: Int, progress: @escaping @Sendable (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try await read(path, offset: offset, length: chunkSize)
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset)
            if data.count < chunkSize { break }
        }
    }

    /// Deletes a folder's contents first, for protocols that can only remove empty folders.
    func deleteRecursively(_ path: String, deleteEmpty: (String, Bool) async throws -> Void) async throws {
        for entry in try await list(path) {
            let child = RemotePath.join(path, entry.name)
            if entry.isDirectory {
                try await deleteRecursively(child, deleteEmpty: deleteEmpty)
            } else {
                try await deleteEmpty(child, false)
            }
        }
        try await deleteEmpty(path, true)
    }
}

/// Helpers for the "/"-separated paths used by every protocol.
enum RemotePath {
    static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    static func parent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else { return "/" }
        return String(trimmed[..<slash])
    }

    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    static func normalized(_ path: String) -> String {
        "/" + components(of: path).joined(separator: "/")
    }
}

/// Keeps one live connection per server and reconnects when a source changes.
actor RemoteConnections {
    static let shared = RemoteConnections()

    private var fileSystems: [String: any RemoteFileSystem] = [:]
    private var connecting: [String: Task<any RemoteFileSystem, Error>] = [:]

    func fileSystem(for source: NetworkSource) async throws -> any RemoteFileSystem {
        if let existing = fileSystems[source.id] { return existing }
        if let pending = connecting[source.id] { return try await pending.value }
        let task = Task { try await Self.connect(source) }
        connecting[source.id] = task
        defer { connecting[source.id] = nil }
        let fileSystem = try await task.value
        fileSystems[source.id] = fileSystem
        return fileSystem
    }

    /// Drops the connection so the next request reconnects with the latest settings.
    func invalidate(_ sourceID: String) async {
        connecting[sourceID]?.cancel()
        connecting[sourceID] = nil
        if let fileSystem = fileSystems.removeValue(forKey: sourceID) {
            await fileSystem.close()
        }
    }

    func invalidateAll() async {
        for id in Array(fileSystems.keys) {
            await invalidate(id)
        }
    }

    /// Connects without caching; used to check settings before saving a source.
    static func connect(_ source: NetworkSource, password: String? = nil) async throws -> any RemoteFileSystem {
        let password = password ?? source.password
        switch source.kind {
        case .webdav, .nextcloud:
            let fileSystem = try WebDAVFileSystem(source: source, password: password)
            _ = try await fileSystem.list("/")
            return fileSystem
        case .smb:
            return try await SMBFileSystem.connect(source: source, password: password)
        case .nfs:
            return try await NFSFileSystem.connect(source: source)
        case .sftp:
            return try await SFTPFileSystem.connect(source: source, password: password)
        case .ftp:
            return try await FTPFileSystem.connect(source: source, password: password)
        }
    }
}
