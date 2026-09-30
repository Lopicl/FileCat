import Foundation

/// A file or folder inside an archive.
struct ArchiveEntry: Hashable, Sendable {
    /// "Folder/File.txt": no leading or trailing slash, no "." or ".." components.
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let isEncrypted: Bool

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var parent: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

enum ArchiveError: LocalizedError, Equatable {
    case cannotOpen(String)
    case passwordRequired
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let reason): "The archive couldn't be opened. \(reason)"
        case .passwordRequired: "This archive is protected with a password."
        case .failed(let reason): reason
        }
    }
}

/// Formats FileCat can create.
enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, sevenZip, tarGz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7-Zip"
        case .tarGz: "TAR.GZ"
        }
    }

    var pathExtension: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tarGz: "tar.gz"
        }
    }
}

/// Lets a long archive operation be stopped from another thread.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// Reads and writes archives with libarchive, which comes with iOS: ZIP, RAR (4 and 5), 7-Zip,
/// TAR (plain, gzip, bzip2, xz, zstd…), ISO, CAB, LHA, XAR and single compressed files (.gz, .bz2,
/// .xz). ZIP, 7-Zip and TAR.GZ can be created. Everything here blocks; call it off the main thread.
enum ArchiveService {
    private static let bufferSize = 256 * 1024

    /// libarchive converts names through the C library's character set, which is plain ASCII
    /// until an app picks one; without UTF-8, names with accents or emoji can't be read or written.
    private static let localePrepared: Void = {
        setlocale(LC_CTYPE, "UTF-8")
    }()

    // MARK: Reading

    /// Every entry in the archive, in archive order.
    static func list(_ url: URL, password: String?) throws -> [ArchiveEntry] {
        let reader = try Reader(url: url, password: password)
        var entries: [ArchiveEntry] = []
        while let entry = try reader.nextEntry() {
            entries.append(entry.info)
        }
        return entries
    }

