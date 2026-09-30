import FileCatKit
import Foundation

enum CloudStatus: Hashable, Sendable {
    /// Only in the cloud; opening it downloads it.
    case notDownloaded
    /// Downloaded, and can be removed from the device again.
    case downloaded
}

/// A snapshot of a file or folder on disk.
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    /// Number of visible entries, for folders only.
    let childCount: Int?
    let kind: FileKind
    /// Tag names, in the order they were added.
    let tags: [String]
    /// For files in iCloud Drive (or another cloud provider): whether the data is on this device.
    var cloud: CloudStatus?

    var id: URL { url }

    var parentName: String {
        url.deletingLastPathComponent().lastPathComponent
    }

    var formattedSize: String? {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    var formattedItemCount: String? {
        childCount.map { $0 == 1 ? "1 item" : "\($0) items" }
    }

    /// "Sep 28, 2026 at 2:53 PM – 1.2 MB"
    var subtitle: String {
        var parts: [String] = []
        if let modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        if let detail = isDirectory ? formattedItemCount : formattedSize {
            parts.append(detail)
        }
        return parts.joined(separator: " – ")
    }
}
