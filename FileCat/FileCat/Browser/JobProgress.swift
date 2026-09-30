import Foundation

/// Runs a screen's slow file work (compressing, extracting) as activities in the activity center,
/// and tells the screen whether any of its own work is still running.
@MainActor
@Observable
final class JobRunner {
    private(set) var runningCount = 0

    var isBusy: Bool { runningCount > 0 }

    /// `total` is the number of bytes `work` will report through its progress callback.
    func run<T: Sendable>(
        _ kind: ActivityCenter.Kind,
        name: String,
        total: Int64?,
        work: @escaping @Sendable (CancellationFlag, @escaping @Sendable (Int64) -> Void) throws -> T
    ) async throws -> T {
        runningCount += 1
        defer { runningCount -= 1 }
        return try await ActivityCenter.shared.run(kind, name: name, total: total, work: work)
    }
}
