import FileCatKit
import SwiftUI

extension Route {
    /// Identifies the screen a route shows, so a screen can find itself in the stack.
    var screenID: String {
        switch self {
        case .file(let item): Self.fileID(item.url)
        case .remote(let item): "remote:" + item.id
        case .remoteFile(let file): "remoteFile:" + file.item.id
        case .tag(let destination): "tag:" + destination.name
        case .archive(let folder): Self.archiveID(folder)
        }
    }

    static func fileID(_ url: URL) -> String {
        "file:" + url.standardizedFileURL.path(percentEncoded: false)
    }

    static func archiveID(_ folder: ArchiveFolder) -> String {
        "archive:" + folder.archive.path(percentEncoded: false) + "#" + folder.path
    }
}

extension View {
    /// Shows the screen's title as a menu listing where you are: every folder on the way here, and
    /// in the Connections and Tags tabs the other servers, folders and tags. On iPhone it's a
    /// Liquid Glass pill on the leading side of the navigation bar (centered in
    /// landscape); on iPad, the bar's title dropdown.
    ///
    /// - Parameters:
    ///   - screenID: the screen's `Route.screenID`, or `nil` for a tab's root screen.
    ///   - isEnabled: `false` shows `title` plainly (e.g. while selecting files).
    func locationTitle(_ title: String, screenID: String?, isEnabled: Bool = true) -> some View {
        modifier(LocationTitle(title: title, screenID: screenID, isEnabled: isEnabled))
    }
}

/// One row of the title menu.
struct PathCrumb: Identifiable {
    enum Icon {
        case symbol(String)
        case tag(FileTag)
    }

    let title: String
    let icon: Icon
    /// The tab's navigation stack that shows this place.
    let stack: [Route]

    var id: String { stack.last?.screenID ?? "root" }
}

private struct LocationTitle: ViewModifier {
    let title: String
    let screenID: String?
    let isEnabled: Bool

    @Environment(Router.self) private var router
    @Environment(LocationStore.self) private var locations
    @Environment(SourceStore.self) private var sources
    @Environment(TagStore.self) private var tags
    @Environment(\.browserTab) private var tab
    @Environment(\.usesSidebarLayout) private var usesSidebarLayout
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var titleSlotWidth: CGFloat?

    func body(content: Content) -> some View {
        let base = content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        if !isEnabled {
            // A plain title, large as usual: on iPad an inline one would hide behind the tab bar.
            content.navigationTitle(title)
        } else if usesSidebarLayout {
            base.toolbarTitleMenu { menuContent }
        } else {
            base.toolbar {
                ToolbarItem(placement: .principal) {
                    TitleSlot(slotWidth: titleSlotWidth, isCentered: isLandscape) {
                        Menu {
                            menuContent
                        } label: {
                            if isLandscape {
                                CappedWidth(maxWidth: titleSlotWidth) { pill }
                            } else {
                                pill
                            }
                        }
                        .accessibilityIdentifier("titleMenu")
                    }
                    .background(TitleSlotWidthReader { titleSlotWidth = $0 })
                }
            }
        }
    }

    // MARK: Pill

    /// On a landscape iPhone the bar has room to center the pill, and to make it wider.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private var pill: some View {
        let current = crumbs.last
        return HStack(spacing: 6) {
            if let current {
                icon(current.icon)
                    .font(.subheadline)
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: isLandscape ? 400 : min(260, titleSlotWidth ?? 260))
        .modifier(PillBackground())
        .contentShape(Capsule())
    }

    @ViewBuilder
    private func icon(_ icon: PathCrumb.Icon) -> some View {
        switch icon {
        case .symbol(let name): Image(systemName: name)
        case .tag(let tag): Image(uiImage: tag.sidebarImage).renderingMode(.original)
        }
    }

    // MARK: Menu

    private var isConnectionsTab: Bool {
        switch tab {
        case .network, .server, .location: true
        default: false
        }
    }

