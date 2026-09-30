import SwiftUI

struct Transfer: Identifiable {
    enum Mode {
        case move, copy

        var actionTitle: String {
            self == .move ? "Move" : "Copy"
        }
    }

    let id = UUID()
    let mode: Mode
    let urls: [URL]
}

struct FolderView: View {
    let url: URL
    let title: String

    @Environment(Router.self) private var router
    @Environment(AudioPlayer.self) private var player
    @Environment(TagStore.self) private var tagStore

    @AppStorage("viewStyle") private var viewStyle: ViewStyle = .list
    @AppStorage("sortKey") private var sortKey: SortKey = .name
    @AppStorage("sortAscending") private var sortAscending = true
    @AppStorage(AppSettings.tagsEnabled) private var tagsEnabled = true

    @State private var model: FolderModel
    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var isSelecting = false
    @State private var selection = Set<URL>()

    @State private var renameTarget: FileItem?
    @State private var isCreatingFolder = false
    @State private var isCreatingTextFile = false
    @State private var textEdit: TextEditRequest?
    @State private var newName = ""
    @State private var pendingDeletion: [URL]?
    @State private var transfer: Transfer?
    @State private var infoItem: FileItem?
    @State private var tagRequest: TagRequest?
    @State private var errorMessage: String?
    /// Cloud files being downloaded before they open.
    @State private var downloading = Set<URL>()
    @State private var isPrepared = Set<URL>()
    @State private var jobs = JobRunner()
    @State private var notice: String?

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        _model = State(initialValue: FolderModel(url: url))
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var items: [FileItem] {
        (isSearching ? model.searchResults : model.items)
            .sorted(by: sortKey, ascending: sortAscending)
    }

    var body: some View {
        dialogs(browser)
    }

