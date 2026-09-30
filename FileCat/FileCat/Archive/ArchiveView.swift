import FileCatKit
import SwiftUI

/// Pushed to show a folder inside an archive.
struct ArchiveFolder: Hashable {
    let archive: URL
    /// "" for the archive's top level.
    let path: String
}

/// Remembers archive listings and passwords while the app runs, so moving between an archive's
/// folders doesn't read the whole archive again.
@MainActor
final class ArchiveStore {
    static let shared = ArchiveStore()

    private var indexes: [URL: (modified: Date?, index: ArchiveIndex)] = [:]
    private var passwords: [URL: String] = [:]

    func password(for archive: URL) -> String? {
        passwords[archive]
    }

    func setPassword(_ password: String, for archive: URL) {
        passwords[archive] = password
        indexes[archive] = nil
    }

    func index(for archive: URL) async throws -> ArchiveIndex {
        let modified = (try? archive.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = indexes[archive], cached.modified == modified {
            return cached.index
        }
        let password = passwords[archive]
        let index = try await Task.detached(priority: .userInitiated) {
            ArchiveIndex(entries: try ArchiveService.list(archive, password: password))
        }.value
        indexes[archive] = (modified, index)
        return index
    }
}

/// Browses the inside of a ZIP, RAR, 7-Zip, TAR… archive like a folder. Files open after being
/// unpacked to a temporary folder; anything can be extracted next to the archive.
struct ArchiveView: View {
    let folder: ArchiveFolder
    let title: String

    @Environment(Router.self) private var router
    @Environment(AudioPlayer.self) private var player

    @AppStorage("sortKey") private var sortKey: SortKey = .name
    @AppStorage("sortAscending") private var sortAscending = true

    @State private var index: ArchiveIndex?
    @State private var loadError: Error?
    @State private var jobs = JobRunner()
    @State private var isAskingPassword = false
    @State private var password = ""
    @State private var wrongPassword = false
    /// Runs again once the user has entered the archive's password.
    @State private var retry: (() -> Void)?
    @State private var notice: String?
    @State private var errorMessage: String?

    init(archive: URL, path: String = "", title: String) {
        folder = ArchiveFolder(archive: archive, path: path)
        self.title = title
    }

    init(folder: ArchiveFolder) {
        self.folder = folder
        title = folder.path.isEmpty ? folder.archive.lastPathComponent : ArchiveEntry(path: folder.path, isDirectory: true, size: nil, modified: nil, isEncrypted: false).name
    }

