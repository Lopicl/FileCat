import SwiftUI

/// Current and past activities: copies, moves, downloads, uploads, extractions.
struct ActivitiesView: View {
    @Environment(\.dismiss) private var dismiss
    private var center: ActivityCenter { .shared }

    var body: some View {
        NavigationStack {
            List {
                let running = center.running
                let past = center.activities.filter { $0.state != .running }
                if !running.isEmpty {
                    Section("In Progress") {
                        ForEach(running) { activity in
                            ActivityRow(activity: activity)
                        }
                    }
                }
                if !past.isEmpty {
                    Section("Recent") {
                        ForEach(past) { activity in
                            ActivityRow(activity: activity)
                        }
                    }
                }
            }
            .overlay {
                if center.activities.isEmpty {
                    ContentUnavailableView(
                        "No Activity",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Copies, moves, downloads and extractions show up here.")
                    )
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { center.clearHistory() }
                        .disabled(!center.activities.contains { $0.state != .running })
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: ActivityCenter.Activity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.kind.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch activity.state {
                case .running:
                    if let fraction = activity.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView(value: nil as Double?)
                            .progressViewStyle(.linear)
                    }
                case .finished:
                    Text(detail("Done"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .cancelled:
                    Text(detail("Cancelled"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            if activity.state == .running, ActivityCenter.shared.canCancel(activity.id) {
                Button("Cancel", systemImage: "xmark.circle.fill") {
                    ActivityCenter.shared.cancel(activity.id)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "Done · 2:41 PM"
    private func detail(_ state: String) -> String {
        guard let ended = activity.ended else { return state }
        return "\(state) · \(ended.formatted(date: .omitted, time: .shortened))"
    }
}

/// A progress ring with the number of running activities in the middle. Spins while progress
/// isn't known.
struct ActivityRing: View {
    var size: CGFloat = 26

    private var center: ActivityCenter { .shared }

    var body: some View {
        let running = center.runningCount
        let fraction = center.overallFraction
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: running == 0 ? 1 : max(0.04, fraction ?? 0.25))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90 + (running > 0 && fraction == nil ? Double(center.spinnerPhase) * 30 : 0)))
                .animation(.linear(duration: 0.12), value: center.spinnerPhase)
                .animation(.easeInOut(duration: 0.25), value: fraction)
            if running > 0 {
                Text("\(running)")
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.38, weight: .bold))
            }
        }
        .frame(width: size, height: size)
    }

    /// The ring as a template image, for the tab bar (which only takes images).
    @MainActor
    static func image(running: Int, fraction: Double?, phase: Int, side: CGFloat = 26) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            let cg = context.cgContext
            let line = side * 0.1
            let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
            cg.setLineWidth(line)
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.25).cgColor)
            cg.strokeEllipse(in: rect)

            let amount = running == 0 ? 1 : max(0.04, fraction ?? 0.25)
            let start = -CGFloat.pi / 2 + (running > 0 && fraction == nil ? CGFloat(phase) * .pi / 6 : 0)
            let arc = UIBezierPath(arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                                   startAngle: start, endAngle: start + CGFloat(amount) * 2 * .pi, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            UIColor.black.setStroke()
            arc.stroke()

            let text = running > 0 ? "\(running)" : "✓"
            let font = UIFont.systemFont(ofSize: side * 0.42, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}
