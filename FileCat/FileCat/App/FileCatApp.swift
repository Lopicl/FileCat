import AVFoundation
import SwiftUI

@main
struct FileCatApp: App {
    @State private var locations: LocationStore
    @State private var player: AudioPlayer
    @State private var tags: TagStore
    @State private var sources: SourceStore
    @State private var transfers: TransferCenter

    init() {
        // Lets music keep playing in the background and with the silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #if DEBUG
        // Must run before the stores below read their saved state.
        UITestSupport.prepareIfNeeded()
        #endif
        _locations = State(initialValue: LocationStore())
        _player = State(initialValue: AudioPlayer())
        _tags = State(initialValue: TagStore())
        let sources = SourceStore()
        _sources = State(initialValue: sources)
        _transfers = State(initialValue: TransferCenter(sources: sources))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locations)
                .environment(player)
                .environment(tags)
                .environment(sources)
                .environment(transfers)
        }
    }
}
