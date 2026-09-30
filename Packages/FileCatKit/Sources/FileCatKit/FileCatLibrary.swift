import Foundation

/// Describes a FileCat library. FileCat keeps it at `.FileCat/library.json` in the root of Local
/// Storage, so companion apps can recognise the folder and show tags the way FileCat does.
public struct LibraryManifest: Codable, Hashable, Sendable {
    public static let folderName = ".FileCat"
    public static let fileName = "library.json"

    public var formatVersion = 1
    /// Stays the same for the life of the library; handy for telling libraries apart.
    public var libraryID: UUID
    /// Every tag defined in FileCat, with its color and icon. Files carry only names and colors.
    public var tags: [FileTag]
    /// The folders and servers added in FileCat's Connections tab. Only names: access to folders
    /// belongs to FileCat, so a companion app asks the user to pick the same folders once.
    public var locations: [SharedLocation]?
    /// The servers added in FileCat, with everything but their passwords (see `ServerShareRequest`).
    public var servers: [SharedServer]?
    public var updated: Date

    public init(libraryID: UUID = UUID(), tags: [FileTag], updated: Date = Date()) {
        self.libraryID = libraryID
        self.tags = tags
        self.updated = updated
    }

    public static func url(in root: URL) -> URL {
        root.appending(path: folderName, directoryHint: .isDirectory).appending(path: fileName)
    }

    public static func read(from root: URL) -> LibraryManifest? {
        guard let data = try? Data(contentsOf: url(in: root)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryManifest.self, from: data)
    }

    public func write(to root: URL) throws {
        let url = Self.url(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// A folder or server added in FileCat, as listed in the library manifest.
public struct SharedLocation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case folder, drive, iCloud, server
    }

    public var name: String
    public var kind: Kind
    /// For servers: "smb://nas/Media", "https://cloud.example.com"…
    public var address: String?

    public init(name: String, kind: Kind, address: String? = nil) {
        self.name = name
        self.kind = kind
        self.address = address
    }
}

/// A file in the library, as a companion app sees it.
public struct LibraryFile: Hashable, Sendable {
    public let url: URL
    /// Path from the library root, e.g. "Music/Album/01 Song.mp3".
    public let relativePath: String
    public let kind: FileKind
    public let size: Int64?
    public let modified: Date?
    /// Finder-compatible tag names, in the order they were added.
    public let tags: [String]
}

/// Gives a companion app (a music or video player, say) lasting access to the files in FileCat.
///
/// FileCat's Local Storage appears in the Files app as *On My iPhone › FileCat*. The companion app
/// shows a folder picker once, the user picks that folder, and `connect(to:)` remembers it with a
/// security-scoped bookmark:
///
/// ```swift
/// let library = FileCatLibrary()
///
/// // In SwiftUI:
/// .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
///     if case .success(let folder) = result { try? library.connect(to: folder) }
/// }
///
/// let songs = library.files(ofKinds: [.audio])
/// ```
///
/// Access lasts across launches. Everything is plain files, so the companion app can also write
/// (for example to save playlists) and FileCat shows the changes.
public final class FileCatLibrary: @unchecked Sendable {
    public enum LibraryError: LocalizedError, Equatable {
        case notALibrary

        public var errorDescription: String? {
            "That folder isn't a FileCat library. In the picker, choose On My iPhone › FileCat (On My iPad on iPad)."
        }
    }

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var accessedURL: URL?

    /// - Parameters:
    ///   - defaults: Where the bookmark is saved.
    ///   - key: The defaults key; change it to connect to more than one library.
    public init(defaults: UserDefaults = .standard, key: String = "FileCatLibrary.bookmark") {
        self.defaults = defaults
        self.key = key
        restore()
    }

    deinit {
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    /// The root of the library while connected.
    public var rootURL: URL? {
        lock.withLock { accessedURL }
    }

    public var isConnected: Bool { rootURL != nil }

    /// Connects to a folder the user picked. Throws `LibraryError.notALibrary` for any other folder.
    public func connect(to folder: URL) throws {
        let accessing = folder.startAccessingSecurityScopedResource()
        guard FileCatLibrary.isLibrary(folder) else {
            if accessing { folder.stopAccessingSecurityScopedResource() }
            throw LibraryError.notALibrary
        }
        let bookmark = try folder.bookmarkData(options: Self.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: key)
        lock.withLock {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = folder
        }
    }

    public func disconnect() {
        defaults.removeObject(forKey: key)
        lock.withLock {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
    }

    public static func isLibrary(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: LibraryManifest.url(in: folder).path(percentEncoded: false))
    }

    /// The library's manifest: its ID and every tag with its color and icon.
    public var manifest: LibraryManifest? {
        rootURL.flatMap(LibraryManifest.read(from:))
    }

    public func tag(named name: String) -> FileTag? {
        manifest?.tags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Every file of the given kinds below `relativePath` (the whole library by default), skipping
    /// hidden files. Scans the disk, so call it off the main thread for large libraries.
    public func files(ofKinds kinds: Set<FileKind>, under relativePath: String = "") -> [LibraryFile] {
        guard let root = rootURL else { return [] }
        let start = relativePath.split(separator: "/").reduce(root) { $0.appending(path: String($1)) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var files: [LibraryFile] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isFolder = values.isDirectory == true && values.isPackage != true
            let kind = FileKind(url: url, isDirectory: isFolder)
            guard kinds.contains(kind), let path = self.relativePath(of: url) else { continue }
            files.append(LibraryFile(
                url: url, relativePath: path, kind: kind, size: values.fileSize.map(Int64.init),
                modified: values.contentModificationDate, tags: FileTags.read(url)
            ))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// The path of a file inside the library, or `nil` if it's somewhere else.
    public func relativePath(of url: URL) -> String? {
        guard let root = rootURL else { return nil }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    /// A `filecat://` link that opens (or reveals) the file in FileCat, for `UIApplication.open`.
    public func link(_ action: FileCatLink.Action = .open, for url: URL) -> URL? {
        relativePath(of: url).map { FileCatLink(action: action, path: $0).url }
    }

    private func restore() {
        guard let bookmark = defaults.data(forKey: key) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: Self.bookmarkResolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return
        }
        guard url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { return }
        accessedURL = url
        if isStale, let fresh = try? url.bookmarkData(options: Self.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: key)
        }
    }

    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}
