import Foundation
import Security

/// A saved server. The password lives in the keychain, everything else in `UserDefaults`.
struct NetworkSource: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case smb, nfs, webdav, nextcloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .smb: "SMB"
            case .nfs: "NFS"
            case .webdav: "WebDAV"
            case .nextcloud: "Nextcloud"
            }
        }

        var subtitle: String {
            switch self {
            case .smb: "Windows, macOS, Linux (Samba) and most NAS"
            case .nfs: "Linux and NAS exports (NFS version 3)"
            case .webdav: "Web servers, NAS, ownCloud, many cloud services"
            case .nextcloud: "Sign in with your Nextcloud account"
            }
        }

        var systemImage: String {
            switch self {
            case .smb: "server.rack"
            case .nfs: "externaldrive.connected.to.line.below"
            case .webdav: "globe"
            case .nextcloud: "cloud"
            }
        }

        var defaultPort: Int {
            switch self {
            case .smb: 445
            case .nfs: 2049
            case .webdav, .nextcloud: 443
            }
        }
    }

    var id = UUID().uuidString
    var kind: Kind
    var name: String
    /// Host name or IP address for SMB and NFS; the full server URL for WebDAV and Nextcloud.
    var host: String
    /// Only set when the server doesn't use the protocol's usual port.
    var port: Int?
    /// SMB: share name, optionally followed by a folder ("Media/Music"). NFS: export path.
    var path = ""
    var username = ""
    /// SMB only; usually empty.
    var domain = ""
    /// NFS only: the user and group IDs sent to the server.
    var uid: Int?
    var gid: Int?
    /// SHA-256 fingerprint of a self-signed certificate the user chose to trust.
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
        }
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
