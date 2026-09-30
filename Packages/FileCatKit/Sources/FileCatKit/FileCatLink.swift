import Foundation

/// `filecat://` links, which let companion apps open or reveal a file in FileCat.
///
/// - `filecat://open?path=Music/Album/01.mp3` opens a file (or folder) in Local Storage.
/// - `filecat://reveal?path=Music/Album/01.mp3` shows the folder that contains it.
///
/// Paths are relative to Local Storage and may not leave it.
public struct FileCatLink: Equatable, Sendable {
    public enum Action: String, Sendable {
        case open, reveal
    }

    public static let scheme = "filecat"

    public let action: Action
    public let path: String

    public init(action: Action, path: String) {
        self.action = action
        self.path = path
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = Action(rawValue: (components.host ?? "").lowercased()),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value
        else { return nil }
        self.action = action
        self.path = path
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }

    /// The file the link points to, or `nil` if the path tries to leave `root`.
    public func fileURL(in root: URL) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.isEmpty || path == "/" || path.isEmpty else { return nil }
        let target = parts.reduce(root) { $0.appending(path: $1) }
        return action == .reveal ? target.deletingLastPathComponent() : target
    }
}
