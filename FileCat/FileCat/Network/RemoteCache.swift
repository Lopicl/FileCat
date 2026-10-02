import CryptoKit
import FileCatKit
import Foundation
import Observation

/// A file or folder on a server.
struct RemoteItem: Hashable, Identifiable, Sendable {
    let sourceID: String
    /// Absolute path within the source; "/" is the root.
    let path: String
    let name: String
    let isDirectory: Bool
    var size: Int64?
    var modified: Date?

    var id: String { sourceID + ":" + path }

    var kind: FileKind {
        FileKind(url: URL(filePath: name), isDirectory: isDirectory)
    }

    static func root(of source: NetworkSource) -> RemoteItem {
        RemoteItem(sourceID: source.id, path: "/", name: source.name, isDirectory: true)
    }

    func child(_ entry: RemoteEntry) -> RemoteItem {
        RemoteItem(
            sourceID: sourceID, path: RemotePath.join(path, entry.name), name: entry.name,
            isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified
        )
    }

    /// The item as the rest of the app sees it: a `FileItem` pointing at where the local copy
    /// lives (or will live), so thumbnails and viewers work once it's downloaded.
    var fileItem: FileItem {
        FileItem(
            url: RemoteCache.localURL(for: self), name: name, isDirectory: isDirectory, size: size,
            modified: modified, created: nil, childCount: nil, kind: kind, tags: []
        )
    }
}

/// Where downloaded copies of remote files live.
///
/// - `Caches/Remote/<source>/<path>` holds files opened recently. iOS may purge it when space is
///   low, and Settings → Clear Cache empties it.
/// - `Application Support/Offline/<source>/<path>` holds files the user chose to keep offline.
///   They stay until the user removes them, and are refreshed when they change on the server.
/// - `Caches/Streams/<source>/` holds the parts of videos and songs played from a server
///   (`PartialFile`), so they aren't fetched twice. A file that streamed in completely moves to
///   `Caches/Remote`.
enum RemoteCache {
    static let cacheRoot = URL.cachesDirectory.appending(path: "Remote", directoryHint: .isDirectory)
    static let offlineRoot = URL.applicationSupportDirectory.appending(path: "Offline", directoryHint: .isDirectory)
    static let streamRoot = URL.cachesDirectory.appending(path: "Streams", directoryHint: .isDirectory)

    private static var fileManager: FileManager { .default }

    static func cacheURL(sourceID: String, path: String) -> URL {
        url(in: cacheRoot, sourceID: sourceID, path: path)
    }

    static func offlineURL(sourceID: String, path: String) -> URL {
        url(in: offlineRoot, sourceID: sourceID, path: path)
    }

    private static func url(in root: URL, sourceID: String, path: String) -> URL {
        RemotePath.components(of: path).reduce(root.appending(path: sourceID, directoryHint: .isDirectory)) {
            $0.appending(path: $1)
        }
    }

    /// Where the streamed parts of `item` go. The name comes from the path, size and date, so a
    /// file that changed on the server starts afresh.
    static func streamURL(for item: RemoteItem) -> URL {
        let key = "\(item.path)\n\(item.size ?? -1)\n\(item.modified?.timeIntervalSince1970 ?? 0)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return streamRoot.appending(path: item.sourceID, directoryHint: .isDirectory).appending(path: name)
    }