    private var isTagsTab: Bool {
        switch tab {
        case .tags, .tag: true
        default: false
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        let crumbs = crumbs
        // At the top of the Connections or Tags tab the path is just the tab itself, which the
        // section below lists anyway.
        if crumbs.count > 1 || (!isConnectionsTab && !isTagsTab) {
            Section {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    Button {
                        router.paths[tab] = crumb.stack
                    } label: {
                        Label {
                            Text(crumb.title)
                        } icon: {
                            icon(crumb.icon)
                        }
                    }
                    .disabled(index == crumbs.count - 1)
                }
            }
        }
        if isConnectionsTab {
            connectionsSection
            addConnectionMenu
        }
        if isTagsTab {
            tagsSection
        }
    }

    @ViewBuilder
    private var connectionsSection: some View {
        Section("Connections") {
            Button {
                go(sidebarTab: .network, stack: [])
            } label: {
                Label("All Connections", systemImage: "network")
            }
            ForEach(sources.sources) { source in
                Button {
                    go(sidebarTab: .server(source.id), stack: [.remote(.root(of: source))])
                } label: {
                    Label(source.name, systemImage: source.kind.systemImage)
                }
            }
            ForEach(locations.locations) { location in
                Button {
                    go(sidebarTab: .location(location.id), stack: [.file(Self.folderItem(location.url, name: location.name))])
                } label: {
                    Label(location.name, systemImage: location.systemImage)
                }
            }
        }
    }

