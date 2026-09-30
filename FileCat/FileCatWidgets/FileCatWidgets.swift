import ActivityKit
import FileCatKit
import SwiftUI
import WidgetKit

@main
struct FileCatWidgets: WidgetBundle {
    var body: some Widget {
        FileActivityLiveActivity()
    }
}

/// Progress of FileCat's copies, moves, downloads and extractions on the Lock Screen and in the
/// Dynamic Island while the app is in the background.
struct FileActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FileActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProgressRing(state: context.state, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressBar(state: context.state)
                        .padding(.horizontal, 8)
                }
            } compactLeading: {
                ProgressRing(state: context.state, size: 20)
            } compactTrailing: {
                Text(context.state.running > 0 ? "\(context.state.running)" : "✓")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            } minimal: {
                ProgressRing(state: context.state, size: 20)
            }
            .keylineTint(.accentColor)
        }
    }
}

private struct LockScreenView: View {
    let state: FileActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ProgressRing(state: state, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let fraction = state.fraction, state.running > 0 {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressBar(state: state)
                Text(state.running == 0 ? "Done" : state.running == 1 ? "1 activity in FileCat" : "\(state.running) activities in FileCat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProgressBar: View {
    let state: FileActivityAttributes.ContentState

    var body: some View {
        if let fraction = state.fraction {
            ProgressView(value: fraction)
                .tint(.accentColor)
        } else {
            ProgressView(value: 0.3)
                .tint(.accentColor)
                .opacity(0.6)
        }
    }
}

/// A ring filling up with progress, the running count (or the activity's symbol) in the middle.
private struct ProgressRing: View {
    let state: FileActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.2), lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: state.running == 0 ? 1 : max(0.04, state.fraction ?? 0.25))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if state.running > 1 {
                Text("\(state.running)")
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            } else {
                Image(systemName: state.running == 0 ? "checkmark" : state.symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
    }
}
