import AVKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false
    @State private var showsEqualizer = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var displayedTime: Double {
        isScrubbing ? scrubTime : player.currentTime
    }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if let artwork = player.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.35)
                    .ignoresSafeArea()
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showsEqualizer) {
            EqualizerView()
        }
        .onChange(of: player.current == nil) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    // MARK: Layouts

    private var portraitLayout: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 8)
            artwork
                .frame(maxWidth: 340)
            titles
            progress
            transport
            secondaryControls
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 500)
    }

    /// iPhone in landscape: artwork and titles on the left half, controls on the right half.
    private var landscapeLayout: some View {
        HStack(spacing: 40) {
            VStack(spacing: 16) {
                artwork
                    .frame(maxWidth: 280)
                titles
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 24) {
                progress
                transport
                secondaryControls
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    // MARK: Parts

    private var artwork: some View {
        ArtworkView(image: player.artwork, cornerRadius: 16)
            .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
            .scaleEffect(player.isPlaying ? 1 : 0.88)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: player.isPlaying)
    }

    private var titles: some View {
        VStack(spacing: 4) {
            Text(player.title)
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("nowPlayingTitle")
            Text(player.artist ?? player.current?.parentName ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let error = player.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { displayedTime }, set: { scrubTime = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = player.currentTime
                        isScrubbing = true
                    } else {
                        player.seek(to: scrubTime)
                        isScrubbing = false
                    }
                })
            HStack {
                Text(formatTime(displayedTime))
                Spacer()
                Text("-" + formatTime(max(0, player.duration - displayedTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 48) {
            Button("Previous", systemImage: "backward.fill") { player.previous() }
                .font(.title)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlayPause()
            }
            .font(.system(size: 48))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 64, height: 64)
            .accessibilityIdentifier("nowPlayingPlayPause")
            Button("Next", systemImage: "forward.fill") { player.next() }
                .font(.title)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.primary)
    }

    private var secondaryControls: some View {
        HStack {
            Button {
                player.repeatMode = player.repeatMode.next
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Repeat")
            Spacer()
            if player.queue.count > 1 {
                Text("\(player.index + 1) of \(player.queue.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button {
                showsEqualizer = true
            } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(player.equalizer.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Equalizer")
            RoutePicker()
                .frame(width: 44, height: 44)
        }
        .font(.title3)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

/// AirPlay / Bluetooth output picker.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .secondaryLabel
        view.activeTintColor = .tintColor
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
