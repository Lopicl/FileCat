import Foundation

/// A server added in FileCat, as listed in the library manifest: everything needed to connect
/// except the password. A companion app gets the passwords from FileCat with a
/// `ServerShareRequest`, after the user agrees.
public struct SharedServer: Codable, Hashable, Identifiable, Sendable {
    /// Stays the same while the server exists in FileCat, so a companion app can follow changes.
    public var id: String
    /// "smb", "nfs", "webdav" or "nextcloud".
    public var kind: String
    public var name: String
    /// Host name or IP address for SMB and NFS; the full server URL for WebDAV and Nextcloud.
    public var host: String
    public var port: Int?
    /// SMB: share, optionally followed by a folder ("Media/Music"). NFS: export path.
    public var path: String
    public var username: String
    public var domain: String
    public var uid: Int?
    public var gid: Int?
    /// SHA-256 fingerprint of a self-signed certificate the user chose to trust.
    public var trustedCertificate: String?
    /// When the password was last changed in FileCat. A companion app that imported the server
    /// before then asks FileCat for it again.
    public var passwordChanged: Date?

    public init(
        id: String, kind: String, name: String, host: String, port: Int? = nil, path: String = "",
        username: String = "", domain: String = "", uid: Int? = nil, gid: Int? = nil,
        trustedCertificate: String? = nil, passwordChanged: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.path = path
        self.username = username
        self.domain = domain
        self.uid = uid
        self.gid = gid
        self.trustedCertificate = trustedCertificate
        self.passwordChanged = passwordChanged
    }
}

/// Asks FileCat for its servers, passwords included: `filecat://share-servers?reply=musicat`.
///
/// FileCat only answers apps it knows, asks the user first, and then opens
/// `<reply>://filecat-servers?…` with a `ServerShareReply`. Nothing is stored in between: the
/// passwords go from FileCat's keychain to the companion app's own.
///
/// ```swift
/// UIApplication.shared.open(ServerShareRequest(replyScheme: "musicat").url)
///
/// .onOpenURL { url in
///     if let reply = ServerShareReply(url: url) { store.import(reply.servers) }
/// }
/// ```
public struct ServerShareRequest: Equatable, Sendable {
    public static let action = "share-servers"

    /// The companion app's URL scheme, which FileCat opens with the reply.
    public let replyScheme: String

    public init(replyScheme: String) {
        self.replyScheme = replyScheme.lowercased()
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == FileCatLink.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == Self.action,
              let reply = components.queryItems?.first(where: { $0.name == "reply" })?.value,
              !reply.isEmpty
        else { return nil }
        self.init(replyScheme: reply)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = FileCatLink.scheme
        components.host = Self.action
        components.queryItems = [URLQueryItem(name: "reply", value: replyScheme)]
        return components.url!
    }
}

/// FileCat's answer to a `ServerShareRequest`: every server with its password.
public struct ServerShareReply: Equatable, Sendable {
    public static let action = "filecat-servers"

    public struct Server: Codable, Hashable, Sendable {
        public var server: SharedServer
        public var password: String

        public init(server: SharedServer, password: String) {
            self.server = server
            self.password = password
        }
    }

    public var servers: [Server]

    public init(servers: [Server]) {
        self.servers = servers
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == Self.action,
              let text = components.queryItems?.first(where: { $0.name == "servers" })?.value,
              let data = Data(base64URLEncoded: text),
              let servers = try? Self.decoder.decode([Server].self, from: data)
        else { return nil }
        self.servers = servers
    }

    /// The link FileCat opens to hand the servers over.
    public func url(scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Self.action
        let data = (try? Self.encoder.encode(servers)) ?? Data("[]".utf8)
        components.queryItems = [URLQueryItem(name: "servers", value: data.base64URLEncodedString())]
        return components.url!
    }

    // Dates as in the manifest, so `passwordChanged` compares equal after the round trip.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
