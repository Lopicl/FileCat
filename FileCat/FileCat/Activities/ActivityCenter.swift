import ActivityKit
import FileCatKit
import Observation
import UIKit

/// Everything FileCat does that takes a while (copying, moving, downloads, uploads, extracting and
/// compressing), so one indicator can show it all: the Activity button in the tab bar, its list,
/// and a Live Activity while the app is in the background.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    enum Kind: Sendable {
        case copy, move, download, upload, extract, compress

        var verb: String {
            switch self {
            case .copy: "Copying"
            case .move: "Moving"
            case .download: "Downloading"
            case .upload: "Uploading"
            case .extract: "Extracting"
            case .compress: "Compressing"
            }
        }

        var pastTense: String {
            switch self {
            case .copy: "Copied"
            case .move: "Moved"
            case .download: "Downloaded"
            case .upload: "Uploaded"
            case .extract: "Extracted"
            case .compress: "Compressed"
            }
        }

        var symbol: String {
            switch self {
            case .copy: "doc.on.doc"
            case .move: "folder"
            case .download: "arrow.down.circle"
            case .upload: "arrow.up.circle"
            case .extract: "arrow.up.bin"
            case .compress: "archivebox"
            }
        }
    }

    enum State: Equatable {
        case running, finished, cancelled
        case failed(String)
    }

    struct Activity: Identifiable {
        let id = UUID()
        let kind: Kind
        let name: String
        /// 0...1, or `nil` when the total isn't known.
        var fraction: Double?
        var state = State.running
        let started = Date()
        var ended: Date?

        var title: String {
            "\(state == .running ? kind.verb : kind.pastTense) “\(name)”"
        }
    }

    /// Newest first; finished ones stay as history until cleared.
    private(set) var activities: [Activity] = []
    /// Ticks while something runs, to animate indicators that can't animate themselves (the tab
    /// bar's image).
    private(set) var spinnerPhase = 0

    @ObservationIgnored private var cancels: [UUID: () -> Void] = [:]
    @ObservationIgnored private var spinner: Timer?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private let liveActivity = LiveActivityController()
    private static let historyLimit = 50

    var running: [Activity] {
        activities.filter { $0.state == .running }
    }

    var runningCount: Int {
        activities.reduce(0) { $0 + ($1.state == .running ? 1 : 0) }
    }

    /// Average progress of the running activities that know theirs; `nil` if none do.
    var overallFraction: Double? {
        let known = running.compactMap(\.fraction)
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    // MARK: Reporting

    /// Records the start of some work. `cancel`, if given, is offered in the activity list.
    @discardableResult
    func begin(_ kind: Kind, name: String, cancel: (() -> Void)? = nil) -> UUID {
        let activity = Activity(kind: kind, name: name)
        activities.insert(activity, at: 0)
        if activities.count > Self.historyLimit {
            activities.removeLast(activities.count - Self.historyLimit)
        }
        if let cancel { cancels[activity.id] = cancel }
        didChange()
        return activity.id
    }

    func update(_ id: UUID, fraction: Double) {
        guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == .running else { return }
        activities[index].fraction = min(1, max(0, fraction))
        liveActivity.update(from: self)
    }

    /// Records the end of some work; a `CancellationError` counts as cancelled.
    func end(_ id: UUID, error: Error? = nil) {
        guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == .running else { return }
        switch error {
        case nil:
            activities[index].state = .finished
            activities[index].fraction = 1
        case is CancellationError:
            activities[index].state = .cancelled
        case let error?:
            activities[index].state = .failed(error.localizedDescription)
        }
        activities[index].ended = Date()
        cancels[id] = nil
        didChange()
    }

    func canCancel(_ id: UUID) -> Bool {
        cancels[id] != nil
    }

    func cancel(_ id: UUID) {
        cancels[id]?()
    }

    func clearHistory() {
        activities.removeAll { $0.state != .running }
    }

    /// Runs `work` off the main thread as an activity with progress and cancellation. `total` is
    /// the number of bytes `work` reports through its progress callback.
    func run<T: Sendable>(
        _ kind: Kind,
        name: String,
        total: Int64?,
        work: @escaping @Sendable (CancellationFlag, @escaping @Sendable (Int64) -> Void) throws -> T
    ) async throws -> T {
        let cancellation = CancellationFlag()
        let id = begin(kind, name: name) { cancellation.cancel() }
        let reporter = ProgressReporter { [weak self] bytes in
            guard let total, total > 0 else { return }
            self?.update(id, fraction: Double(bytes) / Double(total))
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try work(cancellation) { reporter.report($0) }
            }.value
            end(id)
            return result
        } catch {
            end(id, error: error)
            throw error
        }
    }

    // MARK: Side effects

    private func didChange() {
        let isRunning = runningCount > 0
        if isRunning, spinner == nil {
            spinner = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.spinnerPhase += 1 }
            }
        } else if !isRunning {
            spinner?.invalidate()
            spinner = nil
        }
        // Ask for time to finish if the app goes to the background meanwhile.
        if isRunning, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FileCat activities") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        } else if !isRunning {
            endBackgroundTask()
        }
        liveActivity.update(from: self)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Keeps one Live Activity in step with the activity center: started when work begins (Live
/// Activities can only start in the foreground), updated at most twice a second, ended when
/// everything is done.
@MainActor
private final class LiveActivityController {
    private var activity: Activity<FileActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var pending: Task<Void, Never>?

    func update(from center: ActivityCenter) {
        let running = center.running
        if running.isEmpty {
            pending?.cancel()
            pending = nil
            end(center)
            return
        }
        let state = FileActivityAttributes.ContentState(
            title: running.count == 1 ? running[0].title : "\(running.count) activities",
            symbol: running.count == 1 ? running[0].kind.symbol : "square.stack.3d.up",
            running: running.count,
            fraction: center.overallFraction
        )
        if activity == nil {
            guard ActivityAuthorizationInfo().areActivitiesEnabled,
                  UIApplication.shared.applicationState == .active
            else { return }
            activity = try? Activity.request(attributes: FileActivityAttributes(), content: .init(state: state, staleDate: nil))
            lastUpdate = Date()
            return
        }
        // Throttle: progress arrives many times a second.
        let wait = 0.5 - Date().timeIntervalSince(lastUpdate)
        guard wait <= 0 else {
            if pending == nil {
                pending = Task { [weak self, weak center] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, let center, !Task.isCancelled else { return }
                    self.pending = nil
                    self.update(from: center)
                }
            }
            return
        }
        lastUpdate = Date()
        let current = activity
        Task { await current?.update(.init(state: state, staleDate: nil)) }
    }

    private func end(_ center: ActivityCenter) {
        guard let current = activity else { return }
        activity = nil
        let last = center.activities.first
        let state = FileActivityAttributes.ContentState(
            title: last.map(\.title) ?? "Done",
            symbol: "checkmark.circle",
            running: 0,
            fraction: 1
        )
        Task { await current.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4)) }
    }
}
