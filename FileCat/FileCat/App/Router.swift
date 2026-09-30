import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ImportRequest {
    case files(into: URL)
    case location
    /// A drive that was just plugged in, from its Add button: the connection takes its name.
    case drive(name: String)
    case remoteUpload(RemoteItem)

    var contentTypes: [UTType] {
        switch self {
        case .files, .remoteUpload: [.item]
        case .location, .drive: [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .files, .remoteUpload: true
        case .location, .drive: false
        }
    }
}

/// The app's tabs. On iPad the sidebar also lists each tag, folder and server as its own tab.
enum AppTab: Hashable {
    case local, tags, network, settings
    /// Not a real tab: the Activity button in the iPhone tab bar, which opens the activity list.
    case activity
    case tag(String)
    case location(String)
    case server(String)
}

/// Pushed onto a navigation stack to show the files carrying a tag.
struct TagDestination: Hashable {
    let name: String
}

/// Everything a tab's navigation stack can show. The stack is a plain array of these, so the
/// title menu can list the folders you came through.
enum Route: Hashable {
    case file(FileItem)
    case remote(RemoteItem)
    case remoteFile(RemoteFile)
    case tag(TagDestination)
    case archive(ArchiveFolder)
}

/// Per-window navigation state shared by the browser and viewers.
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .local
    /// Each tab keeps its own navigation stack.
    var paths: [AppTab: [Route]] = [:]
    var showsNowPlaying = false
    var showsActivities = false
    /// The server editor, opened from the Connections tab or its title menu.
    var serverEditor: ServerEditorRequest?
    var isImporting = false
    /// True while a search pill is open; the mini player steps aside for it.
    var isSearching = false
    /// True while the gallery fills the screen (landscape on iPhone, or chrome hidden); the mini
    /// player steps aside for it.
    var isImmersive = false
    private(set) var importRequest: ImportRequest?

    /// The navigation stack of the selected tab.
    var path: [Route] {
        get { paths[selectedTab] ?? [] }
        set { paths[selectedTab] = newValue }
    }

    func path(for tab: AppTab) -> Binding<[Route]> {
        Binding { [self] in
            paths[tab] ?? []
        } set: { [self] newValue in
            paths[tab] = newValue
        }
    }

    /// Opens a file or folder in the selected tab.
    func push(_ route: Route) {
        path.append(route)
    }

    func requestImport(_ request: ImportRequest) {
        importRequest = request
        isImporting = true
    }
}
