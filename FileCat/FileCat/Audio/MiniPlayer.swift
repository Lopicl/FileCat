import SwiftUI

extension View {
    /// Shows the mini player above this screen's bottom toolbar and search bar while music is loaded,
    /// and on iPhone the activity button above it (on iPad that floats in the window's corner).
    ///
    /// It has to be applied to each screen inside the navigation stack: an inset on the split view
    /// itself sits outside the navigation bars, so the system toolbars end up underneath it.
    func miniPlayerInset(showsPlayer: Bool = true) -> some View {
        modifier(MiniPlayerInset(showsPlayer: showsPlayer))
    }
}

private struct MiniPlayerInset: ViewModifier {
    let showsPlayer: Bool

    @Environment(AudioPlayer.self) private var player
    @Environment(Router.self) private var router
    @Environment(\.usesSidebarLayout) private var usesSidebarLayout
    private var activities: ActivityCenter { .shared }

    func body(content: Content) -> some View {
        let isCovered = router.isSearching || router.isImmersive
        let showsMiniPlayer = showsPlayer && player.current != nil && !isCovered
        let showsActivity = !usesSidebarLayout && !activities.activities.isEmpty && !isCovered
        content
            // Screens that don't fill the height (the download placeholder) would otherwise carry
            // the inset up with them, into the middle of the screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Stacked so the two never overlap; lists scroll clear of both.
                VStack(spacing: 0) {
                    if showsActivity && showsPlayer {
                        activityButton
                    }
                    if showsMiniPlayer {
                        MiniPlayer { router.showsNowPlaying = true }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .overlay(alignment: .bottom) {
                // Without the player (Settings) the button floats over the screen instead of
                // insetting it, so the long cat at the end still runs down to the tab bar.
                if showsActivity && !showsPlayer {
                    activityButton
                }
            }
            .animation(.snappy, value: showsMiniPlayer)
            .animation(.snappy, value: showsActivity)
    }

    private var activityButton: some View {
        ActivityFloatingButton()
            // Lines up with the right end of the tab bar's pill (21pt in on every iPhone size).
            .padding(.trailing, 21)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// Floating bar shown while music is loaded. Tap to open the full player; swipe left to stop.
struct MiniPlayer: View {
    let onOpen: () -> Void

    @Environment(AudioPlayer.self) private var player
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    /// How far the pill has to travel before letting go stops playback.
    private let stopThreshold: CGFloat = 110

    var body: some View {
        pill
            .offset(x: dragOffset)
            .background(alignment: .trailing) { stopIndicator }
            .simultaneousGesture(swipeToStop)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer")
            .accessibilityAction(named: "Stop Playback") { player.stop() }
            .frame(maxWidth: 500)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .sensoryFeedback(.impact(weight: .medium), trigger: dragOffset < -stopThreshold)
    }

    private var pill: some View {
        HStack(spacing: 12) {
            ArtworkView(image: player.artwork, cornerRadius: 6)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let artist = player.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            Button("Next", systemImage: "forward.fill") {
                player.next()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MiniPlayerButtonStyle())
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: shape)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Stop Playback", systemImage: "stop.fill", role: .destructive) {
                player.stop()
            }
        }
    }

    /// Revealed under the pill as it slides left, like swipe-to-delete.
    private var stopIndicator: some View {
        let revealed = max(0, -dragOffset)
        return shape
            .fill(Color.red)
            .overlay(alignment: .trailing) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .scaleEffect(revealed > stopThreshold ? 1.15 : 1)
                    .frame(width: min(max(revealed, 0), 80))
                    .clipped()
            }
            .frame(width: revealed + 16)
            .opacity(revealed > 0 ? 1 : 0)
            .animation(.snappy(duration: 0.15), value: revealed > stopThreshold)
    }

    private var swipeToStop: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                guard !isDismissing, abs(drag.translation.width) > abs(drag.translation.height) else { return }
                // Only leftwards, with resistance past the threshold.
                let x = min(0, drag.translation.width)
                dragOffset = x > -stopThreshold ? x : -stopThreshold + (x + stopThreshold) * 0.6
            }
            .onEnded { drag in
                guard !isDismissing else { return }
                let flung = drag.predictedEndTranslation.width < -stopThreshold * 2.5
                if dragOffset < -stopThreshold || flung {
                    isDismissing = true
                    withAnimation(.easeIn(duration: 0.2)) {
                        dragOffset = -600
                    } completion: {
                        player.stop()
                        dragOffset = 0
                        isDismissing = false
                    }
                } else {
                    withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

private struct MiniPlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.4 : 1)
    }
}

struct ArtworkView: View {
    let image: UIImage?
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    GeometryReader { proxy in
                        ZStack {
                            LinearGradient(
                                colors: [Color(uiColor: .systemGray4), Color(uiColor: .systemGray5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.note")
                                .font(.system(size: proxy.size.width * 0.4))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
