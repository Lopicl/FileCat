import SwiftUI

/// Opens the server editor, either for a new server (optionally pre-filled from a nearby one) or
/// to edit a saved one.
struct ServerEditorRequest: Identifiable {
    let id = UUID()
    var source: NetworkSource
    var isNew: Bool
}

/// The Connections tab: the servers and folders you added, and servers found nearby. Everything
/// is added from the + menu.
struct NetworkView: View {
    @Environment(SourceStore.self) private var sources
    @Environment(LocationStore.self) private var locations
    @Environment(TransferCenter.self) private var transfers
    @Environment(Router.self) private var router

    @State private var discovery = ServiceDiscovery()
    @State private var pendingRemoval: PendingRemoval?

    private enum PendingRemoval: Identifiable {
        case source(NetworkSource)
        case location(id: String, name: String)

        var id: String {
            switch self {
            case .source(let source): source.id
            case .location(let id, _): id
            }
        }

        var name: String {
            switch self {
            case .source(let source): source.name
            case .location(_, let name): name
            }
        }
    }

    private var isEmpty: Bool {
        sources.sources.isEmpty && locations.locations.isEmpty && locations.disconnected.isEmpty
    }

    var body: some View {
        List {
            if isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "network")
                    } description: {
                        Text("Tap + to connect to an SMB, NFS, WebDAV or Nextcloud server, or to add a folder from the Files app.")
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if !sources.sources.isEmpty {
                Section("Servers") {
                    ForEach(sources.sources) { source in
                        NavigationLink(value: Route.remote(.root(of: source))) {
                            LabeledRow(title: source.name, subtitle: source.displayAddress, systemImage: source.kind.systemImage)
                        }
                        .contextMenu {
                            Button("Edit…", systemImage: "pencil") {
                                router.serverEditor = ServerEditorRequest(source: source, isNew: false)
                            }
                            Button("Keep Everything Offline", systemImage: "arrow.down.circle") {
                                Task { try? await transfers.keepOffline(.root(of: source)) }
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                pendingRemoval = .source(source)
                            }
                        }
                        .swipeActions {
                            Button("Remove", systemImage: "trash") { pendingRemoval = .source(source) }
                                .tint(.red)
                            Button("Edit", systemImage: "pencil") {
                                router.serverEditor = ServerEditorRequest(source: source, isNew: false)
                            }
                        }
                    }
                }
            }

            if !locations.locations.isEmpty || !locations.disconnected.isEmpty {
                Section {
                    ForEach(locations.locations) { location in
                        locationRow(location)
                    }
                    ForEach(locations.disconnected) { location in
                        LabeledRow(title: location.name, subtitle: "Not connected", systemImage: location.systemImage)
                            .foregroundStyle(.secondary)
                            .contextMenu {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    pendingRemoval = .location(id: location.id, name: location.name)
                                }
                            }
                            .swipeActions {
                                Button("Remove", systemImage: "minus.circle") {
                                    pendingRemoval = .location(id: location.id, name: location.name)
                                }
                                .tint(.red)
                            }
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    if !locations.disconnected.isEmpty {
                        Text("Drives that aren't plugged in reconnect by themselves when you plug them in again.")
                    }
                }
            }

            if !discovery.services.isEmpty {
                Section("Nearby") {
                    ForEach(discovery.services) { service in
                        Button {
                            Task { router.serverEditor = ServerEditorRequest(source: await service.resolved(), isNew: true) }
                        } label: {
                            LabeledRow(title: service.name, subtitle: service.kind.title, systemImage: service.kind.systemImage)
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .locationTitle("Connections", screenID: nil)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    addMenuItems
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
                .accessibilityIdentifier("addServerMenu")
            }
        }
        .refreshable {
            locations.reconnect()
            await transfers.syncAll()
        }
        .onAppear {
            discovery.start()
            locations.reconnect()
        }
        .onDisappear { discovery.stop() }
        .task {
            // Drives plugged in while the tab is open show up without a pull to refresh.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !locations.disconnected.isEmpty { locations.reconnect() }
            }
        }
        .alert(
            "Remove “\(pendingRemoval?.name ?? "")”?",
            isPresented: Binding(isPresenting: $pendingRemoval),
            presenting: pendingRemoval
        ) { removal in
            Button("Remove", role: .destructive) {
                switch removal {
                case .source(let source): sources.remove(source)
                case .location(let id, _): locations.remove(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            switch removal {
            case .source:
                Text("Its offline files are deleted from this device. Nothing is deleted on the server.")
            case .location:
                Text("The folder itself isn't deleted.")
            }
        }
    }

    /// Everything the + button can add: a server of each kind, or a folder from Files.
    @ViewBuilder
    private var addMenuItems: some View {
        Section("Server") {
            serverMenuItems
        }
        Section {
            Button {
                router.requestImport(.location)
            } label: {
                // Title, subtitle and icon: the form menus show with a subtitle.
                Text("Folder from Files")
                Text("iCloud Drive and other cloud storage from the Files app, USB drives, and servers connected in Files")
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityIdentifier("addFolderFromFiles")
        }
    }

    @ViewBuilder
    private var serverMenuItems: some View {
        ForEach(NetworkSource.Kind.allCases) { kind in
            Button {
                router.serverEditor = ServerEditorRequest(source: NetworkSource(kind: kind, name: "", host: ""), isNew: true)
            } label: {
                Text(kind.title)
                Text(kind.subtitle)
                Image(systemName: kind.systemImage)
            }
        }
    }

    private func locationRow(_ location: Location) -> some View {
        NavigationLink(value: Route.file(folderItem(location.url, name: location.name))) {
            LabeledRow(title: location.name, subtitle: nil, systemImage: location.systemImage)
        }
        .contextMenu {
            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                pendingRemoval = .location(id: location.id, name: location.name)
            }
        }
        .swipeActions {
            Button("Remove", systemImage: "minus.circle") { pendingRemoval = .location(id: location.id, name: location.name) }
                .tint(.red)
        }
    }

    private func folderItem(_ url: URL, name: String) -> FileItem {
        FileItem(url: url, name: name, isDirectory: true, size: nil, modified: nil, created: nil, childCount: nil, kind: .folder, tags: [])
    }
}

struct LabeledRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
