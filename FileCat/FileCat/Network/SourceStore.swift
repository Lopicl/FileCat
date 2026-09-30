import Foundation
import Observation

/// The user's saved servers.
@MainActor
@Observable
final class SourceStore {
    private(set) var sources: [NetworkSource] = []

    nonisolated static let defaultsKey = "networkSources"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([NetworkSource].self, from: data) {
            sources = saved
        }
    }

    func source(id: String?) -> NetworkSource? {
        sources.first { $0.id == id }
    }

    /// Adds or updates a source. `password == nil` keeps the stored one.
    func save(_ source: NetworkSource, password: String?) {
        var source = source
        source.passwordChanged = self.source(id: source.id)?.passwordChanged
        if let password {
            if password != (Keychain.password(for: source.id) ?? "") {
                source.passwordChanged = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            }
            Keychain.setPassword(password, for: source.id)
        }
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        persist()
        Task { await RemoteConnections.shared.invalidate(source.id) }
    }

    func remove(_ source: NetworkSource) {
        sources.removeAll { $0.id == source.id }
        Keychain.deletePassword(for: source.id)
        persist()
        Task { await RemoteConnections.shared.invalidate(source.id) }
        RemoteCache.removeAll(for: source.id)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