    static func removeStream(at url: URL) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: url.appendingPathExtension("chunks"))
    }

    /// The offline copy if there is one, otherwise the cache location.
    static func localURL(for item: RemoteItem) -> URL {
        let offline = offlineURL(sourceID: item.sourceID, path: item.path)
        return fileManager.fileExists(atPath: offline.path(percentEncoded: false))
            ? offline
            : cacheURL(sourceID: item.sourceID, path: item.path)
    }

    /// An up-to-date local copy, if one exists.
    static func availableURL(for item: RemoteItem) -> URL? {
        for url in [offlineURL(sourceID: item.sourceID, path: item.path), cacheURL(sourceID: item.sourceID, path: item.path)]
            where isCurrent(url, for: item) {
            return url
        }
        return nil
    }

    static func isOffline(_ item: RemoteItem) -> Bool {
        isCurrent(offlineURL(sourceID: item.sourceID, path: item.path), for: item)
    }

    /// A local copy counts as current when its size and date match the server's.
    static func isCurrent(_ url: URL, for item: RemoteItem) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
              values.isDirectory != true
        else { return false }
        if let size = item.size, Int64(values.fileSize ?? -1) != size { return false }
        if let modified = item.modified, let local = values.contentModificationDate,
           abs(local.timeIntervalSince(modified)) > 1 {
            return false
        }
        return true
    }

    /// Moves a finished download into place and stamps it with the server's date.
    static func store(_ temporary: URL, for item: RemoteItem, offline: Bool) throws -> URL {
        let destination = offline
            ? offlineURL(sourceID: item.sourceID, path: item.path)
            : cacheURL(sourceID: item.sourceID, path: item.path)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if offline {
            var root = offlineRoot
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        if let modified = item.modified {
            try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path(percentEncoded: false))
        }
        if offline {
            // An offline copy replaces the cached one.
            try? fileManager.removeItem(at: cacheURL(sourceID: item.sourceID, path: item.path))
        }
        return destination
    }

    static func removeLocalCopies(of item: RemoteItem) {
        try? fileManager.removeItem(at: cacheURL(sourceID: item.sourceID, path: item.path))
        try? fileManager.removeItem(at: offlineURL(sourceID: item.sourceID, path: item.path))
        removeStream(at: streamURL(for: item))
    }

    static func removeAll(for sourceID: String) {
        try? fileManager.removeItem(at: cacheRoot.appending(path: sourceID))
        try? fileManager.removeItem(at: offlineRoot.appending(path: sourceID))
        try? fileManager.removeItem(at: streamRoot.appending(path: sourceID))
    }

    static func temporaryURL(for name: String) -> URL {
        let folder = URL.temporaryDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: UUID().uuidString + "-" + name)
    }
}

/// Tracks downloads and offline files so every screen shows the same state.
@MainActor
@Observable
final class TransferCenter {
    /// Download progress (0...1) for items being fetched, keyed by `RemoteItem.id`.
    private(set) var progress: [String: Double] = [:]
    /// Bumped whenever local copies change, so rows recompute their status.
    private(set) var revision = 0
    /// Paths the user keeps offline, per source. Folders include everything inside them.
    private(set) var pins: [String: Set<String>] = [:]
    private(set) var isSyncing = false
    /// Bumped after changes on a server (upload, rename, delete…) so open folders reload.
    private(set) var listingRevision = 0
    private(set) var uploads: [Upload] = []

    struct Upload: Identifiable {
        let id = UUID()
        let folder: RemoteItem
        let name: String
        var fraction: Double = 0
    }

    @ObservationIgnored private let sources: SourceStore
    @ObservationIgnored private var running: [String: Task<URL, Error>] = [:]
    @ObservationIgnored private var activeDownloads: [String: ActiveDownload] = [:]
    /// Streamed parts in use, by path, so everything playing the same file shares them.
    @ObservationIgnored private var partialFiles: [String: WeakPartialFile] = [:]
    private static let pinsKey = "offlinePins"

    init(sources: SourceStore) {
        self.sources = sources
        if let saved = UserDefaults.standard.dictionary(forKey: Self.pinsKey) as? [String: [String]] {
            pins = saved.mapValues(Set.init)
        }
    }

    enum Status {
        case remote, downloading(Double), cached, offline
    }

    func status(of item: RemoteItem) -> Status {
        _ = revision
        if let fraction = progress[item.id] { return .downloading(fraction) }
        if item.isDirectory { return isPinned(item) ? .offline : .remote }
        if RemoteCache.isOffline(item) { return .offline }
        return RemoteCache.availableURL(for: item) != nil ? .cached : .remote
    }

    func isPinned(_ item: RemoteItem) -> Bool {
        guard let paths = pins[item.sourceID] else { return false }
        return paths.contains { $0 == item.path || $0 == "/" || item.path.hasPrefix($0 + "/") }
    }

    func fileSystem(for sourceID: String) async throws -> any RemoteFileSystem {
        guard let source = sources.source(id: sourceID) else { throw RemoteError.notFound("Server") }
        return try await RemoteConnections.shared.fileSystem(for: source)
    }

    /// Returns a current local copy, downloading it first if needed.
    @discardableResult
    func localCopy(of item: RemoteItem) async throws -> URL {
        if let url = RemoteCache.availableURL(for: item) { return url }
        return try await startDownload(item).value
    }

