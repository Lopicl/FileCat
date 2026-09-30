import SwiftUI

/// Pushed to open a server file: downloads it (with progress) and then shows the usual viewer.
/// `gallery` holds the folder's other photos and videos so the viewer can swipe through them.
struct RemoteFile: Hashable {
    let item: RemoteItem
    var gallery: [RemoteItem] = []
}

/// Browses a folder on a server. Files show whether they're only on the server, downloaded, or
/// kept offline; opening one downloads it first.
struct RemoteFolderView: View {
    let folder: RemoteItem

    @Environment(Router.self) private var router
    @Environment(AudioPlayer.self) private var player
    @Environment(TransferCenter.self) private var transfers
    @Environment(SourceStore.self) private var sources

    @AppStorage("viewStyle") private var viewStyle: ViewStyle = .list
    @AppStorage("sortKey") private var sortKey: SortKey = .name
    @AppStorage("sortAscending") private var sortAscending = true
    @AppStorage(AppSettings.streamsMedia) private var streamsMedia = true

    @State private var items: [RemoteItem] = []
    @State private var isLoaded = false
    @State private var loadError: Error?
    @State private var query = ""
    @State private var isSearchPresented = false

    @State private var renameTarget: RemoteItem?
    @State private var isCreatingFolder = false
    @State private var isCreatingTextFile = false
    @State private var textEdit: TextEditRequest?
    @State private var newName = ""
    @State private var pendingDeletion: RemoteItem?
    @State private var infoItem: RemoteItem?
    @State private var shareURL: ShareableURL?
    @State private var errorMessage: String?
    @State private var notice: String?

    private var source: NetworkSource? {
        sources.source(id: folder.sourceID)
    }

    private var title: String {
        folder.path == "/" ? (source?.name ?? folder.name) : folder.name
    }

    private var visibleItems: [RemoteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? items : items.filter { $0.name.localizedStandardContains(query) }
        let order = filtered.map(\.fileItem).sorted(by: sortKey, ascending: sortAscending).map(\.name)
        let byName = Dictionary(filtered.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byName[$0] }
    }

