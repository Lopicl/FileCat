import Foundation
import UniformTypeIdentifiers

/// The broad category of a file, used to pick an icon and a viewer.
public enum FileKind: Hashable, Sendable {
    case folder
    case image
    case video
    case audio
    case pdf
    case markdown
    case text
    case archive
    case other

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    /// Extensions that are plain text but aren't always recognised by UTType.
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "ini", "cfg", "conf", "toml", "yml", "yaml", "env",
        "srt", "vtt", "csv", "tsv", "json", "xml", "gitignore", "properties",
    ]

    /// Archives and compressed files FileCat can open, some of which UTType doesn't know.
    public static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma", "tlz",
        "zst", "tzst", "lz4", "z", "cab", "iso", "lha", "lzh", "xar", "cpio",
    ]

    public init(url: URL, isDirectory: Bool) {
        if isDirectory {
            self = .folder
            return
        }
        let ext = url.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
            return
        }
        if Self.textExtensions.contains(ext) {
            self = .text
            return
        }
        if Self.archiveExtensions.contains(ext) {
            self = .archive
            return
        }
        guard let type = UTType(filenameExtension: ext) else {
            self = .other
            return
        }
        if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else if type.conforms(to: .archive) {
            self = .archive
        } else if type.conforms(to: .rtf) || type.conforms(to: .html) || type.conforms(to: .propertyList) {
            // Rich formats look better rendered by Quick Look than as raw text.
            self = .other
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            self = .text
        } else {
            self = .other
        }
    }
}
