import FileCatKit
import Foundation

enum FileError: LocalizedError {
    case invalidName
    case nameTaken(String)
    case cannotMoveIntoItself(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Please enter a valid name."
        case .nameTaken(let name):
            "An item named “\(name)” already exists in this location."
        case .cannotMoveIntoItself(let name):
            "“\(name)” can't be moved into itself."
        }
    }
}

/// Thin, synchronous wrappers around FileManager used by the browser.
enum FileService {
    static let documentsDirectory = URL.documentsDirectory

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    private static var fileManager: FileManager { .default }

    // MARK: Reading

    static func contents(of directory: URL) throws -> [FileItem] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: []
        )
        let names = Set(urls.map(\.lastPathComponent))
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(".") else { return item(for: url) }
            // iCloud keeps files that aren't downloaded as hidden ".Name.icloud" stand-ins.
            guard let realName = cloudPlaceholderName(name), !names.contains(realName) else { return nil }
            return placeholderItem(url, realURL: directory.appending(path: realName))
        }
    }

    /// "Report.pdf" for ".Report.pdf.icloud".
    private static func cloudPlaceholderName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    private static func placeholderItem(_ placeholder: URL, realURL: URL) -> FileItem {
        // The stand-in is a small property list that remembers the real file's size.
        let info = (try? Data(contentsOf: placeholder))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let size = (info?["NSURLFileSizeKey"] as? NSNumber)?.int64Value
        let modified = (try? placeholder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return FileItem(
            url: realURL, name: realURL.lastPathComponent, isDirectory: false, size: size, modified: modified,
            created: nil, childCount: nil, kind: FileKind(url: realURL, isDirectory: false), tags: [], cloud: .notDownloaded
        )
    }

    /// Makes sure a cloud file's data is on the device, downloading it if needed. Local files
    /// return straight away.
    static func downloadIfNeeded(_ url: URL) async throws {
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let isPlaceholder = fileManager.fileExists(atPath: placeholder.path(percentEncoded: false))
        guard values?.isUbiquitousItem == true || isPlaceholder else {
            // Other cloud providers download on a coordinated read.
            try await Task.detached(priority: .userInitiated) {
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in }
                if let coordinationError { throw coordinationError }
            }.value
            return
        }
        if values?.ubiquitousItemDownloadingStatus == .current { return }
        try fileManager.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<6000 {
            try await Task.sleep(for: .milliseconds(200))
            var fresh = url
            fresh.removeAllCachedResourceValues()
            let status = (try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if status == .current || (status == nil && fileManager.fileExists(atPath: url.path(percentEncoded: false))) {
                return
            }
        }
        throw RemoteError.timedOut
    }

    /// Frees the space a downloaded cloud file uses; it stays in the cloud.
    static func removeDownload(_ url: URL) throws {
        try fileManager.evictUbiquitousItem(at: url)
    }

    static func item(for url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        // Packages (e.g. .rtfd, .pages) behave like single documents.
        let isDirectory = (values.isDirectory ?? false) && !(values.isPackage ?? false)
        var childCount: Int?
        if isDirectory {
            childCount = (try? fileManager.contentsOfDirectory(atPath: url.path(percentEncoded: false)))?
                .filter { !$0.hasPrefix(".") }
                .count
        }
        var cloud: CloudStatus?
        if values.isUbiquitousItem == true, !isDirectory {
            cloud = values.ubiquitousItemDownloadingStatus == .notDownloaded ? .notDownloaded : .downloaded
        }
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            size: values.fileSize.map(Int64.init),
            modified: values.contentModificationDate,
            created: values.creationDate,
            childCount: childCount,
            kind: FileKind(url: url, isDirectory: isDirectory),
            tags: FileTags.read(url),
            cloud: cloud
        )
    }

    /// Recursively finds items whose name or tags contain `query`.
    static func search(_ query: String, in directory: URL, limit: Int = 500) -> [FileItem] {
        var results: [FileItem] = []
        forEachDescendant(of: directory) { url in
            guard url.lastPathComponent.localizedStandardContains(query)
                    || FileTags.read(url).contains(where: { $0.localizedStandardContains(query) }),
                  let item = item(for: url)
            else { return true }
            results.append(item)
            return results.count < limit
        }
        return results
    }

    /// Every file and folder carrying `tag`, across several (possibly overlapping) roots.
    static func urls(taggedWith tag: String, in roots: [URL], limit: Int = 2000) -> [URL] {
        var seen = Set<String>()
        var results: [URL] = []
        for root in roots {
            forEachDescendant(of: root) { url in
                if FileTags.contains(FileTags.read(url), tag),
                   seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)).inserted {
                    results.append(url)
                }
                return results.count < limit
            }
        }
        return results
    }

    static func items(taggedWith tag: String, in roots: [URL]) -> [FileItem] {
        urls(taggedWith: tag, in: roots).compactMap(item(for:))
    }

    /// Walks everything below `directory`; return `false` from `body` to stop early.
    private static func forEachDescendant(of directory: URL, _ body: (URL) -> Bool) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator where !body(url) {
            break
        }
    }

    // MARK: Writing

    @discardableResult
    static func createFolder(named name: String, in directory: URL) throws -> URL {
        let clean = sanitized(name)
        let url = uniqueURL(for: clean.isEmpty ? "New Folder" : clean, in: directory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let name = sanitized(newName)
        guard !name.isEmpty, name != ".", name != ".." else { throw FileError.invalidName }
        guard name != url.lastPathComponent else { return url }

        let destination = url.deletingLastPathComponent().appending(path: name)
        let isCaseOnlyChange = name.lowercased() == url.lastPathComponent.lowercased()

        if isCaseOnlyChange {
            // Go through a temporary name so case-insensitive volumes accept the change.
            let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString)")
            try fileManager.moveItem(at: url, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
        } else {
            guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
                throw FileError.nameTaken(name)
            }
            try fileManager.moveItem(at: url, to: destination)
        }
        return destination
    }

    static func delete(_ urls: [URL]) throws {
        for url in urls {
            try fileManager.removeItem(at: url)
        }
    }

    static func duplicate(_ urls: [URL]) throws {
        for url in urls {
            let destination = uniqueURL(for: url.lastPathComponent, in: url.deletingLastPathComponent())
            try fileManager.copyItem(at: url, to: destination)
        }
    }

    static func copy(_ urls: [URL], to directory: URL) throws {
        for url in urls {
            try checkNotNested(url, in: directory)
            try fileManager.copyItem(at: url, to: uniqueURL(for: url.lastPathComponent, in: directory))
        }
    }

    static func move(_ urls: [URL], to directory: URL) throws {
        for url in urls {
            if isSameLocation(url.deletingLastPathComponent(), directory) { continue }
            try checkNotNested(url, in: directory)
            try fileManager.moveItem(at: url, to: uniqueURL(for: url.lastPathComponent, in: directory))
        }
    }

    /// Copies or moves items, reporting the bytes that have arrived so far. Stops between items
    /// when cancelled.
    static func transfer(
        _ urls: [URL],
        to directory: URL,
        move: Bool,
        cancellation: CancellationFlag,
        progress: @escaping @Sendable (Int64) -> Void
    ) throws {
        var done: Int64 = 0
        for url in urls {
            if cancellation.isCancelled { throw CancellationError() }
            if move, isSameLocation(url.deletingLastPathComponent(), directory) { continue }
            try checkNotNested(url, in: directory)
            let destination = uniqueURL(for: url.lastPathComponent, in: directory)
            let size = ArchiveService.totalSize(of: [url])
            // The system copies in one go, so watch the destination grow meanwhile.
            let finished = CancellationFlag()
            let base = done
            let watcher = Thread {
                while !finished.isCancelled {
                    Thread.sleep(forTimeInterval: 0.3)
                    if finished.isCancelled { break }
                    progress(base + ArchiveService.totalSize(of: [destination]))
                }
            }
            watcher.start()
            defer { finished.cancel() }
            if move {
                try fileManager.moveItem(at: url, to: destination)
            } else {
                try fileManager.copyItem(at: url, to: destination)
            }
            finished.cancel()
            done += size
            progress(done)
        }
    }

    /// Copies files the user picked from outside the app (Files, iCloud Drive, other apps).
    @discardableResult
    static func importFiles(_ urls: [URL], into directory: URL) throws -> [URL] {
        var imported: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let destination = uniqueURL(for: url.lastPathComponent, in: directory)
            try fileManager.copyItem(at: url, to: destination)
            imported.append(destination)
        }
        return imported
    }

    // MARK: Helpers

    static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func isSameLocation(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == b.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func checkNotNested(_ url: URL, in directory: URL) throws {
        if isSameLocation(url, directory) || isInside(directory, url) {
            throw FileError.cannotMoveIntoItself(url.lastPathComponent)
        }
    }

    /// Returns `name` in `directory`, or "name 2", "name 3"… if it's taken.
    static func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appending(path: name)
        guard fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appending(path: numbered)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path(percentEncoded: false))
        return candidate
    }

    static func sanitized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
