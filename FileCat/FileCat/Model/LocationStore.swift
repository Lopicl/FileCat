import FileCatKit
import Foundation
import Observation
import UIKit

struct Location: Identifiable, Hashable {
    static let documentsID = "documents"

    /// Sidebar selection IDs for tags are prefixed so they can't clash with location IDs.
    static func tagSelectionID(_ name: String) -> String {
        "tag:" + name
    }

    static func tagName(from selectionID: String?) -> String? {
        guard let selectionID, selectionID.hasPrefix("tag:") else { return nil }
        return String(selectionID.dropFirst(4))
    }

    let id: String
    var name: String
    var url: URL
    var systemImage: String

    /// Folders picked from iCloud Drive.
    var isICloud: Bool {
        let path = url.path(percentEncoded: false)
        return path.contains("/Mobile Documents/") || path.contains("com~apple~CloudDocs")
    }
}

/// A saved folder that can't be reached right now, such as a USB drive that's unplugged.
struct DisconnectedLocation: Identifiable, Hashable {
    let id: String
    let name: String
    let systemImage: String
}

/// The app's own storage plus any folders the user added from Files (iCloud Drive, USB drives, …).
/// External folders are remembered with bookmarks so access survives relaunches. Drives leave the
/// list while they're unplugged and come back on their own when they're plugged in again, and
/// drives plugged in for the first time are offered in `newDrives`.
@MainActor
@Observable
final class LocationStore {
    let documents: Location
    private(set) var locations: [Location] = []
    /// Saved folders whose bookmark doesn't resolve right now. Unplugged drives aren't listed:
    /// they're hidden until they're plugged in again.
    private(set) var disconnected: [DisconnectedLocation] = []
    /// Names of drives that are plugged in but haven't been added yet. iOS only lets the app in
    /// once the user picks the drive in the Files picker.
    private(set) var newDrives: [String] = []

    private struct SavedLocation: Codable {
        var id: String
        var name: String
        var bookmark: Data
        /// Remembered so an unplugged drive still shows a drive icon.
        var isExternalDrive: Bool?
        /// The drive's name, to recognise it when it's plugged in (the folder may be inside it).
        var volumeName: String?

        /// The name the drive monitor reports for this folder's drive, if it's on one.
        var driveName: String? {
            guard isExternalDrive == true else { return nil }
            return volumeName ?? name
        }
    }

    @ObservationIgnored private var saved: [SavedLocation] = []
    @ObservationIgnored private var accessedURLs: [String: URL] = [:]
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var driveMonitor: ExternalDriveMonitor?
    @ObservationIgnored private var driveRetry: Task<Void, Never>?
    /// New drives the user dismissed; they're offered again once replugged.
    @ObservationIgnored private var dismissedDrives: Set<String> = []
    private let defaultsKey = "savedLocations"

