import AVKit
import SwiftUI

/// Plays the video on the gallery page currently on screen. One player is shared by all video
/// pages: swiping to a video loads it, swiping away stops it.
@MainActor
@Observable
final class GalleryVideoController {
    @ObservationIgnored let player = AVPlayer()

    private(set) var url: URL?
    private(set) var isPlaying = false
    /// Waiting for data, e.g. while a server video streams in.
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// Gallery videos start muted; the choice carries over as you swipe between videos.
    var isMuted = true {
        didSet { player.isMuted = isMuted }
    }

    /// How many galleries have a video loaded; the music player checks this before it releases
    /// the shared audio session.
    private static var loadedCount = 0
    static var hasLoadedVideo: Bool { loadedCount > 0 }

    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isScrubbing = false
    /// The server stream the current video plays from, if any.
    @ObservationIgnored private var streamingAsset: StreamingAsset?

    init() {
        player.isMuted = true
        // Keep the item at its end instead of advancing, so it can loop.
        player.actionAtItemEnd = .none
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    isolated deinit {
        streamingAsset?.release()
        if url != nil { Self.loadedCount -= 1 }
    }

    /// Plays the video at `url`, or from `streaming` (a server video that's still downloading),
    /// in which case `url` just identifies the video.
    func load(_ url: URL, streaming: StreamingAsset? = nil, autoplay: Bool = true) {
        guard url.standardizedFileURL != self.url?.standardizedFileURL else {
            streaming?.release()
            return
        }
        if self.url == nil { Self.loadedCount += 1 }
        self.url = url
        currentTime = 0
        duration = 0
        streamingAsset?.release()
        streamingAsset = streaming

        let item = streaming.map { AVPlayerItem(asset: $0.asset) } ?? AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        // Loop, like a photo gallery.
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
        if autoplay {
            player.play()
        }
        isPlaying = autoplay
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        streamingAsset?.release()
        streamingAsset = nil
        isBuffering = false
        if url != nil { Self.loadedCount -= 1 }
        url = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func beginScrubbing() {
        isScrubbing = true
    }

    func scrub(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func endScrubbing() {
        isScrubbing = false
    }

    private func tick(_ time: CMTime) {
        guard player.currentItem != nil else { return }
        if !isScrubbing {
            currentTime = time.seconds.isFinite ? time.seconds : 0
        }
        if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
            duration = seconds
        }
        isPlaying = player.timeControlStatus != .paused
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
}

/// Renders an AVPlayer's video, aspect-fit.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

/// Play/pause, scrubber, mute and full screen for the gallery's current video.
/// When the rest of the chrome is hidden, only the mute button stays.
struct GalleryVideoControls: View {
    let video: GalleryVideoController
    let showsFullControls: Bool
    let onFullScreen: () -> Void

    var body: some View {
        Group {
            if showsFullControls {
                HStack(spacing: 10) {
                    Button(video.isPlaying ? "Pause" : "Play", systemImage: video.isPlaying ? "pause.fill" : "play.fill") {
                        video.togglePlayPause()
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityIdentifier("videoPlayPause")

                    Text(formatTime(video.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(get: { video.currentTime }, set: { video.scrub(to: $0) }),
                        in: 0...max(video.duration, 0.1),
                        onEditingChanged: { editing in
                            editing ? video.beginScrubbing() : video.endScrubbing()
                        }
                    )
                    .accessibilityLabel("Position")

                    Text("-" + formatTime(max(0, video.duration - video.currentTime)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    muteButton

                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: onFullScreen)
                        .accessibilityIdentifier("videoFullScreen")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            } else {
                HStack {
                    Spacer()
                    muteButton
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 600)
    }

    private var muteButton: some View {
        Button(video.isMuted ? "Unmute" : "Mute", systemImage: video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
            video.isMuted.toggle()
        }
        .contentTransition(.symbolEffect(.replace))
        .accessibilityIdentifier("videoMute")
    }
}

/// A still frame shown for videos that aren't on screen yet (and until the first frame renders).
enum VideoPoster {
    static func image(for url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Full screen

/// Presents the system video player (with its own controls, AirPlay and Picture in Picture)
/// for a player that's already playing in the gallery.
enum FullScreenVideoPlayer {
    @MainActor
    /// `onDismiss` receives whether the video was playing when the player was closed.
    static func present(_ player: AVPlayer, onDismiss: @escaping (_ wasPlaying: Bool) -> Void) {
        guard let presenter = topViewController() else { return }
        let controller = DismissAwarePlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.modalPresentationStyle = .fullScreen
        controller.onDismiss = onDismiss
        presenter.present(controller, animated: true) {
            player.play()
        }
    }

    private final class DismissAwarePlayerViewController: AVPlayerViewController {
        var onDismiss: ((Bool) -> Void)?
        private var wasPlaying = false

        override func viewWillDisappear(_ animated: Bool) {
            wasPlaying = player.map { $0.timeControlStatus != .paused } ?? false
            super.viewWillDisappear(animated)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil {
                // Hand the shared player back to the gallery.
                player = nil
                onDismiss?(wasPlaying)
                onDismiss = nil
            }
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