    /// Extracts the whole archive, or just `entryPath` (a file, or a folder and everything in it),
    /// into `directory`. A single top-level item keeps its name; several are gathered in a folder
    /// named after the archive. Returns the item that was created.
    @discardableResult
    static func extract(
        _ url: URL,
        password: String?,
        entryPath: String? = nil,
        into directory: URL,
        cancellation: CancellationFlag? = nil,
        progress: ((Int64) -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        // Unpack next to the destination first, so a failed or cancelled extraction leaves nothing
        // half-written behind and the final move is instant.
        let staging = directory.appending(path: ".FileCat-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // Paths are written relative to the selected entry's parent folder.
        let prefix = entryPath.map { path -> String in
            let parent = ArchiveEntry(path: path, isDirectory: false, size: nil, modified: nil, isEncrypted: false).parent
            return parent.isEmpty ? "" : parent + "/"
        } ?? ""

        let reader = try Reader(url: url, password: password)
        var written: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var dates: [(URL, Date)] = []
        while let entry = try reader.nextEntry() {
            if cancellation?.isCancelled == true { throw CancellationError() }
            let info = entry.info
            if let entryPath, info.path != entryPath, !info.path.hasPrefix(entryPath + "/") { continue }
            let relative = String(info.path.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            let target = staging.appending(path: relative, directoryHint: info.isDirectory ? .isDirectory : .notDirectory)
            if info.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fileManager.createFile(atPath: target.path(percentEncoded: false), contents: nil) else {
                    throw ArchiveError.failed("“\(info.name)” couldn't be written.")
                }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                while true {
                    if cancellation?.isCancelled == true { throw CancellationError() }
                    let count = try reader.readData(into: &buffer)
                    if count == 0 { break }
                    try handle.write(contentsOf: Data(buffer[0..<count]))
                    written += Int64(count)
                    progress?(written)
                }
            }
            if let modified = info.modified { dates.append((target, modified)) }
            // A single file: no need to read through the rest of the archive.
            if info.path == entryPath, !info.isDirectory { break }
        }
        // Folder dates change while their contents are written, so set them all at the end.
        for (target, date) in dates.reversed() {
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: target.path(percentEncoded: false))
        }

        let created = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard !created.isEmpty else {
            throw ArchiveError.failed(entryPath == nil ? "The archive is empty." : "The item wasn't found in the archive.")
        }
        let destination: URL
        if created.count == 1 {
            destination = FileService.uniqueURL(for: created[0].lastPathComponent, in: directory)
            try fileManager.moveItem(at: created[0], to: destination)
        } else {
            destination = FileService.uniqueURL(for: baseName(of: url), in: directory)
            try fileManager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    /// "Photos" for "Photos.tar.gz".
    static func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4", ".tar.lzma", ".tar.z"] where lower.hasSuffix(compound) {
            return String(name.dropLast(compound.count))
        }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty { name = (name as NSString).deletingPathExtension }
        return name.isEmpty ? "Archive" : name
    }

    // MARK: Writing

    /// Packs files and folders into a new archive in `directory` and returns it. The archive is
    /// named after the item, or "Archive" for several.
    @discardableResult
    static func compress(
        _ urls: [URL],
        format: ArchiveFormat,
        into directory: URL,
        cancellation: CancellationFlag? = nil,
        progress: ((Int64) -> Void)? = nil
    ) throws -> URL {
        _ = localePrepared
        let fileManager = FileManager.default
        let baseName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let temporary = directory.appending(path: ".FileCat-compress-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        guard let archive = archive_write_new() else { throw ArchiveError.failed("The archive couldn't be created.") }
        defer { archive_write_free(archive) }
        switch format {
        case .zip:
            archive_write_set_format_zip(archive)
            _ = archive_write_set_options(archive, "zip:hdrcharset=UTF-8")
        case .sevenZip:
            archive_write_set_format_7zip(archive)
        case .tarGz:
            archive_write_set_format_pax_restricted(archive)
            archive_write_add_filter_gzip(archive)
        }
        let opened = temporary.withUnsafeFileSystemRepresentation { archive_write_open_filename(archive, $0) }
        guard opened == ARCHIVE_OK else { throw ArchiveError.failed(errorMessage(archive)) }

        var read: Int64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]

        func add(_ url: URL, as name: String) throws {
            if cancellation?.isCancelled == true { throw CancellationError() }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { return }
            let isDirectory = values.isDirectory == true
            guard let entry = archive_entry_new() else { return }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, isDirectory ? name + "/" : name)
            archive_entry_set_filetype(entry, UInt32(isDirectory ? AE_IFDIR : AE_IFREG))
            archive_entry_set_perm(entry, mode_t(isDirectory ? 0o755 : 0o644))
            archive_entry_set_size(entry, isDirectory ? 0 : Int64(values.fileSize ?? 0))
            if let modified = values.contentModificationDate {
                archive_entry_set_mtime(entry, time_t(modified.timeIntervalSince1970), 0)
            }
            guard archive_write_header(archive, entry) >= ARCHIVE_WARN else {
                throw ArchiveError.failed(errorMessage(archive))
            }
            if isDirectory {
                let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for child in children where child.lastPathComponent != ".DS_Store" {
                    try add(child, as: name + "/" + child.lastPathComponent)
                }
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: bufferSize), !data.isEmpty {
                    if cancellation?.isCancelled == true { throw CancellationError() }
                    let written = data.withUnsafeBytes { archive_write_data(archive, $0.baseAddress, data.count) }
                    guard written >= 0 else { throw ArchiveError.failed(errorMessage(archive)) }
                    read += Int64(data.count)
                    progress?(read)
                }
            }
        }

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try add(url, as: url.lastPathComponent)
        }
        guard archive_write_close(archive) == ARCHIVE_OK else { throw ArchiveError.failed(errorMessage(archive)) }

        let destination = FileService.uniqueURL(for: baseName + "." + format.pathExtension, in: directory)
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Total size of files and folders, for progress while compressing.
    static func totalSize(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                while let child = enumerator?.nextObject() as? URL {
                    total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: libarchive

    fileprivate static func errorMessage(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "Unknown error."
    }

    /// Wraps a libarchive read handle.
    private final class Reader {
        struct Entry {
            let info: ArchiveEntry
        }

        private let archive: OpaquePointer
        private let archiveName: String
        private var isRaw = false

        init(url: URL, password: String?) throws {
            _ = ArchiveService.localePrepared
            guard let archive = archive_read_new() else { throw ArchiveError.cannotOpen("") }
            self.archive = archive
            archiveName = url.lastPathComponent
            archive_read_support_filter_all(archive)
            // Not "all": that includes text formats such as mtree, which would claim any
            // compressed text file.
            archive_read_support_format_7zip(archive)
            archive_read_support_format_cab(archive)
            archive_read_support_format_cpio(archive)
            archive_read_support_format_iso9660(archive)
            archive_read_support_format_lha(archive)
            archive_read_support_format_rar(archive)
            archive_read_support_format_rar5(archive)
            archive_read_support_format_tar(archive)
            archive_read_support_format_xar(archive)
            archive_read_support_format_zip(archive)
            // Single compressed files (notes.txt.gz) have no archive format; "raw" reads them.
            archive_read_support_format_raw(archive)
            if let password, !password.isEmpty {
                archive_read_add_passphrase(archive, password)
            }
            let result = url.withUnsafeFileSystemRepresentation { archive_read_open_filename(archive, $0, 64 * 1024) }
            guard result == ARCHIVE_OK else {
                let message = ArchiveService.errorMessage(archive)
                archive_read_free(archive)
                throw Self.error(from: message, opening: true)
            }
        }

        deinit {
            archive_read_free(archive)
        }

        func nextEntry() throws -> Entry? {
            while true {
                var entry: OpaquePointer?
                let result = archive_read_next_header(archive, &entry)
                if result == ARCHIVE_EOF { return nil }
                guard result >= ARCHIVE_WARN, let entry else {
                    throw Self.error(from: ArchiveService.errorMessage(archive), opening: false)
                }
                isRaw = archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_RAW
                let type = Int32(archive_entry_filetype(entry))
                // Links, devices and the like aren't extracted.
                guard type == AE_IFREG || type == AE_IFDIR || isRaw else { continue }

                let rawName = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
                var path = rawName.map { String(cString: $0) } ?? ""
                if isRaw {
                    // A single compressed file: it's the archive's name without ".gz".
                    path = (archiveName as NSString).deletingPathExtension
                }
                let isDirectory = type == AE_IFDIR || path.hasSuffix("/")
                path = path.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.isEmpty }.joined(separator: "/")
                guard !path.isEmpty else { continue }
                let info = ArchiveEntry(
                    path: path,
                    isDirectory: isDirectory,
                    size: !isDirectory && archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
                    modified: archive_entry_mtime_is_set(entry) != 0 ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil,
                    isEncrypted: archive_entry_is_encrypted(entry) != 0
                )
                return Entry(info: info)
            }
        }

        /// Reads the current entry's data; 0 at its end.
        func readData(into buffer: inout [UInt8]) throws -> Int {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            guard count >= 0 else {
                throw Self.error(from: ArchiveService.errorMessage(archive), opening: false)
            }
            return count
        }

        private static func error(from message: String, opening: Bool) -> ArchiveError {
            let lower = message.lowercased()
            if lower.contains("passphrase") || lower.contains("password") || lower.contains("encrypt") {
                return .passwordRequired
            }
            return opening ? .cannotOpen(message) : .failed(message)
        }
    }
}

/// An archive's entries arranged as folders, including folders that only appear in paths.
struct ArchiveIndex: Sendable {
    let entries: [ArchiveEntry]
    private let children: [String: [ArchiveEntry]]

    init(entries: [ArchiveEntry]) {
        var byPath: [String: ArchiveEntry] = [:]
        for entry in entries {
            byPath[entry.path] = entry
            // Make sure every parent folder exists, even if the archive doesn't list it.
            var parent = entry.parent
            while !parent.isEmpty, byPath[parent] == nil {
                byPath[parent] = ArchiveEntry(path: parent, isDirectory: true, size: nil, modified: nil, isEncrypted: false)
                parent = byPath[parent]!.parent
            }
        }
        self.entries = Array(byPath.values)
        children = Dictionary(grouping: byPath.values, by: \.parent)
    }

    func children(of path: String) -> [ArchiveEntry] {
        children[path] ?? []
    }

    /// Uncompressed size of an entry, or of everything in a folder (`""` for the whole archive).
    func size(of path: String) -> Int64 {
        entries
            .filter { !$0.isDirectory && (path.isEmpty || $0.path == path || $0.path.hasPrefix(path + "/")) }
            .reduce(0) { $0 + ($1.size ?? 0) }
    }
}
