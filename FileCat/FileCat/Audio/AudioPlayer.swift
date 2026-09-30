import AVFoundation
import MediaPlayer
import UIKit

/// App-wide music player. Plays a queue of audio files through an equalizer, keeps going in the
/// background and integrates with the Lock Screen / Control Center.
@MainActor
@Observable
final class AudioPlayer {
    enum RepeatMode {
        case off, all, one

        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    private(set) var queue: [FileItem] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var title = ""
    private(set) var artist: String?
    private(set) var artwork: UIImage?
    /// Set when the current file can't be decoded.
    private(set) var loadError: String?
    var repeatMode = RepeatMode.off

    let equalizer = Equalizer()

    var current: FileItem? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    // Playback graph: player node → equalizer → main mixer → output.
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    /// Set instead of `file` while a server song plays as it downloads.
    @ObservationIgnored private var streamDecoder: StreamingAudioDecoder? {
        didSet {
            if oldValue !== streamDecoder { oldValue?.cancel() }
        }
    }
    /// Decoding a stream blocks on the network, so it runs on its own queue.
    @ObservationIgnored private let decodeQueue = DispatchQueue(label: "FileCat.stream-decode", qos: .userInitiated)
    /// Stream buffers handed to the player node and not played yet.
    @ObservationIgnored private var streamBuffersInFlight = 0
    @ObservationIgnored private var streamReachedEnd = false
    /// Play was pressed before the first stream buffer was decoded.
    @ObservationIgnored private var waitingForStreamData = false
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    /// The file frame the scheduled segment starts at; the node's own clock counts from here.
    @ObservationIgnored private var segmentStartFrame: AVAudioFramePosition = 0
    /// Bumped whenever scheduled audio is thrown away, so stale completion callbacks are ignored.
    @ObservationIgnored private var scheduleGeneration = 0
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var fadeStep = 0
    /// Bumped whenever playback starts or stops, so a late session deactivation can tell it's stale.
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    /// Fetches queue items that aren't on the device yet (music on a server).
    @ObservationIgnored private var resolver: (@MainActor (FileItem) async throws -> URL)?
    /// Streams queue items that aren't on the device yet; `nil` from it means "download instead".
    @ObservationIgnored private var streamer: (@MainActor (FileItem) async throws -> RemoteStream?)?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    /// Bumped for every track change, so a late download or metadata load can tell it's stale.
    @ObservationIgnored private var loadGeneration = 0

