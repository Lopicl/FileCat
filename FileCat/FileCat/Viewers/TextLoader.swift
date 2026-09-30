import Foundation

enum TextLoader {
    enum LoadError: LocalizedError {
        case notText
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notText: "This file doesn't appear to contain readable text."
            case .tooLarge: "This file is too large to edit (the limit is \(TextLoader.maxEditableBytes / 1_048_576) MB)."
            }
        }
    }

    /// A whole file as text, with what's needed to write it back the same way.
    struct EditableText: Sendable {
        let text: String
        let encoding: String.Encoding
        /// The file isn't text; its bytes are shown one character each (Latin-1), which writes
        /// them back unchanged.
        let isBinary: Bool
    }

    static let maxEditableBytes = 16 * 1024 * 1024

    static func loadForEditing(_ url: URL) throws -> EditableText {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxEditableBytes else { throw LoadError.tooLarge }
        let data = try Data(contentsOf: url)
        if let (text, encoding) = decodeWithEncoding(data) {
            return EditableText(text: text, encoding: encoding, isBinary: false)
        }
        return EditableText(text: String(data: data, encoding: .isoLatin1) ?? "", encoding: .isoLatin1, isBinary: true)
    }

    /// Writes in place rather than replacing the file, so its tags (extended attributes) stay.
    static func save(_ text: String, encoding: String.Encoding, to url: URL) throws {
        let data = text.data(using: encoding) ?? Data(text.utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    /// Creates an empty text file, adding ".txt" when the name has no extension.
    static func createFile(named name: String, in directory: URL) throws -> URL {
        var clean = FileService.sanitized(name)
        if clean.isEmpty { clean = "New Text File" }
        if (clean as NSString).pathExtension.isEmpty { clean += ".txt" }
        let url = FileService.uniqueURL(for: clean, in: directory)
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Larger files are truncated so the reader stays responsive.
    static let maxBytes = 8 * 1024 * 1024

    static func load(_ url: URL) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        let truncated = data.count > maxBytes

        if truncated {
            // Don't cut a multi-byte UTF-8 character in half.
            for trim in 0..<4 {
                if let text = String(data: data.prefix(maxBytes - trim), encoding: .utf8) {
                    return (text, true)
                }
            }
        }
        guard let text = decode(truncated ? data.prefix(maxBytes) : data) else {
            throw LoadError.notText
        }
        return (text, truncated)
    }

    static func decode(_ data: Data) -> String? {
        decodeWithEncoding(data)?.text
    }

    static func decodeWithEncoding(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }

        var converted: NSString?
        var usedLossy = ObjCBool(false)
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.suggestedEncodingsKey: [String.Encoding.utf16.rawValue, String.Encoding.windowsCP1252.rawValue]],
            convertedString: &converted,
            usedLossyConversion: &usedLossy
        )
        if encoding != 0, let converted, !usedLossy.boolValue {
            return (converted as String, String.Encoding(rawValue: encoding))
        }
        // Lots of NUL bytes means binary data, not text.
        if data.prefix(4096).contains(0) { return nil }
        return String(data: data, encoding: .isoLatin1).map { ($0, .isoLatin1) }
    }
}