    private var entries: [ArchiveEntry] {
        guard let index else { return [] }
        let children = visibleChildren(of: folder.path, in: index)
        let items = children.map(fileItem(for:)).sorted(by: sortKey, ascending: sortAscending)
        let byURL = Dictionary(children.map { (fileItem(for: $0).url, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { byURL[$0.url] }
    }

    /// Where extracted items go: next to the archive, or Local Storage for archives that are only
    /// cached copies of server files.
    private var extractionFolder: URL {
        let parent = folder.archive.deletingLastPathComponent()
        let isScratch = [URL.cachesDirectory, URL.temporaryDirectory, URL.applicationSupportDirectory]
            .contains { FileService.isInside(folder.archive, $0) }
        return isScratch ? FileService.documentsDirectory : parent
    }

    var body: some View {
        List(entries, id: \.path) { entry in
            row(for: entry)
                .contextMenu {
                    if !entry.isDirectory {
                        Button("Open", systemImage: "doc") { open(entry) }
                    }
                    Button("Extract", systemImage: "arrow.up.bin") { extract(entry.path) }
                }
                .swipeActions(edge: .trailing) {
                    Button("Extract", systemImage: "arrow.up.bin") { extract(entry.path) }
                        .tint(.accentColor)
                }
        }
        .listStyle(.plain)
        .locationTitle(title, screenID: folder.path.isEmpty ? Route.fileID(folder.archive) : Route.archiveID(folder))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(folder.path.isEmpty ? "Extract All" : "Extract Folder", systemImage: "arrow.up.bin") {
                    extract(folder.path.isEmpty ? nil : folder.path)
                }
                .disabled(index == nil || jobs.isBusy)
                .accessibilityIdentifier("extractAll")
            }
        }
        .overlay { emptyState }
        .task { await load() }
        .alert("Enter Password", isPresented: $isAskingPassword) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { retry = nil }
            Button("OK") {
                ArchiveStore.shared.setPassword(password, for: folder.archive)
                let action = retry
                retry = nil
                action?()
            }
        } message: {
            Text(wrongPassword
                 ? "The password for “\(folder.archive.lastPathComponent)” is incorrect. Try again."
                 : "“\(folder.archive.lastPathComponent)” is protected with a password.")
        }
        .alert(notice ?? "", isPresented: Binding(isPresenting: $notice)) {
            Button("OK") {}
        }
        .alert("Something Went Wrong", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private func row(for entry: ArchiveEntry) -> some View {
        let label = FileRow(item: fileItem(for: entry))
        if entry.isDirectory {
            NavigationLink(value: Route.archive(ArchiveFolder(archive: folder.archive, path: entry.path))) { label }
        } else {
            Button { open(entry) } label: {
                HStack {
                    label
                    Spacer(minLength: 8)
                    if entry.isEncrypted {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Encrypted")
                    }
                }
            }
            .tint(Color.primary)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Can't Open Archive", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError.localizedDescription)
            } actions: {
                if loadError as? ArchiveError == .passwordRequired {
                    Button("Enter Password") { askForPassword { Task { await load() } } }
                        .buttonStyle(.bordered)
                }
            }
        } else if index == nil {
            ProgressView()
        } else if entries.isEmpty {
            ContentUnavailableView("Empty Archive", systemImage: "archivebox")
        }
    }

    /// Hidden files and the resource forks macOS adds to ZIPs stay out of sight, like in folders.
    private func visibleChildren(of path: String, in index: ArchiveIndex) -> [ArchiveEntry] {
        index.children(of: path).filter { !$0.name.hasPrefix(".") && $0.name != "__MACOSX" }
    }

    /// A stand-in `FileItem`, so entries show with the usual rows and icons.
    private func fileItem(for entry: ArchiveEntry) -> FileItem {
        let url = folder.archive.appending(path: entry.path, directoryHint: entry.isDirectory ? .isDirectory : .notDirectory)
        return FileItem(
            url: url, name: entry.name, isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified,
            created: nil, childCount: entry.isDirectory ? index.map { visibleChildren(of: entry.path, in: $0).count } : nil,
            kind: FileKind(url: url, isDirectory: entry.isDirectory), tags: []
        )
    }

    // MARK: Actions

    private func load() async {
        do {
            index = try await ArchiveStore.shared.index(for: folder.archive)
            loadError = nil
        } catch ArchiveError.passwordRequired {
            loadError = ArchiveError.passwordRequired
            askForPassword { Task { await load() } }
        } catch {
            loadError = error
        }
    }

    private func askForPassword(then action: @escaping () -> Void) {
        wrongPassword = ArchiveStore.shared.password(for: folder.archive) != nil
        password = ""
        retry = action
        isAskingPassword = true
    }

    /// Unpacks a file to a temporary folder and opens it in the matching viewer.
    private func open(_ entry: ArchiveEntry) {
        guard !jobs.isBusy else { return }
        let archive = folder.archive
        let password = ArchiveStore.shared.password(for: archive)
        let scratch = URL.temporaryDirectory.appending(path: "Archives/\(UUID().uuidString)", directoryHint: .isDirectory)
        Task {
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let url = try await jobs.run(.extract, name: entry.name, total: entry.size) { cancellation, progress in
                    try ArchiveService.extract(archive, password: password, entryPath: entry.path, into: scratch, cancellation: cancellation, progress: progress)
                }
                guard let item = FileService.item(for: url) else { return }
                if item.kind == .audio {
                    player.play(item, in: [item])
                    router.showsNowPlaying = true
                } else {
                    router.push(.file(item))
                }
            } catch {
                handle(error) { open(entry) }
            }
        }
    }

    /// Extracts an entry (or everything, for `nil`) next to the archive.
    private func extract(_ entryPath: String?) {
        guard !jobs.isBusy else { return }
        let archive = folder.archive
        let password = ArchiveStore.shared.password(for: archive)
        let destination = extractionFolder
        let total = index?.size(of: entryPath ?? "")
        let name = entryPath.map { ArchiveEntry(path: $0, isDirectory: false, size: nil, modified: nil, isEncrypted: false).name } ?? archive.lastPathComponent
        Task {
            do {
                let url = try await jobs.run(.extract, name: name, total: total) { cancellation, progress in
                    try ArchiveService.extract(archive, password: password, entryPath: entryPath, into: destination, cancellation: cancellation, progress: progress)
                }
                let place = FileService.isSameLocation(destination, FileService.documentsDirectory) ? "Local Storage" : destination.lastPathComponent
                notice = "Extracted “\(url.lastPathComponent)” to \(place)."
            } catch {
                handle(error) { extract(entryPath) }
            }
        }
    }

    private func handle(_ error: Error, retrying action: @escaping () -> Void) {
        if error is CancellationError { return }
        if error as? ArchiveError == .passwordRequired {
            askForPassword(then: action)
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