    private var addConnectionMenu: some View {
        Menu {
            ForEach(NetworkSource.Kind.allCases) { kind in
                Button {
                    router.serverEditor = ServerEditorRequest(source: NetworkSource(kind: kind, name: "", host: ""), isNew: true)
                } label: {
                    Text(kind.title)
                    Text(kind.subtitle)
                    Image(systemName: kind.systemImage)
                }
            }
            Button {
                router.requestImport(.location)
            } label: {
                Text("Folder from Files")
                Text("iCloud Drive and other cloud storage from the Files app, USB drives, and servers connected in Files")
                Image(systemName: "folder.badge.plus")
            }
        } label: {
            Label("Add Connection", systemImage: "plus")
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            Button {
                go(sidebarTab: .tags, stack: [], phoneTab: .tags)
            } label: {
                Label("All Tags", systemImage: "tag")
            }
            ForEach(tags.tags) { tag in
                Button {
                    go(sidebarTab: .tag(tag.name), stack: [.tag(TagDestination(name: tag.name))], phoneTab: .tags)
                } label: {
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(uiImage: tag.sidebarImage).renderingMode(.original)
                    }
                }
            }
        }
    }

    /// On iPad every server, folder and tag is its own sidebar tab; on iPhone they're pushed onto
    /// the Connections or Tags tab.
    private func go(sidebarTab: AppTab, stack: [Route], phoneTab: AppTab = .network) {
        if usesSidebarLayout {
            router.paths[sidebarTab] = []
            router.selectedTab = sidebarTab
        } else {
            router.paths[phoneTab] = stack
        }
    }

    // MARK: Path

    /// Where the screen is, from the tab's top: one row per folder, including folders skipped on
    /// the way (e.g. after opening a search result).
    private var crumbs: [PathCrumb] {
        let stack = router.paths[tab] ?? []
        let depth = screenID.flatMap { id in stack.lastIndex { $0.screenID == id }.map { $0 + 1 } } ?? 0
        var result = [rootCrumb]
        var previous = rootPlace
        for index in 0..<min(depth, stack.count) {
            let route = stack[index]
            let prefix = Array(stack[..<index])
            let place = Self.place(of: route)
            if let previous, let place {
                for middle in Self.places(between: previous, and: place) {
                    let middleRoute = middle.route
                    result.append(crumb(for: middleRoute, stack: prefix + [middleRoute]))
                }
            }
            result.append(crumb(for: route, stack: prefix + [route]))
            previous = place
        }
        return result
    }

    private var rootCrumb: PathCrumb {
        switch tab {
        case .local:
            return PathCrumb(title: locations.documents.name, icon: .symbol("internaldrive"), stack: [])
        case .location(let id):
            let location = locations.location(id: id)
            return PathCrumb(title: location?.name ?? "Folder", icon: .symbol(location?.systemImage ?? "folder"), stack: [])
        case .network:
            return PathCrumb(title: "Connections", icon: .symbol("network"), stack: [])
        case .server(let id):
            let source = sources.source(id: id)
            return PathCrumb(title: source?.name ?? "Server", icon: .symbol(source?.kind.systemImage ?? "server.rack"), stack: [])
        case .tags:
            return PathCrumb(title: "Tags", icon: .symbol("tag"), stack: [])
        case .tag(let name):
            return PathCrumb(title: name, icon: tagIcon(name), stack: [])
        case .settings, .activity:
            return PathCrumb(title: "Settings", icon: .symbol("gearshape"), stack: [])
        }
    }

    private var rootPlace: Place? {
        switch tab {
        case .local: .local(locations.documents.url)
        case .location(let id): locations.location(id: id).map { .local($0.url) }
        case .server(let id): sources.source(id: id).map { .remote(.root(of: $0)) }
        default: nil
        }
    }

    private func crumb(for route: Route, stack: [Route]) -> PathCrumb {
        switch route {
        case .file(let item):
            let symbol = item.isDirectory ? (location(at: item.url)?.systemImage ?? "folder") : item.kind == .archive ? "doc.zipper" : "doc"
            return PathCrumb(title: location(at: item.url)?.name ?? item.name, icon: .symbol(symbol), stack: stack)
        case .remote(let item):
            if item.path == "/", let source = sources.source(id: item.sourceID) {
                return PathCrumb(title: source.name, icon: .symbol(source.kind.systemImage), stack: stack)
            }
            return PathCrumb(title: item.name, icon: .symbol("folder"), stack: stack)
        case .remoteFile(let file):
            return PathCrumb(title: file.item.name, icon: .symbol("doc"), stack: stack)
        case .tag(let destination):
            return PathCrumb(title: destination.name, icon: tagIcon(destination.name), stack: stack)
        case .archive(let folder):
            return PathCrumb(title: RemotePath.name(of: folder.path), icon: .symbol("folder"), stack: stack)
        }
    }

    private func tagIcon(_ name: String) -> PathCrumb.Icon {
        tags.tag(named: name).map { .tag($0) } ?? .symbol("tag")
    }

    /// An added folder, for its name and icon (iCloud Drive's root has an internal name).
    private func location(at url: URL) -> Location? {
        locations.all.first { FileService.isSameLocation($0.url, url) }
    }

    static func folderItem(_ url: URL, name: String? = nil) -> FileItem {
        FileItem(url: url, name: name ?? url.lastPathComponent, isDirectory: true, size: nil, modified: nil,
                 created: nil, childCount: nil, kind: .folder, tags: [])
    }

    // MARK: Places

    /// A folder-like place, for filling in the folders between two screens.
    private enum Place {
        case local(URL)
        case remote(RemoteItem)
        case archive(ArchiveFolder)

        var route: Route {
            switch self {
            case .local(let url): .file(LocationTitle.folderItem(url))
            case .remote(let item): .remote(item)
            case .archive(let folder): .archive(folder)
            }
        }
    }

    private static func place(of route: Route) -> Place? {
        switch route {
        case .file(let item):
            if item.isDirectory { return .local(item.url) }
            // An archive shows its top level.
            if item.kind == .archive { return .archive(ArchiveFolder(archive: item.url, path: "")) }
            return nil
        case .remote(let item): return .remote(item)
        case .archive(let folder): return .archive(folder)
        case .remoteFile, .tag: return nil
        }
    }

    /// The folders strictly between `from` and `to` when `to` is inside `from`.
    private static func places(between from: Place, and to: Place) -> [Place] {
        switch (from, to) {
        case (.local(let parent), .local(let child)):
            guard FileService.isInside(child, parent) else { return [] }
            let base = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents.count
            let components = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard components.count > base + 1 else { return [] }
            var url = parent
            return components[base..<(components.count - 1)].map { component in
                url = url.appending(path: component, directoryHint: .isDirectory)
                return .local(url)
            }
        case (.remote(let parent), .remote(let child)):
            guard parent.sourceID == child.sourceID else { return [] }
            let base = RemotePath.components(of: parent.path)
            let components = RemotePath.components(of: child.path)
            guard components.count > base.count + 1, Array(components.prefix(base.count)) == base else { return [] }
            var path = parent.path
            return components[base.count..<(components.count - 1)].map { name in
                path = RemotePath.join(path, name)
                return .remote(RemoteItem(sourceID: parent.sourceID, path: path, name: name, isDirectory: true))
            }
        case (.archive(let parent), .archive(let child)):
            guard parent.archive == child.archive else { return [] }
            let base = RemotePath.components(of: parent.path)
            let components = RemotePath.components(of: child.path)
            guard components.count > base.count + 1, Array(components.prefix(base.count)) == base else { return [] }
            return (base.count + 1..<components.count).map { length in
                .archive(ArchiveFolder(archive: parent.archive, path: components.prefix(length).joined(separator: "/")))
            }
        default:
            return []
        }
    }
}