    /// Starts downloading `item` into the cache (or offline storage), or joins the download
    /// that's already running.
    private func startDownload(_ item: RemoteItem) -> Task<URL, Error> {
        if let task = running[item.id] { return task }

        let temporary = RemoteCache.temporaryURL(for: item.name)
        // SMB, NFS, SFTP and FTP write the file front to back as it arrives; WebDAV hands it over at the end.
        let kind = sources.source(id: item.sourceID)?.kind
        let active = ActiveDownload(temporaryURL: temporary, isProgressive: kind.map { ![.webdav, .nextcloud].contains($0) } ?? false)
        let activityID = ActivityCenter.shared.begin(.download, name: item.name) { [weak self] in
            self?.cancelDownload(of: item)
        }
        let task = Task { [weak self] () throws -> URL in
            defer {
                try? FileManager.default.removeItem(at: temporary)
                if let self {
                    self.running[item.id] = nil
                    self.activeDownloads[item.id] = nil
                    self.progress[item.id] = nil
                    self.revision += 1
                }
            }
            guard let self else { throw CancellationError() }
            do {
                let fileSystem = try await self.fileSystem(for: item.sourceID)
                let total = Double(max(item.size ?? 0, 1))
                let reporter = ProgressReporter { [weak self] bytes in
                    // A late report must not bring back a finished download's progress.
                    guard let self, self.running[item.id] != nil else { return }
                    self.progress[item.id] = min(1, Double(bytes) / total)
                    ActivityCenter.shared.update(activityID, fraction: Double(bytes) / total)
                }
                try await fileSystem.download(item.path, to: temporary) { bytes in
                    active.didWrite(bytes)
                    reporter.report(bytes)
                }
                // Checked at the end: Keep Offline may join a download that was already running.
                let url = try RemoteCache.store(temporary, for: item, offline: self.isPinned(item))
                active.finish(at: url)
                ActivityCenter.shared.end(activityID)
                return url
            } catch {
                active.finish(at: nil)
                let error = Task.isCancelled ? CancellationError() : error
                ActivityCenter.shared.end(activityID, error: error)
                throw error
            }
        }
        running[item.id] = task
        activeDownloads[item.id] = active
        progress[item.id] = 0
        return task
    }

    func cancelDownload(of item: RemoteItem) {
        running[item.id]?.cancel()
    }

    // MARK: Streaming

    /// Something to play `item` from the server, or `nil` when it's already on the device (or its
    /// size isn't known, which streaming needs). Only the parts that get played are fetched; they're
    /// kept in the cache, and a file that streamed in completely counts as downloaded.
    func stream(for item: RemoteItem) async throws -> RemoteStream? {
        guard let size = item.size, size > 0, RemoteCache.availableURL(for: item) == nil else { return nil }
        let fileSystem = try await fileSystem(for: item.sourceID)
        guard RemoteCache.availableURL(for: item) == nil else { return nil }
        return RemoteStream(
            path: item.path, name: item.name, size: size, fileSystem: fileSystem,
            download: activeDownloads[item.id], partial: partialFile(for: item, size: size), readAhead: 4
        )
    }

    /// An asset that plays `item` from the server.
    func streamingAsset(for item: RemoteItem) async throws -> StreamingAsset? {
        guard let stream = try await stream(for: item) else { return nil }
        return StreamingAsset(stream: stream)
    }

    private func partialFile(for item: RemoteItem, size: Int64) -> PartialFile? {
        let url = RemoteCache.streamURL(for: item)
        if let file = partialFiles[url.path]?.file { return file }
        let file = PartialFile(url: url, size: size) { [weak self] url in
            Task { @MainActor in self?.didFinishStreaming(item, at: url) }
        }
        partialFiles = partialFiles.filter { $0.value.file != nil }
        partialFiles[url.path] = WeakPartialFile(file: file)
        return file
    }

