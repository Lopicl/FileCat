#if os(iOS)
import ActivityKit
import Foundation

/// The Live Activity FileCat shows while it copies, moves, downloads or extracts files, so progress
/// stays visible on the Lock Screen and in the Dynamic Island when the app is in the background.
public struct FileActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// What's happening, e.g. "Copying “Photos”", or "3 activities".
        public var title: String
        /// An SF Symbol for the kind of work.
        public var symbol: String
        /// Activities still running.
        public var running: Int
        /// Overall progress (0...1), or `nil` when it isn't known.
        public var fraction: Double?
        /// When progress would have been 0 and 1 at the current speed, if it's known. The widget
        /// animates progress across this range by itself, because iOS ignores the app's updates
        /// while it runs in the background only for music playback.
        public var estimate: ClosedRange<Date>?

        public init(title: String, symbol: String, running: Int, fraction: Double?, estimate: ClosedRange<Date>? = nil) {
            self.title = title
            self.symbol = symbol
            self.running = running
            self.fraction = fraction
            self.estimate = estimate
        }
    }

    public init() {}
}
#endif