/// Asks for its content's full size but draws it no wider than `maxWidth`, centered. The navigation
/// bar sizes its title slot from the full size, so the slot can grow back (e.g. after rotating).
private struct CappedWidth: Layout {
    let maxWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let width = min(bounds.width, maxWidth ?? .infinity)
        content.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                      proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// Pins the title to the leading edge of the navigation bar's title slot, as the bar does on its own
/// with a title too wide to center. It asks for more width than any bar has, so the bar always
/// falls back to that and fits the slot between its buttons (and grows it back, e.g. after rotating).
/// Centered, it asks for the title's own width and the bar centers it.
private struct TitleSlot: Layout {
    let slotWidth: CGFloat?
    let isCentered: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return isCentered ? size : CGSize(width: proposal.width ?? 10_000, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        if isCentered {
            content.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
            return
        }
        // SwiftUI also lays this out at its full width, centered on the slot.
        let slot = min(bounds.width, slotWidth ?? bounds.width)
        content.place(at: CGPoint(x: bounds.midX - slot / 2, y: bounds.midY), anchor: .leading,
                      proposal: .unspecified)
    }
}

/// Reports the width of the navigation bar's title slot. The bar fits the slot between its buttons,
/// but SwiftUI still lays the title out at its full width, so a long one runs under the buttons.
private struct TitleSlotWidthReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        Probe(onChange: onChange)
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: UIView {
        var onChange: (CGFloat) -> Void
        private var observation: NSKeyValueObservation?
        private var reported: CGFloat?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = nil
            guard window != nil, let slot = titleView else { return }
            observation = slot.layer.observe(\.bounds, options: [.initial, .new]) { [weak self] layer, _ in
                let width = layer.bounds.width
                DispatchQueue.main.async { self?.report(width) }
            }
        }

        private func report(_ width: CGFloat) {
            guard width > 0, width != reported else { return }
            reported = width
            onChange(width)
        }

        /// The navigation item's title view this probe is in.
        private var titleView: UIView? {
            var ancestors: [UIView] = []
            var view = superview
            while let current = view {
                if let bar = current as? UINavigationBar {
                    return bar.items?.lazy.compactMap(\.titleView).first { title in ancestors.contains { $0 === title } }
                }
                ancestors.append(current)
                view = current.superview
            }
            return nil
        }
    }
}

/// Liquid Glass on iOS 26 (the toolbar doesn't give the title slot any), a material before that.
private struct PillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