    init() {
        engine.attach(playerNode)
        engine.attach(equalizer.unit)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.handleEngineStopped(resume: false)
                } else if type == AVAudioSession.InterruptionType.ended.rawValue,
                          AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    // Resume after a phone call or Siri if the system says we should.
                    self.handleEngineStopped(resume: true)
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Pause when headphones are unplugged, like every other audio app.
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The engine stops itself when the output hardware changes; pick up where we were.
                guard let self else { return }
                self.handleEngineStopped(resume: self.isPlaying)
            }
        })

        configureRemoteCommands()
    }

    // MARK: Controls

    /// Plays `item`, then the rest of `queue`. `resolve` downloads tracks that aren't local yet;
    /// `stream`, if given, plays them while they download.
    func play(
        _ item: FileItem,
        in queue: [FileItem],
        resolve: (@MainActor (FileItem) async throws -> URL)? = nil,
        stream: (@MainActor (FileItem) async throws -> RemoteStream?)? = nil
    ) {
        resolver = resolve
        streamer = stream
        if let position = queue.firstIndex(where: { $0.url == item.url }) {
            self.queue = queue
            index = position
        } else {
            self.queue = [item]
            index = 0
        }
        loadCurrent(autoplay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        guard isPlaying else { return }
        currentTime = playbackPosition
        playerNode.pause()
        engine.pause()
        waitingForStreamData = false
        isPlaying = false
        stopProgressTimer()
        updateNowPlaying()
    }

    func resume() {
        guard current != nil, hasSource, startEngineIfNeeded() else { return }
        startNode()
        isPlaying = true
        startProgressTimer()
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        loadCurrent(autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // Like Music: go back to the start of the song first.
        if playbackPosition > 3 {
            seek(to: 0)
            return
        }
        index = (index - 1 + queue.count) % queue.count
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        guard let sampleRate else { return }
        discardScheduledAudio()
        schedule(from: AVAudioFramePosition(max(0, seconds) * sampleRate))
        currentTime = Double(segmentStartFrame) / sampleRate
        if isPlaying {
            startNode()
        }
        updateNowPlaying()
    }

    func stop() {
        discardScheduledAudio()
        engine.stop()
        stopProgressTimer()
        metadataTask?.cancel()
        resolveTask?.cancel()
        resolver = nil
        streamer = nil
        loadGeneration += 1
        file = nil
        streamDecoder = nil
        queue = []
        index = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        loadError = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Let other apps' audio resume. Deactivating blocks, so keep it off the main thread,
        // and skip it if playback has started again in the meantime. The session is shared with
        // the gallery, so leave it alone while a video is on screen: deactivating would pause it.
        sessionGeneration += 1
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self, self.sessionGeneration == generation, !self.engine.isRunning,
                  !GalleryVideoController.hasLoadedVideo
            else { return }
            await Self.deactivateSession()
        }
    }

    // MARK: Internals

    /// Where playback is right now, in seconds.
    private var playbackPosition: Double {
        guard let sampleRate else { return 0 }
        guard isPlaying, !waitingForStreamData,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return currentTime }
        let frame = segmentStartFrame + max(0, playerTime.sampleTime)
        return min(Double(frame) / sampleRate, duration)
    }

    private var hasSource: Bool {
        file != nil || streamDecoder != nil
    }

    private var sampleRate: Double? {
        file?.processingFormat.sampleRate ?? streamDecoder?.processingFormat.sampleRate
    }

    /// Starts the player node, or, for a stream with nothing decoded yet, as soon as there is.
    private func startNode() {
        if streamDecoder != nil, streamBuffersInFlight == 0, !streamReachedEnd {
            waitingForStreamData = true
            return
        }
        waitingForStreamData = false
        fadeIn()
        playerNode.play()
    }

    private func loadCurrent(autoplay: Bool) {
        guard let item = current else {
            stop()
            return
        }
        discardScheduledAudio()
        currentTime = 0
        duration = 0
        loadError = nil
        title = item.url.deletingPathExtension().lastPathComponent
        artist = nil
        artwork = nil
        nowPlayingArtwork = nil
        loadGeneration += 1
        resolveTask?.cancel()

        if let resolver, !FileManager.default.fileExists(atPath: item.url.path(percentEncoded: false)) {
            // Stop whatever was playing while the next track downloads.
            file = nil
            streamDecoder = nil
            if isPlaying {
                playerNode.pause()
                isPlaying = false
                stopProgressTimer()
            }
            artist = "Downloading…"
            let generation = loadGeneration
            let streamer = streamer
            resolveTask = Task { [weak self] in
                do {
                    // Play while it downloads when possible; otherwise wait for the whole file.
                    if let streamer, let stream = try? await streamer(item),
                       let decoder = await self?.openDecoder(for: stream) {
                        guard let self, self.loadGeneration == generation else { return }
                        self.artist = nil
                        self.open(decoder, autoplay: autoplay)
                        return
                    }
                    let url = try await resolver(item)
                    guard let self, self.loadGeneration == generation else { return }
                    self.artist = nil
                    self.open(url, autoplay: autoplay)
                } catch {
                    guard let self, self.loadGeneration == generation, !(error is CancellationError) else { return }
                    self.artist = nil
                    self.loadError = "This song couldn't be downloaded. \(error.localizedDescription)"
                }
            }
            return
        }
        open(item.url, autoplay: autoplay)
    }

    private func open(_ url: URL, autoplay: Bool) {
        do {
            let file = try AVAudioFile(forReading: url)
            self.file = file
            streamDecoder = nil
            connect(format: file.processingFormat)
            duration = Double(file.length) / file.processingFormat.sampleRate
            schedule(from: 0)
        } catch {
            file = nil
            loadError = "This file can't be played."
            if isPlaying {
                playerNode.pause()
                isPlaying = false
                stopProgressTimer()
            }
        }

        if autoplay {
            resume()
        } else {
            updateNowPlaying()
        }
        loadMetadata(for: url)
    }

    /// Wires the graph for the file's format. Only needed when the format changes between tracks.
    private func connect(format: AVAudioFormat) {
        guard connectedFormat != format else { return }
        let wasRunning = engine.isRunning
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(equalizer.unit)
        engine.connect(playerNode, to: equalizer.unit, format: format)
        engine.connect(equalizer.unit, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        if wasRunning {
            try? engine.start()
        }
    }

    /// Runs off the main actor: deactivating the session blocks until audio I/O has stopped.
    private nonisolated static func deactivateSession() async {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        sessionGeneration += 1
        do {
            // Activate the session and allocate the engine's resources before starting. Leaving
            // it to engine.start() can make iOS reconfigure the output just after playback has
            // begun, which the engine then restarts through: an audible glitch.
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// Ramps the output up over a few milliseconds so playback doesn't start with a click.
    private func fadeIn(duration: Double = 0.1) {
        let steps = 10
        fadeTimer?.invalidate()
        fadeStep = 0
        engine.mainMixerNode.outputVolume = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.fadeStep += 1
                let progress = Float(self.fadeStep) / Float(steps)
                self.engine.mainMixerNode.outputVolume = progress * progress
                if self.fadeStep >= steps {
                    timer.invalidate()
                    self.engine.mainMixerNode.outputVolume = 1
                }
            }
        }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        if let streamDecoder {
            scheduleStream(streamDecoder, from: frame)
            return
        }
        guard let file, file.length > 0 else { return }
        // Always leave at least one frame so the completion callback fires.
        let start = min(max(0, frame), file.length - 1)
        segmentStartFrame = start
        scheduleGeneration += 1
        let generation = scheduleGeneration
        playerNode.scheduleSegment(
            file,
            startingFrame: start,
            frameCount: AVAudioFrameCount(file.length - start),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scheduleGeneration == generation else { return }
                self.itemDidFinish()
            }
        }
        // Read the first half second into memory now; otherwise the start of playback can
        // outrun the file reads and drop out while decoding catches up.
        playerNode.prepare(withFrameCount: AVAudioFrameCount(file.processingFormat.sampleRate / 2))
    }

    // MARK: Streaming

    /// Opens a server song for streaming; `nil` if Audio Toolbox can't read it that way.
    private func openDecoder(for stream: RemoteStream) async -> StreamingAudioDecoder? {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                continuation.resume(returning: try? StreamingAudioDecoder(stream: stream))
            }
        }
    }

    private func open(_ decoder: StreamingAudioDecoder, autoplay: Bool) {
        file = nil
        streamDecoder = decoder
        connect(format: decoder.processingFormat)
        duration = Double(decoder.length) / decoder.processingFormat.sampleRate
        schedule(from: 0)
        if autoplay {
            resume()
        } else {
            updateNowPlaying()
        }
        loadMetadata(for: StreamingAsset(stream: decoder.stream))
    }

    /// Streams play from buffers decoded a little ahead (about 1.5 seconds) instead of a file segment.
    private func scheduleStream(_ decoder: StreamingAudioDecoder, from frame: AVAudioFramePosition) {
        let start = max(0, decoder.length > 0 ? min(frame, decoder.length - 1) : frame)
        segmentStartFrame = start
        scheduleGeneration += 1
        let generation = scheduleGeneration
        streamBuffersInFlight = 0
        streamReachedEnd = false
        decodeQueue.async { decoder.seek(to: start) }
        for _ in 0..<4 {
            decodeNextStreamBuffer(decoder, generation: generation)
        }
    }

    private func decodeNextStreamBuffer(_ decoder: StreamingAudioDecoder, generation: Int) {
        let format = decoder.processingFormat
        decodeQueue.async { [weak self] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return }
            var failure: Error?
            do {
                try decoder.read(into: buffer)
            } catch {
                failure = error
                buffer.frameLength = 0
            }
            // Main queue, in order: buffers must reach the player node in the order they were decoded.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scheduleStreamBuffer(buffer, failure: failure, decoder: decoder, generation: generation)
                }
            }
        }
    }

    private func scheduleStreamBuffer(_ buffer: AVAudioPCMBuffer, failure: Error?, decoder: StreamingAudioDecoder, generation: Int) {
        guard generation == scheduleGeneration, streamDecoder === decoder else { return }
        if let failure, !(failure is CancellationError) {
            loadError = "The connection to the server was lost. \(failure.localizedDescription)"
        }
        guard buffer.frameLength > 0 else {
            streamReachedEnd = true
            if streamBuffersInFlight == 0 {
                waitingForStreamData = false
                itemDidFinish()
            }
            return
        }
        streamBuffersInFlight += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.scheduleGeneration == generation else { return }
                    self.streamBuffersInFlight -= 1
                    if self.streamReachedEnd {
                        if self.streamBuffersInFlight == 0 { self.itemDidFinish() }
                    } else {
                        self.decodeNextStreamBuffer(decoder, generation: generation)
                    }
                }
            }
        }
        if waitingForStreamData, isPlaying {
            waitingForStreamData = false
            fadeIn()
            playerNode.play()
        }
    }

    private func discardScheduledAudio() {
        scheduleGeneration += 1
        playerNode.stop()
    }

    /// Re-schedules from the last known position after the engine was stopped by the system.
    private func handleEngineStopped(resume shouldResume: Bool) {
        guard hasSource else { return }
        let position = playbackPosition
        isPlaying = false
        stopProgressTimer()
        seek(to: position)
        if shouldResume {
            resume()
        }
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.playbackPosition
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func itemDidFinish() {
        switch repeatMode {
        case .one:
            seek(to: 0)
        case .all:
            next()
        case .off:
            if index + 1 < queue.count {
                index += 1
                loadCurrent(autoplay: true)
            } else {
                pause()
                seek(to: 0)
            }
        }
    }

    private func loadMetadata(for url: URL) {
        loadMetadata(asset: AVURLAsset(url: url), keepAlive: nil)
    }

    private func loadMetadata(for streaming: StreamingAsset) {
        loadMetadata(asset: streaming.asset, keepAlive: streaming)
    }

    /// `keepAlive` holds a streaming asset's loader until the metadata has been read.
    private func loadMetadata(asset: AVURLAsset, keepAlive: StreamingAsset?) {
        metadataTask?.cancel()
        let generation = loadGeneration
        metadataTask = Task { [weak self] in
            defer { withExtendedLifetime(keepAlive) {} }
            guard let metadata = try? await asset.load(.commonMetadata) else { return }

            var title: String?
            var artist: String?
            var artwork: UIImage?
            for item in metadata {
                switch item.commonKey {
                case .commonKeyTitle?:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist?:
                    artist = try? await item.load(.stringValue)
                case .commonKeyArtwork?:
                    if let data = try? await item.load(.dataValue) {
                        artwork = UIImage(data: data)
                    }
                default:
                    break
                }
            }

            guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
            if let title, !title.isEmpty { self.title = title }
            self.artist = artist
            self.artwork = artwork
            self.nowPlayingArtwork = artwork.map(Self.makeArtwork)
            self.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard current != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The artwork handler is called on a background queue, so it must not be main-actor isolated.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
    }
}
