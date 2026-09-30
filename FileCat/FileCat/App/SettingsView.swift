import FileCatKit
import SwiftUI

/// `UserDefaults` keys for user preferences, read with `@AppStorage`.
enum AppSettings {
    /// Show tag dots and icons after file and folder names.
    static let showsFileTags = "showsFileTags"
    /// Start videos automatically when they come on screen in the gallery.
    static let galleryAutoplay = "galleryAutoplay"
    /// Gallery videos start without sound.
    static let galleryStartsMuted = "galleryStartsMuted"
    /// Tags as a whole: the Tags tab, tag menus and tag dots.
    static let tagsEnabled = "tagsEnabled"
    /// Play server videos and music straight from the server, instead of downloading the whole file first.
    static let streamsMedia = "streamsMedia"

    static let all = [showsFileTags, galleryAutoplay, galleryStartsMuted, tagsEnabled, streamsMedia]

    /// Everything "Reset All Settings" puts back: preferences plus view options chosen in menus
    /// (list or icons, sort order, text size) and the equalizer.
    static let resettable = all + ["viewStyle", "sortKey", "sortAscending", "textFontSize", "textMonospaced", "eqEnabled", "eqGains", "tabCustomization"]
}

struct SettingsView: View {
    @AppStorage(AppSettings.showsFileTags) private var showsFileTags = true
    @AppStorage(AppSettings.galleryAutoplay) private var galleryAutoplay = true
    @AppStorage(AppSettings.galleryStartsMuted) private var galleryStartsMuted = true
    @AppStorage(AppSettings.tagsEnabled) private var tagsEnabled = true
    @AppStorage(AppSettings.streamsMedia) private var streamsMedia = true

    @Environment(AudioPlayer.self) private var player
    @Environment(TransferCenter.self) private var transfers

    @State private var cacheSize: Int64?
    @State private var offlineSize: Int64?
    @State private var isConfirmingClearCache = false
    @State private var isConfirmingRemoveOffline = false
    @State private var isConfirmingReset = false
    @State private var confirmation: String?
    @State private var meows = 0

    var body: some View {
        Form {
            Section {
                Toggle("Tags", isOn: $tagsEnabled.animation())
                    .accessibilityIdentifier("tagsEnabled")
                if tagsEnabled {
                    Toggle("Show Tags on Files", isOn: $showsFileTags)
                }
            } header: {
                Text("Tags")
            } footer: {
                Text(tagsEnabled
                     ? "Shows each file's tag colors and icons next to its date and size."
                     : "The Tags tab and tag menus are hidden. Tags already on your files are kept.")
            }

            Section {
                NavigationLink {
                    EqualizerSettings()
                } label: {
                    LabeledContent("Equalizer", value: player.equalizer.isEnabled ? (player.equalizer.preset?.name ?? "Custom") : "Off")
                }
                .accessibilityIdentifier("equalizerSettings")
            } header: {
                Text("Music")
            }

            Section {
                Toggle("Stream Videos and Music", isOn: $streamsMedia)
            } header: {
                Text("Servers")
            } footer: {
                Text("Videos and music on servers start playing right away, and only the parts you play are fetched. Otherwise the whole file downloads first.")
            }

            Section {
                Toggle("Autoplay Videos", isOn: $galleryAutoplay)
                Toggle("Start Videos Muted", isOn: $galleryStartsMuted)
            } header: {
                Text("Photos & Videos")
            } footer: {
                Text("Applies to videos shown in the photo and video gallery. Unmuting a video pauses the music player.")
            }

            Section {
                LabeledContent("Cache", value: formatted(cacheSize))
                Button("Clear Cache", role: .destructive) {
                    isConfirmingClearCache = true
                }
                .accessibilityIdentifier("clearCache")
                LabeledContent("Offline Files", value: formatted(offlineSize))
                Button("Remove All Offline Files", role: .destructive) {
                    isConfirmingRemoveOffline = true
                }
                .disabled(offlineSize == 0)
            } header: {
                Text("Storage")
            } footer: {
                Text("The cache holds thumbnails and files recently opened from servers; it's rebuilt as you browse. Offline files are server files you chose to keep on this device. Files in Local Storage are never touched.")
            }

            Section {
                Button("Reset All Settings", role: .destructive) {
                    isConfirmingReset = true
                }
                .accessibilityIdentifier("resetAllSettings")
            } footer: {
                Text("Puts every setting back to its default, including list or icon view, sort order, text size and the equalizer. Your files, tags and connections are kept.")
            }

            Section {
                NavigationLink("Companion Apps") {
                    CompanionAppsView()
                }
                LabeledContent("Version", value: Self.version)
            } footer: {
                LongCat(meows: meows)
            }
        }
        .onHardOverscroll {
            meows += 1
            Meow.play()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: meows)
        .navigationTitle("Settings")
        .task(id: transfers.revision) { await measure() }
        .confirmationDialog("Clear the cache?", isPresented: $isConfirmingClearCache, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await AppCache.clear()
                    await measure()
                    confirmation = "Cache cleared."
                }
            }
        } message: {
            Text("Thumbnails and downloaded server files will be fetched again when needed.")
        }
        .confirmationDialog("Remove all offline files?", isPresented: $isConfirmingRemoveOffline, titleVisibility: .visible) {
            Button("Remove Offline Files", role: .destructive) {
                transfers.removeAllOffline()
                Task { await measure() }
            }
        } message: {
            Text("They stay on the servers and can be downloaded again.")
        }
        .confirmationDialog("Reset all settings?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset All Settings", role: .destructive) {
                for key in AppSettings.resettable {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                player.equalizer.reset()
                confirmation = "All settings were reset."
            }
        }
        .alert(confirmation ?? "", isPresented: Binding(isPresenting: $confirmation)) {
            Button("OK") {}
        }
    }

    private func measure() async {
        async let cache = AppCache.size()
        async let offline = AppCache.directorySize(RemoteCache.offlineRoot)
        (cacheSize, offlineSize) = await (cache, offline)
    }

    private func formatted(_ size: Int64?) -> String {
        guard let size else { return "…" }
        return size == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// Everything the app keeps that can be thrown away and rebuilt.
enum AppCache {
    private static var roots: [URL] {
        [URL.cachesDirectory, URL.temporaryDirectory]
    }

    static func size() async -> Int64 {
        var total: Int64 = 0
        for root in roots {
            total += await directorySize(root)
        }
        return total
    }

    static func directorySize(_ url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
            while let file = enumerator.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
            return total
        }.value
    }

    @MainActor
    static func clear() async {
        ThumbnailCache.shared.removeAll()
        URLCache.shared.removeAllCachedResponses()
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            for root in roots {
                for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    try? fileManager.removeItem(at: url)
                }
            }
        }.value
    }
}
