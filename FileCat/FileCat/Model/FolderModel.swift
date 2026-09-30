import Foundation
import Observation

/// Loads and watches the contents of one folder, and runs searches beneath it.
@MainActor
@Observable
final class FolderModel {
    let url: URL

    private(set) var items: [FileItem] = []
    private(set) var searchResults: [FileItem] = []
    private(set) var isLoaded = false
    private(set) var isSearching = false
    private(set) var error: String?

    @ObservationIgnored private var monitor: DirectoryMonitor?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func start() {
        load()
        if monitor == nil {
            monitor = DirectoryMonitor(url: url) { [weak self] in
                MainActor.assumeIsolated { self?.load() }
            }
        }
    }

    func stop() {
        monitor = nil
    }

    func load() {
        let url = url
        Task {
            do {
                items = try await Task.detached(priority: .userInitiated) {
                    try FileService.contents(of: url)
                }.value
                error = nil
            } catch {
                items = []
                self.error = error.localizedDescription
            }
            isLoaded = true
        }
    }

    func search(_ query: String) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        let url = url
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                FileService.search(query, in: url)
            }.value
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }
}
