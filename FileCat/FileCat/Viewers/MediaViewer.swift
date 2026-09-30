import ImageIO
import SwiftUI

/// Full-screen gallery for the photos and videos in a folder. Swipe between them, pinch or
/// double-tap photos to zoom, tap to hide the chrome. Videos play inline, muted and looping;
/// the full system player is one tap away.
struct MediaViewer: View {
    let item: FileItem
    /// The photos and videos to swipe through. Empty means "the ones in the item's folder".
    var gallery: [FileItem] = []

    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.fileResolver) private var resolver
    @AppStorage("sortKey") private var sortKey: SortKey = .name
    @AppStorage("sortAscending") private var sortAscending = true
    @AppStorage(AppSettings.galleryAutoplay) private var autoplay = true
    @AppStorage(AppSettings.galleryStartsMuted) private var startsMuted = true

    @State private var items: [FileItem] = []
    @State private var current: URL?
    @State private var chromeHidden = false
    @State private var video = GalleryVideoController()
    /// The system player covers the gallery without leaving it, so playback must carry on.
    @State private var isShowingFullScreen = false

    private var isImmersive: Bool {
        chromeHidden || verticalSizeClass == .compact
    }

    private var currentItem: FileItem? {
        items.first { $0.url == current }
    }

    var body: some View {
        PageView(ids: items.map(\.url), current: $current) { url in
            if let media = items.first(where: { $0.url == url }) {
                page(for: media)
            }
        }
        .background(chromeHidden ? Color.black : Color(uiColor: .systemBackground))
        // Full height, but not under the iPad sidebar: pages there would peek out behind it.
        .ignoresSafeArea(edges: .vertical)
        .overlay(alignment: .bottom) {
            if currentItem?.kind == .video {
                GalleryVideoControls(video: video, showsFullControls: !chromeHidden) {
                    video.isMuted = false
                    isShowingFullScreen = true
                    FullScreenVideoPlayer.present(video.player) { wasPlaying in
                        isShowingFullScreen = false
                        // Carry on in the gallery the way it was left in full screen.
                        if wasPlaying {
                            video.play()
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .navigationTitle(currentItem?.name ?? item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
        // In landscape on iPhone (and whenever the chrome is hidden) photos and videos get the whole
        // screen: no tab bar, no mini player.
        .toolbar(isImmersive ? .hidden : .automatic, for: .tabBar)
        .onChange(of: isImmersive, initial: true) { _, immersive in
            router.isImmersive = immersive
        }
        .statusBarHidden(chromeHidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: current ?? item.url)
            }
        }
        .task {
            // Runs again when the gallery reappears (e.g. after full screen); keep the position.
            guard items.isEmpty else { return }
            video.isMuted = startsMuted
            items = [item]
            current = item.url
            let siblings = gallery.isEmpty
                ? ((try? FileService.contents(of: item.url.deletingLastPathComponent())) ?? [])
                    .filter { $0.kind == .image || $0.kind == .video }
                    .sorted(by: sortKey, ascending: sortAscending)
                : gallery
            if let match = siblings.first(where: { $0.name == item.name }) {
                items = siblings
                current = match.url
            }
        }
        .onChange(of: current) {
            if let currentItem, currentItem.kind == .video {
                let url = currentItem.url
                Task {
                    // Server videos stream (or download first, if streaming is
                    // off); local ones resolve to themselves right away.
                    if resolver.canStream(url) {
                        let streaming = await resolver.stream(url)
                        guard current == url else {
                            streaming?.release()
                            return
                        }
                        if let streaming {
                            video.load(url, streaming: streaming, autoplay: autoplay)
                            return
                        }
                    }
                    guard let local = try? await resolver.resolve(url), current == url else { return }
                    video.load(local, autoplay: autoplay)
                }
            } else {
                video.stop()
            }
        }
        .onChange(of: !video.isMuted && video.isPlaying) { _, isAudible in
            // A video with sound takes over from the music player; a muted or paused one doesn't.
            if isAudible {
                audioPlayer.pause()
            }
        }
        .onDisappear {
            router.isImmersive = false
            if !isShowingFullScreen {
                video.stop()
            }
        }
    }

    @ViewBuilder
    private func page(for media: FileItem) -> some View {
        let toggleChrome = {
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
        }
        if media.kind == .video {
            VideoPage(url: media.url, video: video, onTap: toggleChrome)
        } else {
            ImagePage(url: media.url, onTap: toggleChrome)
        }
    }
}

private struct VideoPage: View {
    let url: URL
    let video: GalleryVideoController
    let onTap: () -> Void

    @Environment(\.fileResolver) private var resolver
    @State private var poster: UIImage?
    @State private var resolved: URL?
    /// Streamed from a server: there's no local file for a poster frame.
    @State private var streams = false

    /// Observed from the shared player, so the page updates itself when it becomes current.
    private var isCurrent: Bool {
        video.url?.standardizedFileURL == (resolved ?? url).standardizedFileURL
    }

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
            }
            if isCurrent {
                PlayerLayerView(player: video.player)
                if !video.isPlaying {
                    Button("Play", systemImage: "play.fill") {
                        video.togglePlayPause()
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 30))
                    .foregroundStyle(.primary)
                    .frame(width: 72, height: 72)
                    .background(.regularMaterial, in: Circle())
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .overlay {
            if (resolved == nil && poster == nil && !streams) || (isCurrent && video.isBuffering) {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task(id: url) {
            // Resolving would download the whole video just for a poster frame.
            streams = resolver.canStream(url)
            guard !streams, let local = try? await resolver.resolve(url) else { return }
            resolved = local
            poster = await VideoPoster.image(for: local)
        }
    }
}

private struct ImagePage: View {
    let url: URL
    let onTap: () -> Void

    @Environment(\.fileResolver) private var resolver
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image, onTap: onTap)
            } else if failed {
                ContentUnavailableView("Can't Open Image", systemImage: "photo")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            guard let local = try? await resolver.resolve(url) else {
                failed = !Task.isCancelled
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.image(at: local, maxPixelSize: 4096)
            }.value
            image = loaded
            failed = loaded == nil
        }
    }
}

enum ImageLoader {
    /// Decodes an image scaled down to `maxPixelSize`, keeping memory use low for huge photos.
    static func image(at url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
