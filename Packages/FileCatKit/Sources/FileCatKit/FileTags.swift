import Foundation

/// Tag colors, numbered the way Finder stores them.
public enum TagColor: Int, Codable, CaseIterable, Identifiable, Sendable {
    case none = 0, gray, green, purple, blue, yellow, red, orange

    public var id: Int { rawValue }

    /// The order the Files app shows colors in.
    public static let pickerOrder: [TagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray, .none]

    public var name: String {
        switch self {
        case .none: "No Color"
        case .gray: "Gray"
        case .green: "Green"
        case .purple: "Purple"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .red: "Red"
        case .orange: "Orange"
        }
    }

    /// Approximate sRGB components of Finder's tag colors, for matching custom colors.
    public var rgb: (red: Double, green: Double, blue: Double)? {
        switch self {
        case .none: nil
        case .gray: (0.56, 0.56, 0.58)
        case .green: (0.20, 0.78, 0.35)
        case .purple: (0.69, 0.32, 0.87)
        case .blue: (0.0, 0.48, 1.0)
        case .yellow: (1.0, 0.8, 0.0)
        case .red: (1.0, 0.23, 0.19)
        case .orange: (1.0, 0.58, 0.0)
        }
    }

    /// The Finder color closest to an arbitrary color, so custom-colored tags still get a
    /// sensible color in Finder and Files.
    public static func nearest(red: Double, green: Double, blue: Double) -> TagColor {
        pickerOrder.compactMap { color in
            color.rgb.map { (color, pow($0.red - red, 2) + pow($0.green - green, 2) + pow($0.blue - blue, 2)) }
        }
        .min { $0.1 < $1.1 }?.0 ?? .none
    }
}

/// A tag color the user picked freely, as sRGB components (0...1). Kept in the app and the library
/// manifest; files store the nearest Finder color.
public struct CustomTagColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The Finder color stored on files for this color.
    public var nearestTagColor: TagColor {
        TagColor.nearest(red: red, green: green, blue: blue)
    }
}

/// An optional picture for a tag: an SF Symbol. Kept in the app only; Finder just
/// sees the tag's name and color.
public enum TagIcon: Codable, Hashable, Sendable {
    case symbol(String)

    /// A curated set of symbols that read well at small sizes.
    public static let symbols = [
        "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "bolt.fill", "bell.fill",
        "briefcase.fill", "house.fill", "person.fill", "person.2.fill", "graduationcap.fill", "book.fill",
        "cart.fill", "creditcard.fill", "airplane", "car.fill", "gamecontroller.fill", "music.note",
        "camera.fill", "photo.fill", "film.fill", "doc.fill", "folder.fill", "paintbrush.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "leaf.fill", "pawprint.fill", "gift.fill", "sun.max.fill",
        "moon.fill", "cloud.fill", "lock.fill", "key.fill", "checkmark.seal.fill", "exclamationmark.triangle.fill",
        "clock.fill", "calendar", "mappin", "globe",
    ]
}

public struct FileTag: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var color: TagColor
    public var icon: TagIcon?
    /// Overrides `color` for display when the user picked a color of their own. `color` then
    /// holds the nearest Finder color.
    public var customColor: CustomTagColor?

    public init(name: String, color: TagColor, icon: TagIcon? = nil, customColor: CustomTagColor? = nil) {
        self.name = name
        self.color = customColor?.nearestTagColor ?? color
        self.icon = icon
        self.customColor = customColor
    }

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, color, icon, customColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(TagColor.self, forKey: .color)
        // Icons FileCat no longer offers (emoji) load as "no icon" instead of failing the tag.
        icon = try? container.decodeIfPresent(TagIcon.self, forKey: .icon)
        customColor = try? container.decodeIfPresent(CustomTagColor.self, forKey: .customColor)
    }

    public static let defaults: [FileTag] = TagColor.pickerOrder
        .filter { $0 != .none }
        .map { FileTag(name: $0.name, color: $0) }
}

/// Reads and writes Finder-compatible tags in the `com.apple.metadata:_kMDItemUserTags` extended
/// attribute, so tags travel with the file when it's moved, renamed or copied.
public enum FileTags {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    public static func read(_ url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            guard read == size,
                  let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
            else { return [] }
            // Entries look like "Work\n4": the name, then an optional color number.
            return entries.compactMap { entry in
                entry.split(separator: "\n", maxSplits: 1).first.map(String.init)
            }
        }
    }

    public static func write(_ names: [String], colors: [String: TagColor], to url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileNoSuchFile) }
            if names.isEmpty {
                if removexattr(path, attribute, 0) != 0, errno != ENOATTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return
            }
            let entries = names.map { name in
                let color = colors[name.lowercased()] ?? TagColor.none
                return color == .none ? name : "\(name)\n\(color.rawValue)"
            }
            let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
            let result = data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) }
            if result != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    public static func contains(_ names: [String], _ tag: String) -> Bool {
        names.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}
