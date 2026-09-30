import FileCatKit
import SwiftUI

struct ContentView: View {
    @Environment(LocationStore.self) private var store
    @Environment(TagStore.self) private var tagStore
    @Environment(SourceStore.self) private var sources
    @Environment(AudioPlayer.self) private var player
    @Environment(TransferCenter.self) private var transfers

    @Environment(\.usesSidebarLayout) private var usesSidebarLayout

    @State private var router = Router()
    private var activities: ActivityCenter { .shared }
    /// Needed for the sidebar-only tabs to stay out of the iPad tab bar.
    @AppStorage("tabCustomization") private var customization: TabViewCustomization
    @State private var errorMessage: String?
    /// A companion app asking for the servers (`filecat://share-servers`), waiting for the user's OK.
    @State private var serverShare: ServerShareRequest?
    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.tagsEnabled) private var tagsEnabled = true

    var body: some View {
        @Bindable var router = router

        // On iPhone this is a tab bar at the bottom. On iPad it's the floating bar at the top, which
        // expands into a sidebar listing every tag, folder and server.
        TabView(selection: tabSelection) {
            localTab
            if usesSidebarLayout {
                // iPad: Connections and Tags are dropdowns in the tab bar (sections in the sidebar)
                // listing every server, folder and tag.
                networkSection
                if tagsEnabled { tagSection }
                // The sidebar lists plain tabs above its sections, so Settings is in its bottom bar
                // instead (see SidebarSettingsButton).
                settingsTab
                    .defaultVisibility(.hidden, for: .sidebar)
            } else {
                // iPhone: plain tabs; extra ones would end up under "More".
                networkTab
                if tagsEnabled { tagsTab }
                settingsTab
                if !activities.activities.isEmpty { activityTab }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // iPad: the tab bar is at the top, so the activity indicator floats in the corner.
            if usesSidebarLayout, !activities.activities.isEmpty {
                ActivityFloatingButton()
            }
        }
        .sheet(isPresented: $router.showsActivities) {
            ActivitiesView()
                .presentationDetents([.medium, .large])
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($customization)
        .onAppear(perform: showSections)
        .tabViewSidebarBottomBar {
            SidebarSettingsButton()
        }
        .sheet(item: $router.serverEditor) { request in
            ServerEditorView(request: request)
        }
        .onChange(of: tagStore.tags) { fixSelection() }
        .onChange(of: sources.sources) { fixSelection() }
        .onChange(of: sources.sources, initial: true) {
            // Companion apps see the servers' settings, not their passwords.
            SharedManifest.setServers(sources.sources)
        }
        .onChange(of: store.locations) { fixSelection() }
        .onChange(of: tagsEnabled) { fixSelection() }
        .sheet(isPresented: $router.showsNowPlaying) {
            NowPlayingView()
        }
        .fileImporter(
            isPresented: $router.isImporting,
            allowedContentTypes: router.importRequest?.contentTypes ?? [.item],
            allowsMultipleSelection: router.importRequest?.allowsMultipleSelection ?? true,
            onCompletion: handleImport
        )
        .onOpenURL(perform: handleOpenURL)
        #if DEBUG
        // For testing: launch with `-FileCatOpenPath "Photos/Sunset.jpg"` to open a file directly.
        .task {
            if let path = UserDefaults.standard.string(forKey: "FileCatOpenPath") {
                handleOpenURL(FileService.documentsDirectory.appending(path: path))
            }
            UITestSupport.startDemoActivityIfNeeded()
        }
        #endif
        .task {
            await transfers.syncAll()
        }
        .alert("Upload Failed", isPresented: Binding(isPresenting: Bindable(transfers).uploadError), presenting: transfers.uploadError) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .modifier(ServerShareAlert(request: $serverShare, serverCount: sources.sources.count, share: shareServers))
        .alert("Something Went Wrong", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .environment(router)
    }

    @TabContentBuilder<AppTab>
    private var localTab: some TabContent<AppTab> {
        Tab("Local Storage", systemImage: "internaldrive", value: AppTab.local) {
            stack(for: .local) {
                FolderView(url: store.documents.url, title: store.documents.name)
            }
        }
        .customizationID("local")
        .accessibilityIdentifier("tab-local")
    }

    @TabContentBuilder<AppTab>
    private var tagsTab: some TabContent<AppTab> {
        Tab("Tags", systemImage: "tag", value: AppTab.tags) {
            stack(for: .tags) { TagsView() }
        }
        .customizationID("tags")
        .accessibilityIdentifier("tab-tags")
    }

    @TabContentBuilder<AppTab>
    private var networkTab: some TabContent<AppTab> {
        Tab("Connections", systemImage: "network", value: AppTab.network) {
            stack(for: .network) { NetworkView() }
        }
        .customizationID("network")
        .accessibilityIdentifier("tab-network")
    }

    /// Choosing the Activity "tab" opens the activity list instead of switching tabs.
    private var tabSelection: Binding<AppTab> {
        Binding {
            router.selectedTab
        } set: { tab in
            if tab == .activity {
                router.showsActivities = true
            } else {
                router.selectedTab = tab
            }
        }
    }

    /// iPhone: the activity indicator sits in the tab bar, a progress ring with the number of
    /// running activities. It shows once anything has run, until the list is cleared.
    @TabContentBuilder<AppTab>
    private var activityTab: some TabContent<AppTab> {
        Tab(value: AppTab.activity) {
            Color.clear
        } label: {
            Label {
                Text("Activity")
            } icon: {
                Image(uiImage: ActivityRing.image(
                    running: activities.runningCount,
                    fraction: activities.overallFraction,
                    phase: activities.spinnerPhase
                ))
            }
        }
        .customizationID("activity")
        .accessibilityIdentifier("tab-activity")
    }

    @TabContentBuilder<AppTab>
    private var settingsTab: some TabContent<AppTab> {
        Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
            NavigationStack { SettingsView() }
        }
        .customizationID("settings")
        .accessibilityIdentifier("tab-settings")
    }

    /// iPad: the Tags dropdown in the tab bar and section in the sidebar.
    @TabContentBuilder<AppTab>
    private var tagSection: some TabContent<AppTab> {
        TabSection("Tags") {
            Tab("All Tags", systemImage: "tag", value: AppTab.tags) {
                stack(for: .tags) { TagsView() }
            }
            .customizationID("tags")
            .accessibilityIdentifier("tab-tags")

            ForEach(tagStore.tags) { tag in
                Tab(value: AppTab.tag(tag.name)) {
                    stack(for: .tag(tag.name)) { TaggedFilesView(tagName: tag.name) }
                } label: {
                    // The tag's own icon or color dot, in its color.
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(uiImage: tag.sidebarImage)
                            .renderingMode(.original)
                    }
                }
                .customizationID("tag." + tag.name)
            }
        }
        .customizationID("section.tags.menu")
        // Hiding the section in the sidebar's Edit mode left no way to bring it back.
        .customizationBehavior(.disabled, for: .sidebar)
    }

    /// iPad: the Connections dropdown in the tab bar and section in the sidebar.
    @TabContentBuilder<AppTab>
    private var networkSection: some TabContent<AppTab> {
        TabSection("Connections") {
            Tab("All Connections", systemImage: "network", value: AppTab.network) {
                stack(for: .network) { NetworkView() }
            }
            .customizationID("network")
            .accessibilityIdentifier("tab-network")

            ForEach(sources.sources) { source in
                Tab(source.name, systemImage: source.kind.systemImage, value: AppTab.server(source.id)) {
                    stack(for: .server(source.id)) {
                        RemoteFolderView(folder: .root(of: source))
                    }
                }
                .customizationID("server." + source.id)
            }
            ForEach(store.locations) { location in
                Tab(location.name, systemImage: location.systemImage, value: AppTab.location(location.id)) {
                    stack(for: .location(location.id)) {
                        FolderView(url: location.url, title: location.name)
                    }
                }
                .customizationID("location." + location.id)
            }
        }
        .customizationID("section.network.menu")
        // Hiding the section in the sidebar's Edit mode left no way to bring it back.
        .customizationBehavior(.disabled, for: .sidebar)
    }

    /// A tab's navigation stack, with every kind of destination the browser can push.
    private func stack(for tab: AppTab, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: router.path(for: tab)) {
            root()
                .miniPlayerInset()
                .environment(\.browserTab, tab)
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                        .miniPlayerInset()
                        .environment(\.browserTab, tab)
                }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .file(let item): FileDestination(item: item)
        case .remote(let item): RemoteFolderView(folder: item)
        case .remoteFile(let file): RemoteFileViewer(file: file)
        case .tag(let destination): TaggedFilesView(tagName: destination.name)
        case .archive(let folder): ArchiveView(folder: folder)
        }
    }

    /// Brings back the Connections and Tags sections for anyone who hid them before they were locked.
    private func showSections() {
        for id in ["section.network.menu", "section.tags.menu"] where customization[sidebarVisibility: id] == .hidden {
            customization[sidebarVisibility: id] = .visible
        }
    }

    /// Leaves a sidebar tab whose tag, folder or server was just removed, or the Tags tab when
    /// tags are switched off.
    private func fixSelection() {
        switch router.selectedTab {
        case .tags where !tagsEnabled, .tag(_) where !tagsEnabled:
            router.selectedTab = .local
        case .tag(let name) where tagStore.tag(named: name) == nil:
            router.selectedTab = .tags
        case .server(let id) where sources.source(id: id) == nil:
            router.selectedTab = .network
        case .location(let id) where store.location(id: id) == nil:
            router.selectedTab = .network
        default:
            break
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let request = router.importRequest else { return }
        do {
            let urls = try result.get()
            switch request {
            case .files(let destination):
                try FileService.importFiles(urls, into: destination)
            case .location:
                for url in urls {
                    try store.add(url)
                }
            case .drive(let name):
                for url in urls {
                    try store.add(url, driveName: name)
                }
            case .remoteUpload(let folder):
                try transfers.upload(urls, to: folder)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Files shared to the app ("Open in FileCat") are copied into its storage, then opened.
    /// `filecat://open?path=Music/Song.mp3` opens a file in Local Storage (used by companion apps).
    private func handleOpenURL(_ url: URL) {
        if let request = ServerShareRequest(url: url) {
            if request.appName == nil {
                errorMessage = "Only FileCat's own companion apps can import its servers."
            } else if sources.sources.isEmpty {
                errorMessage = "There are no servers to share yet. Add one in Connections first."
            } else {
                serverShare = request
            }
            return
        }
        var url = url
        if let link = FileCatLink(url: url) {
            guard let resolved = link.fileURL(in: FileService.documentsDirectory) else { return }
            url = resolved
        }
        guard url.isFileURL else { return }
        do {
            let local = FileService.isInside(url, FileService.documentsDirectory)
                ? url
                : try FileService.importFiles([url], into: FileService.documentsDirectory)[0]
            guard let item = FileService.item(for: local) else { return }

            router.selectedTab = .local
            if FileService.isSameLocation(item.url, FileService.documentsDirectory) {
                router.paths[.local] = []
            } else if item.kind == .audio {
                router.paths[.local] = []
                player.play(item, in: [item])
                router.showsNowPlaying = true
            } else {
                router.paths[.local] = [.file(item)]
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ContentView {
    /// Hands every server, password included, to the companion app that asked.
    private func shareServers(with request: ServerShareRequest) {
        let reply = ServerShareReply(servers: sources.sources.map { .init(server: $0.shared, password: $0.password) })
        openURL(reply.url(scheme: request.replyScheme)) { opened in
            if !opened { errorMessage = "\(request.appName ?? "The app") couldn't be opened." }
        }
    }
}

/// Asks before a companion app gets the servers and their passwords.
private struct ServerShareAlert: ViewModifier {
    @Binding var request: ServerShareRequest?
    let serverCount: Int
    let share: (ServerShareRequest) -> Void

    func body(content: Content) -> some View {
        let appName = request?.appName ?? ""
        let servers = serverCount == 1 ? "server" : "\(serverCount) servers"
        content.alert("Share Servers with \(appName)?", isPresented: Binding(isPresenting: $request), presenting: request) { request in
            Button("Cancel", role: .cancel) {}
            Button("Share") { share(request) }
        } message: { _ in
            Text("\(appName) gets the addresses, user names and passwords of your \(servers) and keeps them in its own keychain. Later changes reach it too; for a new password it asks again.")
        }
    }
}

extension ServerShareRequest {
    /// Apps allowed to ask for the servers, by URL scheme. Anyone can send FileCat a link, so the
    /// passwords only go to schemes of companion apps.
    fileprivate var appName: String? {
        ["musicat": "MusiCat"][replyScheme]
    }
}

extension EnvironmentValues {
    /// True for the iPad layout: the tab bar at the top, expanding into a sidebar. Pro Max iPhones
    /// are regular width in landscape too, but they keep the bottom tab bar: rebuilding the tabs
    /// mid-rotation crashes UIKit.
    var usesSidebarLayout: Bool {
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }
}

extension EnvironmentValues {
    /// The tab a screen is shown in, so its title menu knows which navigation stack it belongs to.
    @Entry var browserTab: AppTab = .local
}

extension FileTag {
    /// The tag's icon or color dot, in the tag's color, for places that need an image (the iPad
    /// sidebar tints SF Symbols with the accent color otherwise).
    var sidebarImage: UIImage {
        let color = UIColor(displayColor)
        if case .symbol(let name) = icon,
           let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)) {
            return symbol.withTintColor(isUncolored ? .secondaryLabel : color, renderingMode: .alwaysOriginal)
        }
        let side: CGFloat = 22
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let rect = CGRect(x: 5, y: 5, width: side - 10, height: side - 10)
            if isUncolored {
                UIColor.systemGray3.setStroke()
                let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            } else {
                color.setFill()
                UIBezierPath(ovalIn: rect).fill()
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

/// iPad: the activity indicator in the bottom corner; tap for the activity list.
private struct ActivityFloatingButton: View {
    @State private var isShowingList = false

    var body: some View {
        Button {
            isShowingList = true
        } label: {
            ActivityRing(size: 28)
                .frame(width: 52, height: 52)
                .modifier(GlassCapsule())
        }
        .buttonStyle(.plain)
        .padding(20)
        .accessibilityLabel("Activity")
        .accessibilityIdentifier("activityButton")
        .popover(isPresented: $isShowingList) {
            ActivitiesView()
                .frame(minWidth: 380, minHeight: 420)
        }
    }
}

/// Settings at the bottom of the iPad sidebar.
private struct SidebarSettingsButton: View {
    @Environment(Router.self) private var router

    var body: some View {
        let isSelected = router.selectedTab == .settings
        Button {
            router.selectedTab = .settings
            Self.closeSidebarIfOverlaying()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(isSelected ? Color.primary.opacity(0.1) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityIdentifier("sidebarSettings")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Choosing a real sidebar tab closes the sidebar when it covers the content (iPad in
    /// portrait); do the same, through the tab bar controller behind the TabView.
    private static func closeSidebarIfOverlaying() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window, window.bounds.width < 1000, let tabs = tabBarController(in: window.rootViewController) else { return }
        tabs.sidebar.isHidden = true
    }

    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = tabBarController(in: child) { return tabs }
        }
        return tabBarController(in: controller.presentedViewController)
    }
}
