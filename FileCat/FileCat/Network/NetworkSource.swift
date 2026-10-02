import Foundation
import Security

/// A saved server. The password lives in the keychain, everything else in `UserDefaults`.
struct NetworkSource: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case smb, nfs, webdav, nextcloud, sftp, ftp

        var id: String { rawValue }

        var title: String {
            switch self {
            case .smb: "SMB"
            case .nfs: "NFS"
            case .webdav: "WebDAV"
            case .nextcloud: "Nextcloud"
            case .sftp: "SFTP"
            case .ftp: "FTP"
            }
        }

        var subtitle: String {
            switch self {
            case .smb: "Windows, macOS, Linux (Samba) and most NAS"
            case .nfs: "Linux and NAS exports (NFS version 3)"
            case .webdav: "Web servers, NAS, ownCloud, many cloud services"
            case .nextcloud: "Sign in with your Nextcloud account"
            case .sftp: "Files over SSH: Linux, macOS, NAS and web hosting"
            case .ftp: "Older NAS, routers and web hosting (FTP and FTPS)"
            }
        }

        var systemImage: String {
            switch self {
            case .smb: "server.rack"
            case .nfs: "externaldrive.connected.to.line.below"
            case .webdav: "globe"
            case .nextcloud: "cloud"
            case .sftp: "lock.rectangle.stack"
            case .ftp: "arrow.up.arrow.down.circle"
            }
        }

        var defaultPort: Int {
            switch self {
            case .smb: 445
            case .nfs: 2049
            case .webdav, .nextcloud: 443
            case .sftp: 22
            case .ftp: 21
            }
        }
    }

    var id = UUID().uuidString
    var kind: Kind
    var name: String
    /// Host name or IP address for SMB, NFS, SFTP and FTP; the full server URL for WebDAV and Nextcloud.
    var host: String
    /// Only set when the server doesn't use the protocol's usual port.
    var port: Int?
    /// SMB: share name, optionally followed by a folder ("Media/Music"). NFS: export path.
    /// SFTP and FTP: the folder to start in (empty for the home folder).
    var path = ""
    var username = ""
    /// SMB only; usually empty.
    var domain = ""
    /// NFS only: the user and group IDs sent to the server.
    var uid: Int?
    var gid: Int?
    /// SHA-256 fingerprint of a self-signed certificate the user chose to trust. SFTP: the
    /// fingerprint of the server's host key ("SHA256:…"), as OpenSSH shows it.
    var trustedCertificate: String?
    /// When the password was last changed, so companion apps that imported the server know to
    /// ask FileCat for it again. Whole seconds, to survive the ISO 8601 manifest.
    var passwordChanged: Date?

    var displayAddress: String {
        switch kind {
        case .smb:
            let share = path.isEmpty ? "" : "/" + path
            return "smb://\(host)\(port.map { ":\($0)" } ?? "")\(share)"
        case .nfs:
            return "nfs://\(host)\(port.map { ":\($0)" } ?? "")\(path.hasPrefix("/") ? path : "/" + path)"
        case .webdav, .nextcloud:
            return host
        case .sftp, .ftp:
            let user = username.isEmpty ? "" : username + "@"
            let folder = path.isEmpty ? "" : (path.hasPrefix("/") ? path : "/" + path)
            let scheme = usesImplicitTLS && port != 990 ? "ftps" : kind.rawValue
            return "\(scheme)://\(user)\(hostName)\(port.map { ":\($0)" } ?? "")\(folder)"
        }
    }

    /// SFTP and FTP: the host name without the "sftp://", "ftp://" or "ftps://" people may type.
    var hostName: String {
        var text = host.trimmingCharacters(in: .whitespaces)
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        return text
    }

    /// FTP with TLS from the start rather than after AUTH TLS: "ftps://" addresses and port 990.
    var usesImplicitTLS: Bool {
        kind == .ftp && (host.lowercased().hasPrefix("ftps://") || port == 990)
    }

    /// The WebDAV root for WebDAV and Nextcloud sources.
    var webDAVBaseURL: URL? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        if let port { components.port = port }
        if kind == .nextcloud {
            let root = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? username
            components.percentEncodedPath = (root.isEmpty ? "" : "/" + root) + "/remote.php/dav/files/\(user)"
        }
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url
    }

    var password: String {
        get { Keychain.password(for: id) ?? "" }
    }
}

/// Server passwords, kept in the keychain and available after the first unlock so
/// downloads can finish in the background.
enum Keychain {
    private static let service = "com.lopicl.FileCat.network"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String) {
        deletePassword(for: account)
        guard !password.isEmpty else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deletePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