    init() {
        documents = Location(
            id: Location.documentsID,
            name: "Local Storage",
            url: FileService.documentsDirectory,
            systemImage: "internaldrive"
        )
        restore()
        // Plugging a drive in usually happens with the app in the background.
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect() }
        }
        driveMonitor = ExternalDriveMonitor { [weak self] in self?.drivesChanged() }
        updateNewDrives()
    }

    /// True if some saved folder (maybe a hidden, unplugged drive) can't be reached.
    var hasUnreachable: Bool {
        saved.count > locations.count
    }

    /// Hides a new drive until it's plugged in again.
    func dismissNewDrive(_ name: String) {
        dismissedDrives.insert(Self.key(name))
        updateNewDrives()
    }

    var all: [Location] { [documents] + locations }

    func location(id: String?) -> Location? {
        all.first { $0.id == id }
    }

    @discardableResult
    func add(_ url: URL) throws -> Location {
        if let existing = all.first(where: { FileService.isSameLocation($0.url, url) }) {
            return existing
        }
        let accessing = url.startAccessingSecurityScopedResource()
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let isDrive = Self.isExternalDrive(url)
        let entry = SavedLocation(
            id: UUID().uuidString, name: url.lastPathComponent, bookmark: bookmark,
            isExternalDrive: isDrive, volumeName: isDrive ? Self.volumeName(url) : nil
        )
        saved.append(entry)
        if accessing { accessedURLs[entry.id] = url }

        let location = makeLocation(entry, url: url)
        locations.append(location)
        persist()
        updateNewDrives()
        return location
    }

    func remove(_ location: Location) {
        remove(id: location.id)
    }

    func remove(id: String) {
        // A drive removed while it's plugged in isn't offered as new straight away.
        if let driveName = saved.first(where: { $0.id == id })?.driveName {
            dismissedDrives.insert(Self.key(driveName))
        }
        accessedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        saved.removeAll { $0.id == id }
        locations.removeAll { $0.id == id }
        disconnected.removeAll { $0.id == id }
        persist()
        updateNewDrives()
    }

    /// Tries the bookmarks of folders that couldn't be reached, and drops folders whose drive was
    /// unplugged. Cheap enough to call whenever the app becomes active or the Connections tab shows.
    func reconnect() {
        var changed = false
        defer { updateNewDrives() }
        // Folders that went away (the drive was unplugged) leave the list until they come back.
        for location in locations where !FileManager.default.fileExists(atPath: location.url.path(percentEncoded: false)) {
            accessedURLs.removeValue(forKey: location.id)?.stopAccessingSecurityScopedResource()
            locations.removeAll { $0.id == location.id }
            changed = true
        }
        for index in saved.indices where !locations.contains(where: { $0.id == saved[index].id }) {
            if let url = resolve(&saved[index]) {
                locations.append(makeLocation(saved[index], url: url))
                changed = true
            }
        }
        if changed {
            // Keep the order the folders were added in.
            let order = saved.map(\.id)
            locations.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
            persist()
        }
        updateDisconnected()
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([SavedLocation].self, from: data)
        else { return }

        for var entry in entries {
            if let url = resolve(&entry) {
                locations.append(makeLocation(entry, url: url))
            }
            // Unresolvable bookmarks (e.g. an unplugged drive) are kept so they return later.
            saved.append(entry)
        }
        persist()
        updateDisconnected()
    }

    /// Resolves a bookmark and starts accessing it; `nil` if its folder can't be reached.
    private func resolve(_ entry: inout SavedLocation) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        let accessing = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        if accessing { accessedURLs[entry.id] = url }
        if isStale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            entry.bookmark = fresh
        }
        if entry.isExternalDrive == nil {
            entry.isExternalDrive = Self.isExternalDrive(url)
        }
        if entry.isExternalDrive == true, entry.volumeName == nil {
            entry.volumeName = Self.volumeName(url)
        }
        return url
    }

    /// A drive was plugged in or out. The system mounts a new drive a moment after it's reported,
    /// so its folders are tried again for a few seconds.
    private func drivesChanged() {
        reconnect()
        driveRetry?.cancel()
        driveRetry = Task { [weak self] in
            for delay in [1, 2, 4] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.hasUnreachable else { return }
                self.reconnect()
            }
        }
    }

    private func updateNewDrives() {
        let plugged = driveMonitor?.driveNames ?? []
        let pluggedKeys = Set(plugged.map(Self.key))
        // Dismissed drives are offered again after they're replugged.
        dismissedDrives.formIntersection(pluggedKeys)
        let known = Set(saved.compactMap(\.driveName).map(Self.key))
        let fresh = plugged.filter { !known.contains(Self.key($0)) && !dismissedDrives.contains(Self.key($0)) }
        if fresh != newDrives { newDrives = fresh }
    }

    private static func key(_ driveName: String) -> String {
        driveName.lowercased()
    }

    private func updateDisconnected() {
        let fresh = saved
            .filter { entry in !locations.contains { $0.id == entry.id } }
            // Unplugged drives are hidden, not listed as disconnected.
            .filter { $0.isExternalDrive != true }
            .map { DisconnectedLocation(id: $0.id, name: $0.name, systemImage: $0.isExternalDrive == true ? "externaldrive" : "folder") }
        if fresh != disconnected { disconnected = fresh }
    }

    private func makeLocation(_ entry: SavedLocation, url: URL) -> Location {
        var location = Location(id: entry.id, name: entry.name, url: url, systemImage: entry.isExternalDrive == true ? "externaldrive" : "folder")
        if location.isICloud {
            location.systemImage = "icloud"
            // The root of iCloud Drive comes back with its internal name.
            if entry.name == "com~apple~CloudDocs" { location.name = "iCloud Drive" }
        }
        return location
    }

    /// USB drives and SD cards are mounted by the system's file system daemon.
    private static func isExternalDrive(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        if path.contains("/LiveFiles/") || path.hasPrefix("/Volumes/") || path.hasPrefix("/private/var/mobile/Library/LiveFiles") {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey])
        return values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
    }

    private static func volumeName(_ url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        // Companion apps get the bookmarks too, so they can follow the same folders.
        let shared = saved.map { entry in
            let location = locations.first { $0.id == entry.id }
            let kind: SharedLocation.Kind = entry.isExternalDrive == true ? .drive : location?.isICloud == true ? .iCloud : .folder
            return SharedLocation(
                id: entry.id, name: location?.name ?? entry.name, kind: kind,
                bookmark: entry.bookmark, isConnected: location != nil
            )
        }
        SharedManifest.setLocations(shared, ofKinds: [.folder, .drive, .iCloud])
    }
}
