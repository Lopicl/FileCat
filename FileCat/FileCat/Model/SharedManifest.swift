import FileCatKit
import Foundation

/// Keeps `.FileCat/library.json` in Local Storage up to date, so companion apps (like MusiCat) can
/// find the library and show its tags, folders and servers (see FileCatKit).
enum SharedManifest {
    static func update(_ change: (inout LibraryManifest) -> Void) {
        let root = FileService.documentsDirectory
        var manifest = LibraryManifest.read(from: root) ?? LibraryManifest(tags: [])
        change(&manifest)
        manifest.updated = Date()
        try? manifest.write(to: root)
    }

    /// Replaces the listed locations of some kinds, keeping the others.
    static func setLocations(_ locations: [SharedLocation], ofKinds kinds: Set<SharedLocation.Kind>) {
        update { manifest in
            let others = (manifest.locations ?? []).filter { !kinds.contains($0.kind) }
            manifest.locations = others + locations
        }
    }

    /// Lists the servers by name and address, and with their settings (not their passwords) so
    /// companion apps can follow changes to servers they imported.
    static func setServers(_ sources: [NetworkSource]) {
        update { manifest in
            let others = (manifest.locations ?? []).filter { $0.kind != .server }
            manifest.locations = others + sources.map { SharedLocation(id: $0.id, name: $0.name, kind: .server, address: $0.displayAddress) }
            manifest.servers = sources.map(\.shared)
        }
    }
}
