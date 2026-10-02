import Foundation
import Security

/// The App Group FileCat and its companion apps share: one container, one `UserDefaults` suite
/// and one keychain group, so the apps read the same data instead of copying it between them.
///
/// AltStore and SideStore re-sign apps under the user's own team and may rename App Groups on the
/// way (adding the team ID); they list the names they used in Info.plist under `ALTAppGroups`, so
/// `identifier` looks there first.
public enum SharedStorage {
    public static let baseIdentifier = "group.com.lopicl.FileCat"

    /// The group this copy of the app was signed with, or nil if it has none.
    public static let identifier: String? = {
        let renamed = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        let candidates = renamed.filter { $0.hasPrefix(baseIdentifier) } + renamed + [baseIdentifier]
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    public static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    public static var defaults: UserDefaults? {
        identifier.flatMap { UserDefaults(suiteName: $0) }
    }
}

/// What an app last left in shared storage, so the other app can tell that sharing works. Each
/// app records itself at launch through all three channels (defaults, a container file and the
/// keychain) and reads the other's.
public struct SharedStorageCheck: Sendable {
    public var version: String
    public var date: Date
    /// Read from the shared container, not from the shared defaults.
    public var fileVersion: String?
    /// Read from the shared keychain group.
    public var keychainVersion: String?

    private static let service = "com.lopicl.FileCat.shared-check"

    public static func record(app: String) {
        guard let defaults = SharedStorage.defaults else { return }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        defaults.set(["version": version, "date": Date()], forKey: "check.\(app)")
        if let url = fileURL(app: app) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(version.utf8).write(to: url, options: .atomic)
        }
        if let group = SharedStorage.identifier {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: app,
                kSecAttrAccessGroup as String: group,
            ]
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = Data(version.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    /// What `app` recorded last, or nil if it never did (or this app can't see shared storage).
    public static func read(app: String) -> SharedStorageCheck? {
        guard let entry = SharedStorage.defaults?.dictionary(forKey: "check.\(app)"),
              let version = entry["version"] as? String,
              let date = entry["date"] as? Date
        else { return nil }
        var check = SharedStorageCheck(version: version, date: date)
        if let url = fileURL(app: app), let data = try? Data(contentsOf: url) {
            check.fileVersion = String(data: data, encoding: .utf8)
        }
        if let group = SharedStorage.identifier {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: app,
                kSecAttrAccessGroup as String: group,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                check.keychainVersion = String(data: data, encoding: .utf8)
            }
        }
        return check
    }

    private static func fileURL(app: String) -> URL? {
        SharedStorage.containerURL?.appending(path: "Checks", directoryHint: .isDirectory).appending(path: "\(app).txt")
    }
}

#if os(iOS)
import SwiftUI

/// Settings rows telling whether this app shares storage with `otherApp`, and what it can read
/// of what that app left there.
public struct SharedStorageRows: View {
    let otherApp: String
    @State private var check: SharedStorageCheck?

    public init(otherApp: String) {
        self.otherApp = otherApp
    }

    public var body: some View {
        Group {
            LabeledContent("App Group", value: SharedStorage.identifier ?? "None")
                .accessibilityIdentifier("sharedStorageGroup")
            if SharedStorage.identifier != nil {
                if let check {
                    LabeledContent("\(otherApp) Seen") {
                        Text("\(check.version), \(check.date.formatted(.relative(presentation: .named)))")
                    }
                    .accessibilityIdentifier("sharedStorageSeen")
                    row("Shared Folder", ok: check.fileVersion == check.version)
                    row("Shared Keychain", ok: check.keychainVersion == check.version)
                } else {
                    LabeledContent("\(otherApp) Seen", value: "Not yet")
                        .accessibilityIdentifier("sharedStorageSeen")
                }
            }
        }
        .task { check = SharedStorageCheck.read(app: otherApp) }
    }

    private func row(_ title: String, ok: Bool) -> some View {
        LabeledContent(title) {
            Label(ok ? "Works" : "Can't Read", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
        }
        .accessibilityIdentifier("sharedStorage\(title.replacingOccurrences(of: " ", with: ""))")
    }
}
#endif