    var body: some View {
        content
            .locationTitle(title, screenID: Route.remote(folder).screenID)
            .searchPill(text: $query, isPresented: $isSearchPresented, prompt: "Search in \(title)")
            .toolbar { toolbar }
            .overlay { emptyState }
            .refreshable { await load() }
            .task(id: transfers.listingRevision) { await load() }
            .safeAreaInset(edge: .top, spacing: 0) { uploadBanner }
            .alert("Rename", isPresented: Binding(isPresenting: $renameTarget), presenting: renameTarget) { item in
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") { rename(item, to: newName) }
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create") { createFolder(named: newName) }
            }
            .alert("New Text File", isPresented: $isCreatingTextFile) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createTextFile(named: newName) }
            }
            .textEditor($textEdit)
            .alert("Delete “\(pendingDeletion?.name ?? "")”?", isPresented: Binding(isPresenting: $pendingDeletion), presenting: pendingDeletion) { item in
                Button("Delete", role: .destructive) { delete(item) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It will be deleted from the server. This can't be undone.")
            }
            .alert("Something Went Wrong", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .alert(notice ?? "", isPresented: Binding(isPresenting: $notice)) {
                Button("OK") {}
            }
            .sheet(item: $infoItem) { item in
                RemoteInfoView(item: item)
            }
            .sheet(item: $shareURL) { shareable in
                ActivityView(items: [shareable.url])
                    .presentationDetents([.medium, .large])
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch viewStyle {
        case .list:
            List(visibleItems) { item in
                row(for: item)
                    .contextMenu { contextMenu(for: item) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash") { pendingDeletion = item }
                            .tint(.red)
                        Button("More", systemImage: "ellipsis.circle") { infoItem = item }
                    }
            }
            .listStyle(.plain)
        case .grid:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12, alignment: .top)], spacing: 24) {
                    ForEach(visibleItems) { item in
                        cell(for: item)
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func row(for item: RemoteItem) -> some View {
        let label = HStack {
            FileRow(item: item.fileItem)
            Spacer(minLength: 8)
            RemoteStatusBadge(item: item)
        }
        if item.isDirectory {
            NavigationLink(value: Route.remote(item)) { label }
        } else {
            Button { open(item) } label: { label }
                .tint(Color.primary)
        }
    }

    @ViewBuilder
    private func cell(for item: RemoteItem) -> some View {
        let cell = FileGridCell(item: item.fileItem)
            .overlay(alignment: .topTrailing) {
                RemoteStatusBadge(item: item)
                    .padding(4)
            }
        Group {
            if item.isDirectory {
                NavigationLink(value: Route.remote(item)) { cell }
            } else {
                Button { open(item) } label: { cell }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isLoaded {
            ProgressView()
        } else if let loadError {
            ContentUnavailableView {
                Label("Can't Open Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError.localizedDescription)
            } actions: {
                Button("Try Again") { Task { await load(reconnect: true) } }
                    .buttonStyle(.bordered)
            }
        } else if visibleItems.isEmpty {
            if query.isEmpty {
                ContentUnavailableView {
                    Label("No Items", systemImage: "folder")
                } description: {
                    Text("Upload files or create a folder.")
                } actions: {
                    Button("Upload Files") { router.requestImport(.remoteUpload(folder)) }
                        .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private var uploadBanner: some View {
        let uploads = transfers.uploads.filter { $0.folder == folder }
        if !uploads.isEmpty {
            let fraction = uploads.map(\.fraction).reduce(0, +) / Double(uploads.count)
            HStack(spacing: 12) {
                ProgressView(value: fraction)
                Text(uploads.count == 1 ? "Uploading “\(uploads[0].name)”" : "Uploading \(uploads.count) items")
                    .font(.footnote)
                    .lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: Toolbar & menus

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button("Create Folder", systemImage: "folder.badge.plus") {
                        newName = "New Folder"
                        isCreatingFolder = true
                    }
                    Button("Create Text File", systemImage: "doc.badge.plus") {
                        newName = "New Text File.txt"
                        isCreatingTextFile = true
                    }
                }
                Button("Upload from Files", systemImage: "square.and.arrow.up") {
                    router.requestImport(.remoteUpload(folder))
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("addMenu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button("Search", systemImage: "magnifyingglass") {
                        withAnimation(.snappy) { isSearchPresented = true }
                    }
                    offlineButton(for: folder)
                }
                Section {
                    Picker("View", selection: $viewStyle) {
                        Label("Icons", systemImage: "square.grid.2x2").tag(ViewStyle.grid)
                        Label("List", systemImage: "list.bullet").tag(ViewStyle.list)
                    }
                }
                Section("Sort By") {
                    ForEach(SortKey.allCases) { key in
                        Button {
                            if sortKey == key {
                                sortAscending.toggle()
                            } else {
                                sortKey = key
                                sortAscending = key.defaultAscending
                            }
                        } label: {
                            if sortKey == key {
                                Label(key.title, systemImage: sortAscending ? "chevron.up" : "chevron.down")
                            } else {
                                Text(key.title)
                            }
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func offlineButton(for item: RemoteItem) -> some View {
        if transfers.isPinned(item) {
            Button("Remove Download", systemImage: "icloud.slash") {
                transfers.removeDownload(item)
            }
        } else {
            Button("Keep Offline", systemImage: "arrow.down.circle") {
                perform { try await transfers.keepOffline(item) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: RemoteItem) -> some View {
        Section {
            Button("Get Info", systemImage: "info.circle") { infoItem = item }
            if !item.isDirectory {
                Button("Share…", systemImage: "square.and.arrow.up") {
                    perform { shareURL = ShareableURL(url: try await transfers.localCopy(of: item)) }
                }
            }
            Button("Save to Local Storage", systemImage: "internaldrive") {
                perform {
                    let saved = try await transfers.save(item, to: FileService.documentsDirectory)
                    notice = "Saved “\(saved.lastPathComponent)” to Local Storage."
                }
            }
            offlineButton(for: item)
            if !item.isDirectory, !transfers.isPinned(item), case .cached = transfers.status(of: item) {
                Button("Remove Download", systemImage: "icloud.slash") {
                    transfers.removeDownload(item)
                }
            }
            if !item.isDirectory {
                Button("Edit as Text", systemImage: "square.and.pencil") { editAsText(item) }
            }
            Button("Rename", systemImage: "pencil") {
                newName = item.name
                renameTarget = item
            }
        }
        Section {
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = item
            }
        }
    }

    // MARK: Actions

    private func load(reconnect: Bool = false) async {
        do {
            if reconnect { await RemoteConnections.shared.invalidate(folder.sourceID) }
            let fileSystem = try await transfers.fileSystem(for: folder.sourceID)
            let entries = try await fileSystem.list(folder.path)
            items = entries.map(folder.child)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            // A dropped connection is common after the app was in the background; retry once.
            if !reconnect, case RemoteError.connectionFailed = error {
                await load(reconnect: true)
                return
            }
            loadError = error
        }
        isLoaded = true
    }

    private func open(_ item: RemoteItem) {
        switch item.kind {
        case .audio:
            let queue = visibleItems.filter { $0.kind == .audio }
            let byURL = Dictionary(queue.map { ($0.fileItem.url, $0) }, uniquingKeysWith: { first, _ in first })
            let streams = streamsMedia
            player.play(item.fileItem, in: queue.map(\.fileItem)) { [transfers] file in
                guard let remote = byURL[file.url] else { return file.url }
                return try await transfers.localCopy(of: remote)
            } stream: { [transfers] file in
                guard streams, let remote = byURL[file.url] else { return nil }
                return try await transfers.stream(for: remote)
            }
            router.showsNowPlaying = true
        case .image, .video:
            router.push(.remoteFile(RemoteFile(item: item, gallery: visibleItems.filter { $0.kind == .image || $0.kind == .video })))
        default:
            router.push(.remoteFile(RemoteFile(item: item)))
        }
    }

    /// Downloads the file, then edits it; saving uploads it back.
    private func editAsText(_ item: RemoteItem) {
        perform {
            let local = try await transfers.localCopy(of: item)
            textEdit = TextEditRequest(url: local, name: item.name, afterSave: transfers.saveHandler(for: item))
        }
    }

    private func createTextFile(named name: String) {
        perform {
            let item = try await transfers.createTextFile(named: name, in: folder)
            editAsText(item)
        }
    }

    private func createFolder(named name: String) {
        let clean = FileService.sanitized(name)
        guard !clean.isEmpty else { return }
        perform {
            let fileSystem = try await transfers.fileSystem(for: folder.sourceID)
            try await fileSystem.createFolder(RemotePath.join(folder.path, clean))
            transfers.didChangeListing()
        }
    }

    private func rename(_ item: RemoteItem, to name: String) {
        let clean = FileService.sanitized(name)
        guard !clean.isEmpty, clean != item.name else { return }
        perform {
            let fileSystem = try await transfers.fileSystem(for: folder.sourceID)
            try await fileSystem.move(item.path, to: RemotePath.join(folder.path, clean))
            transfers.didModify(item)
            transfers.didChangeListing()
        }
    }

    private func delete(_ item: RemoteItem) {
        perform {
            let fileSystem = try await transfers.fileSystem(for: folder.sourceID)
            try await fileSystem.delete(item.path, isDirectory: item.isDirectory)
            transfers.removeDownload(item)
            transfers.didChangeListing()
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Cloud, progress ring, checkmark or pin, depending on where the file's data is.
struct RemoteStatusBadge: View {
    let item: RemoteItem

    @Environment(TransferCenter.self) private var transfers

    var body: some View {
        switch transfers.status(of: item) {
        case .remote:
            if !item.isDirectory {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("On server only")
            }
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityLabel("Downloading")
        case .cached:
            EmptyView()
        case .offline:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Kept offline")
        }
    }
}

/// Downloads a server file, then shows it in the matching viewer.
struct RemoteFileViewer: View {
    let file: RemoteFile

    @Environment(TransferCenter.self) private var transfers
    @AppStorage(AppSettings.streamsMedia) private var streamsMedia = true
    @State private var local: FileItem?
    @State private var error: Error?

    var body: some View {
        Group {
            if let local {
                if local.kind == .image || local.kind == .video {
                    MediaViewer(item: local, gallery: galleryItems)
                        .environment(\.fileResolver, resolver)
                } else {
                    FileDestination(item: local)
                        .environment(\.fileSaveHandler, transfers.saveHandler(for: file.item))
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Can't Download", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try Again") {
                        self.error = nil
                        Task { await download() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                VStack(spacing: 16) {
                    ThumbnailView(item: file.item.fileItem, side: 96)
                    Text(file.item.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if case .downloading(let fraction) = transfers.status(of: file.item) {
                        ProgressView(value: fraction)
                            .frame(maxWidth: 240)
                        if let size = file.item.size {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(Double(size) * fraction), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        ProgressView()
                    }
                }
                .padding()
                .navigationTitle(file.item.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await download() }
        .onDisappear {
            if local == nil { transfers.cancelDownload(of: file.item) }
        }
    }

    private var galleryItems: [FileItem] {
        file.gallery.isEmpty ? [] : file.gallery.map(\.fileItem)
    }

    private var resolver: FileResolver {
        let byURL = Dictionary((file.gallery + [file.item]).map { ($0.fileItem.url, $0) }, uniquingKeysWith: { first, _ in first })
        let streams = streamsMedia
        let canStream: @MainActor @Sendable (URL) -> Bool = { url in
            guard streams, let remote = byURL[url], remote.kind == .video, remote.size != nil else { return false }
            return RemoteCache.availableURL(for: remote) == nil
        }
        return FileResolver { [transfers] url in
            guard let remote = byURL[url] else { return url }
            return try await transfers.localCopy(of: remote)
        } canStream: { url in
            canStream(url)
        } stream: { [transfers] url in
            guard canStream(url), let remote = byURL[url] else { return nil }
            return try? await transfers.streamingAsset(for: remote)
        }
    }

    private func download() async {
        guard local == nil else { return }
        // Videos play while they download; the gallery streams them.
        if resolver.canStream(file.item.fileItem.url) {
            local = file.item.fileItem
            return
        }
        do {
            let url = try await transfers.localCopy(of: file.item)
            var item = file.item.fileItem
            if item.url != url {
                item = FileItem(url: url, name: item.name, isDirectory: false, size: item.size, modified: item.modified,
                                created: nil, childCount: nil, kind: item.kind, tags: [])
            }
            local = item
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }
}

/// Fetches the local copy of a file that may still be on a server, or streams it.
struct FileResolver: Sendable {
    let resolve: @MainActor @Sendable (URL) async throws -> URL
    /// Whether `stream` would play the file from the server rather than wait for the download.
    let canStream: @MainActor @Sendable (URL) -> Bool
    let stream: @MainActor @Sendable (URL) async -> StreamingAsset?

    init(
        _ resolve: @escaping @MainActor @Sendable (URL) async throws -> URL,
        canStream: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false },
        stream: @escaping @MainActor @Sendable (URL) async -> StreamingAsset? = { _ in nil }
    ) {
        self.resolve = resolve
        self.canStream = canStream
        self.stream = stream
    }

    static let local = FileResolver { $0 }
}

extension EnvironmentValues {
    @Entry var fileResolver: FileResolver = .local
}

struct ShareableURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct RemoteInfoView: View {
    let item: RemoteItem

    @Environment(\.dismiss) private var dismiss
    @Environment(TransferCenter.self) private var transfers
    @Environment(SourceStore.self) private var sources

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        ThumbnailView(item: item.fileItem, side: 120)
                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section("Information") {
                    if let size = item.size {
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let modified = item.modified {
                        LabeledContent("Modified", value: modified.formatted(date: .long, time: .shortened))
                    }
                    LabeledContent("Server", value: sources.source(id: item.sourceID)?.name ?? "")
                    LabeledContent("Path", value: item.path)
                    LabeledContent("On This Device", value: statusText)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        switch transfers.status(of: item) {
        case .remote: "Not downloaded"
        case .downloading: "Downloading…"
        case .cached: "Downloaded"
        case .offline: "Kept offline"
        }
    }
}