    /// Every part of `item` has streamed in: keep it as an ordinary cached copy.
    private func didFinishStreaming(_ item: RemoteItem, at url: URL) {
        partialFiles[url.path] = nil
        // Players still reading it keep their open file, so it can go right away.
        defer { RemoteCache.removeStream(at: url) }
        guard RemoteCache.availableURL(for: item) == nil else { return }
        let copy = RemoteCache.temporaryURL(for: item.name)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            _ = try RemoteCache.store(copy, for: item, offline: isPinned(item))
            revision += 1
        } catch {
            try? FileManager.default.removeItem(at: copy)
        }
    }

    // MARK: Offline

    func keepOffline(_ item: RemoteItem) async throws {
        pins[item.sourceID, default: []].insert(item.path)
        savePins()
        do {
            try await sync(item)
        } catch is CancellationError where !item.isDirectory {
            // Cancelling the download takes the file off the offline list again, so the next
            // sync doesn't start it over.
            unpin(item)
            throw CancellationError()
        }
    }

    func removeDownload(_ item: RemoteItem) {
        unpin(item)
        RemoteCache.removeLocalCopies(of: item)
        revision += 1
    }

    private func unpin(_ item: RemoteItem) {
        guard var paths = pins[item.sourceID] else { return }
        paths = paths.filter { $0 != item.path && !$0.hasPrefix(item.path == "/" ? "/" : item.path + "/") }
        pins[item.sourceID] = paths.isEmpty ? nil : paths
        savePins()
    }

    func removeAllOffline() {
        pins = [:]
        savePins()
        try? FileManager.default.removeItem(at: RemoteCache.offlineRoot)
        revision += 1
    }

    /// Brings every offline item of every source up to date.
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for (sourceID, paths) in pins {
            guard let source = sources.source(id: sourceID) else { continue }
            for path in paths {
                let root = RemoteItem(sourceID: sourceID, path: path, name: path == "/" ? source.name : RemotePath.name(of: path), isDirectory: true)
                try? await sync(root, probe: true)
            }
        }
    }

    /// Downloads new and changed files, and removes local copies of files deleted on the server.
    private func sync(_ item: RemoteItem, probe: Bool = false) async throws {
        let fileSystem = try await fileSystem(for: item.sourceID)
        var target = item
        if probe {
            // Pins store only the path; find out whether it's a file or a folder, and its size.
            let parent = RemotePath.parent(of: item.path)
            let entries = try await fileSystem.list(parent)
            guard let entry = entries.first(where: { $0.name == RemotePath.name(of: item.path) }) else { return }
            target = RemoteItem(sourceID: item.sourceID, path: parent, name: "", isDirectory: true).child(entry)
            if item.path == "/" { target = item }
        }
        if !target.isDirectory {
            if !RemoteCache.isOffline(target) {
                // The shared download, so the viewer's and the activity list's Cancel reach it.
                try await startDownload(target).value
            }
            return
        }
        let entries = try await fileSystem.list(target.path)
        let names = Set(entries.map(\.name))
        let folder = RemoteCache.offlineURL(sourceID: target.sourceID, path: target.path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for local in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            where !names.contains(local) {
            try? FileManager.default.removeItem(at: folder.appending(path: local))
        }
        for entry in entries {
            try Task.checkCancellation()
            do {
                try await sync(target.child(entry))
            } catch is CancellationError where !Task.isCancelled {
                // The user cancelled this file's download; carry on with the rest of the folder.
            }
        }
        revision += 1
    }

    /// Copies a remote file or folder into a local folder.
    @discardableResult
    func save(_ item: RemoteItem, to directory: URL) async throws -> URL {
        let destination = FileService.uniqueURL(for: item.name, in: directory)
        if item.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let fileSystem = try await fileSystem(for: item.sourceID)
            for entry in try await fileSystem.list(item.path) {
                try await save(item.child(entry), to: destination)
            }
        } else {
            let local = try await localCopy(of: item)
            try FileManager.default.copyItem(at: local, to: destination)
        }
        return destination
    }

    /// Call after changing something on the server so cached listings and copies refresh.
    func didModify(_ item: RemoteItem) {
        RemoteCache.removeLocalCopies(of: item)
        revision += 1
    }

    func didChangeListing() {
        listingRevision += 1
    }

    /// Sends a locally edited copy of a server file back to the server.
    func uploadEdited(_ local: URL, to item: RemoteItem) async throws {
        let fileSystem = try await fileSystem(for: item.sourceID)
        try await fileSystem.upload(local, to: item.path) { _ in }
        // The local copy already matches; stamp it with the new date so it still counts as current.
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: local.path(percentEncoded: false))
        revision += 1
        listingRevision += 1
    }

    /// Uploads an edited local copy of `item` once the text editor has saved it.
    func saveHandler(for item: RemoteItem) -> FileSaveHandler {
        FileSaveHandler { [weak self] url in
            try await self?.uploadEdited(url, to: item)
        }
    }

    /// Creates an empty text file in a server folder and returns it.
    func createTextFile(named name: String, in folder: RemoteItem) async throws -> RemoteItem {
        var clean = FileService.sanitized(name)
        if clean.isEmpty { clean = "New Text File" }
        if (clean as NSString).pathExtension.isEmpty { clean += ".txt" }
        let fileSystem = try await fileSystem(for: folder.sourceID)
        let taken = Set(try await fileSystem.list(folder.path).map { $0.name.lowercased() })
        clean = Self.uniqueName(clean, taken: taken)
        let empty = RemoteCache.temporaryURL(for: clean)
        FileManager.default.createFile(atPath: empty.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: empty) }
        try await fileSystem.upload(empty, to: RemotePath.join(folder.path, clean)) { _ in }
        listingRevision += 1
        return folder.child(RemoteEntry(name: clean, isDirectory: false, size: 0, modified: nil))
    }

    /// Uploads files picked in the document picker. They're copied to a temporary folder first,
    /// because access to picked files doesn't last.
    func upload(_ urls: [URL], to folder: RemoteItem) throws {
        var staged: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let copy = RemoteCache.temporaryURL(for: url.lastPathComponent)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: copy) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
            staged.append(copy)
        }
        let names = zip(urls, staged).map { original, copy in
            // Folders come through as zip archives when coordinated for uploading.
            copy.pathExtension == "zip" && original.pathExtension != "zip" ? original.lastPathComponent + ".zip" : original.lastPathComponent
        }
        Task {
            await upload(staged, names: names, to: folder)
        }
    }

    private func upload(_ files: [URL], names: [String], to folder: RemoteItem) async {
        let entries = zip(files, names).map { (file: $0, upload: Upload(folder: folder, name: $1)) }
        uploads += entries.map(\.upload)
        defer {
            uploads.removeAll { upload in entries.contains { $0.upload.id == upload.id } }
            for entry in entries { try? FileManager.default.removeItem(at: entry.file) }
            listingRevision += 1
        }
        do {
            let fileSystem = try await fileSystem(for: folder.sourceID)
            var taken = Set(try await fileSystem.list(folder.path).map { $0.name.lowercased() })
            for entry in entries {
                let name = Self.uniqueName(entry.upload.name, taken: taken)
                taken.insert(name.lowercased())
                let size = Double(max(1, (try? entry.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1))
                let id = entry.upload.id
                let activityID = ActivityCenter.shared.begin(.upload, name: name)
                let reporter = ProgressReporter { [weak self] bytes in
                    ActivityCenter.shared.update(activityID, fraction: Double(bytes) / size)
                    guard let self, let index = self.uploads.firstIndex(where: { $0.id == id }) else { return }
                    self.uploads[index].fraction = min(1, Double(bytes) / size)
                }
                do {
                    try await fileSystem.upload(entry.file, to: RemotePath.join(folder.path, name)) { reporter.report($0) }
                    ActivityCenter.shared.end(activityID)
                } catch {
                    ActivityCenter.shared.end(activityID, error: error)
                    throw error
                }
            }
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// Set when an upload fails; shown in an alert by the app window.
    var uploadError: String?

    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    private func savePins() {
        UserDefaults.standard.set(pins.mapValues(Array.init), forKey: Self.pinsKey)
    }
}

private struct WeakPartialFile {
    weak var file: PartialFile?
}

/// Forwards byte counts from a network callback to the main actor, at most every 1%.
final class ProgressReporter: @unchecked Sendable {
    private let update: @MainActor (Int64) -> Void
    private let lock = NSLock()
    private var lastReported: Int64 = -1
    private var lastTime = Date.distantPast

    init(update: @escaping @MainActor (Int64) -> Void) {
        self.update = update
    }

    func report(_ bytes: Int64) {
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastTime) > 0.1
        if due {
            lastTime = now
            lastReported = bytes
        }
        lock.unlock()
        guard due else { return }
        Task { @MainActor [update] in update(bytes) }
    }
}