    private var browser: some View {
        content
            .locationTitle(isSelecting ? selectionTitle : title, screenID: Route.fileID(url), isEnabled: !isSelecting)
            .searchPill(text: $query, isPresented: $isSearchPresented, prompt: "Search in \(title)")
            .onChange(of: query) { _, newValue in model.search(newValue) }
            .toolbar { toolbar }
            .toolbar(isSelecting ? .visible : .automatic, for: .bottomBar)
            .overlay { emptyState }
            .refreshable { model.load() }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: tagStore.revision) {
                // Tag changes don't touch the folder itself, so the directory monitor won't notice.
                model.load()
                if isSearching { model.search(query) }
            }
    }

    /// Alerts and sheets, kept apart from `browser` so the compiler can type-check each part.
    private func dialogs(_ view: some View) -> some View {
        view
            .alert("Rename", isPresented: Binding(isPresenting: $renameTarget), presenting: renameTarget) { item in
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") { perform { try FileService.rename(item.url, to: newName) } }
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create") { perform { try FileService.createFolder(named: newName, in: url) } }
            }
            .alert("New Text File", isPresented: $isCreatingTextFile) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    perform {
                        let file = try TextLoader.createFile(named: newName, in: url)
                        textEdit = TextEditRequest(url: file, name: file.lastPathComponent)
                    }
                }
            }
            .textEditor($textEdit) { model.load() }
            .alert(deletionTitle, isPresented: Binding(isPresenting: $pendingDeletion), presenting: pendingDeletion) { urls in
                Button("Delete", role: .destructive) {
                    perform { try FileService.delete(urls) }
                    endSelection()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This can't be undone.")
            }
            .alert("Something Went Wrong", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .alert(notice ?? "", isPresented: Binding(isPresenting: $notice)) {
                Button("OK") {}
            }
            .sheet(item: $transfer) { transfer in
                FolderPickerSheet(transfer: transfer) { destination in
                    run(transfer, to: destination)
                    endSelection()
                }
            }
            .sheet(item: $infoItem) { item in
                FileInfoView(item: item)
            }
            .sheet(item: $tagRequest) { request in
                TagEditorSheet(urls: request.urls)
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch viewStyle {
        case .list: listView
        case .grid: gridView
        }
    }

    private var listView: some View {
        List(selection: isSelecting ? $selection : .constant([])) {
            ForEach(items) { item in
                listRow(for: item)
                    .tag(item.url)
                    .contextMenu { contextMenu(for: item) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash") { pendingDeletion = [item.url] }
                            .tint(.red)
                        Button("More", systemImage: "ellipsis.circle") { infoItem = item }
                    }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
    }

    @ViewBuilder
    private func listRow(for item: FileItem) -> some View {
        let row = HStack {
            FileRow(item: item, showsLocation: isSearching)
            Spacer(minLength: 8)
            cloudBadge(for: item)
        }
        if isSelecting {
            row
        } else if item.isDirectory {
            NavigationLink(value: Route.file(item)) { row }
        } else {
            Button { open(item) } label: { row }
                .tint(Color.primary)
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12, alignment: .top)], spacing: 24) {
                ForEach(items) { item in
                    gridCell(for: item)
                        .contextMenu { contextMenu(for: item) }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func cloudBadge(for item: FileItem) -> some View {
        if downloading.contains(item.url) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Downloading")
        } else if item.cloud == .notDownloaded {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
                .accessibilityLabel("In iCloud only")
        }
    }

    @ViewBuilder
    private func gridCell(for item: FileItem) -> some View {
        let cell = FileGridCell(item: item, isSelecting: isSelecting, isSelected: selection.contains(item.url))
            .overlay(alignment: .topTrailing) {
                cloudBadge(for: item)
                    .padding(4)
            }
        Group {
            if isSelecting {
                Button { toggleSelection(item) } label: { cell }
            } else if item.isDirectory {
                NavigationLink(value: Route.file(item)) { cell }
            } else {
                Button { open(item) } label: { cell }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            if model.isSearching && items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        } else if model.isLoaded && items.isEmpty {
            if let error = model.error {
                ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView {
                    Label("No Items", systemImage: "folder")
                } description: {
                    Text("Import files or create a folder to get started.")
                } actions: {
                    Button("Import Files") { router.requestImport(.files(into: url)) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: Toolbar & menus

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let allSelected = !items.isEmpty && selection.count == items.count
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(items.map(\.url))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelection() }
                    .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(items: Array(selection)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Spacer()
                Menu {
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        perform { try FileService.duplicate(Array(selection)) }
                        endSelection()
                    }
                    Button("Copy To…", systemImage: "doc.on.doc") {
                        transfer = Transfer(mode: .copy, urls: Array(selection))
                    }
                    compressMenu(for: Array(selection))
                } label: {
                    Label("More Actions", systemImage: "ellipsis.circle")
                }
                .disabled(selection.isEmpty)
                if tagsEnabled {
                    Spacer()
                    Button("Tag", systemImage: "tag") {
                        tagRequest = TagRequest(urls: Array(selection))
                    }
                }
                Spacer()
                Button("Move", systemImage: "folder") {
                    transfer = Transfer(mode: .move, urls: Array(selection))
                }
                Spacer()
                Button("Delete", systemImage: "trash") {
                    pendingDeletion = Array(selection)
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                addMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu
            }
        }
    }

    private var addMenu: some View {
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
            Button("Import from Files", systemImage: "square.and.arrow.down") {
                router.requestImport(.files(into: url))
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .accessibilityIdentifier("addMenu")
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("Search", systemImage: "magnifyingglass") {
                    withAnimation(.snappy) { isSearchPresented = true }
                }
                Button("Select", systemImage: "checkmark.circle") { isSelecting = true }
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

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        Section {
            Button("Get Info", systemImage: "info.circle") { infoItem = item }
            if tagsEnabled {
                Button("Tags…", systemImage: "tag") { tagRequest = TagRequest(urls: [item.url]) }
            }
            Button("Rename", systemImage: "pencil") {
                newName = item.name
                renameTarget = item
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                perform { try FileService.duplicate([item.url]) }
            }
            if !item.isDirectory, item.cloud != .notDownloaded {
                Button("Edit as Text", systemImage: "square.and.pencil") {
                    textEdit = TextEditRequest(url: item.url, name: item.name)
                }
            }
            Button("Move", systemImage: "folder") {
                transfer = Transfer(mode: .move, urls: [item.url])
            }
            Button("Copy To…", systemImage: "doc.on.doc") {
                transfer = Transfer(mode: .copy, urls: [item.url])
            }
            ShareLink(item: item.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Section {
            if item.kind == .archive {
                Button("Extract Here", systemImage: "arrow.up.bin") { extract(item) }
            }
            compressMenu(for: [item.url])
        }
        if item.cloud == .notDownloaded {
            Button("Download Now", systemImage: "icloud.and.arrow.down") {
                download(item) {}
            }
        } else if item.cloud == .downloaded {
            Button("Remove Download", systemImage: "icloud.slash") {
                perform { try FileService.removeDownload(item.url) }
            }
        }
        Section {
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = [item.url]
            }
        }
    }

    private func compressMenu(for urls: [URL]) -> some View {
        Menu {
            ForEach(ArchiveFormat.allCases) { format in
                Button(format.title) { compress(urls, as: format) }
            }
        } label: {
            Label("Compress", systemImage: "archivebox")
        }
    }

    // MARK: Actions

    /// Copies or moves in the background, as an activity with progress.
    private func run(_ transfer: Transfer, to destination: URL) {
        let urls = transfer.urls
        let move = transfer.mode == .move
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        Task {
            do {
                let total = await Task.detached { ArchiveService.totalSize(of: urls) }.value
                try await ActivityCenter.shared.run(move ? .move : .copy, name: name, total: total) { cancellation, progress in
                    try FileService.transfer(urls, to: destination, move: move, cancellation: cancellation, progress: progress)
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            model.load()
        }
    }

    private func compress(_ urls: [URL], as format: ArchiveFormat) {
        guard !urls.isEmpty else { return }
        let directory = url
        endSelection()
        Task {
            do {
                let total = await Task.detached { ArchiveService.totalSize(of: urls) }.value
                let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
                _ = try await jobs.run(.compress, name: name, total: total) { cancellation, progress in
                    try ArchiveService.compress(urls, format: format, into: directory, cancellation: cancellation, progress: progress)
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            model.load()
        }
    }

    private func extract(_ item: FileItem) {
        let directory = url
        let password = ArchiveStore.shared.password(for: item.url)
        Task {
            do {
                let total = try? await ArchiveStore.shared.index(for: item.url).size(of: "")
                _ = try await jobs.run(.extract, name: item.name, total: total) { cancellation, progress in
                    try ArchiveService.extract(item.url, password: password, into: directory, cancellation: cancellation, progress: progress)
                }
            } catch is CancellationError {
            } catch ArchiveError.passwordRequired {
                // Opening the archive asks for the password; extracting from there works too.
                notice = "“\(item.name)” is protected with a password. Open it to enter the password, then extract."
            } catch {
                errorMessage = error.localizedDescription
            }
            model.load()
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select Items" : "\(selection.count) Selected"
    }

    private var deletionTitle: String {
        let count = pendingDeletion?.count ?? 0
        if count == 1, let url = pendingDeletion?.first {
            return "Delete “\(url.lastPathComponent)”?"
        }
        return "Delete \(count) Items?"
    }

    private func open(_ item: FileItem) {
        // Files from other cloud providers (picked in Files) may need fetching too; asking to read
        // them through a file coordinator makes the provider download them.
        let needsFetch = item.cloud == .notDownloaded
            || (item.cloud == nil && !FileService.isInside(item.url, FileService.documentsDirectory) && !isPrepared.contains(item.url))
        guard !needsFetch else {
            isPrepared.insert(item.url)
            download(item) {
                if let fresh = FileService.item(for: item.url) { open(fresh) }
            }
            return
        }
        if item.kind == .audio {
            player.play(item, in: items.filter { $0.kind == .audio })
            router.showsNowPlaying = true
        } else {
            router.push(.file(item))
        }
    }

    /// Fetches a cloud file, then runs `completion`.
    private func download(_ item: FileItem, then completion: @escaping () -> Void) {
        guard !downloading.contains(item.url) else { return }
        downloading.insert(item.url)
        let activityID = ActivityCenter.shared.begin(.download, name: item.name)
        Task {
            defer { downloading.remove(item.url) }
            do {
                try await FileService.downloadIfNeeded(item.url)
                ActivityCenter.shared.end(activityID)
                model.load()
                completion()
            } catch {
                ActivityCenter.shared.end(activityID, error: error)
                errorMessage = "“\(item.name)” couldn't be downloaded. \(error.localizedDescription)"
            }
        }
    }

    private func toggleSelection(_ item: FileItem) {
        if selection.contains(item.url) {
            selection.remove(item.url)
        } else {
            selection.insert(item.url)
        }
    }

    private func endSelection() {
        isSelecting = false
        selection.removeAll()
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
        model.load()
    }
}
