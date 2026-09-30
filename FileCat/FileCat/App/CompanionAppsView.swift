import FileCatKit
import SwiftUI

/// Explains how other apps (a music or video player, say) can use the files in Local Storage.
struct CompanionAppsView: View {
    @State private var manifest: LibraryManifest?
    @State private var notice: String?
    @Environment(\.openURL) private var openURL

    private var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Local Storage is ready to share")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } footer: {
                Text("Apps built with FileCatKit, like a dedicated music or video player, can open the same files instead of keeping their own copies. Tags, folders and changes stay in sync because everything is ordinary files.")
            }

            Section {
                HStack(spacing: 14) {
                    Image("MusiCatIcon")
                        .resizable()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MusiCat")
                            .font(.headline)
                        Text("A music player for your FileCat library: playlists, songs with several artists, hi-res WAV, FLAC and ALAC, and USB DACs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button("Open MusiCat", systemImage: "arrow.up.forward.app") {
                    openURL(URL(string: "musicat://")!) { opened in
                        if !opened { notice = "MusiCat isn't installed. It's still in development." }
                    }
                }
                .accessibilityIdentifier("openMusiCat")
            } header: {
                Text("Apps")
            }

            Section("Connect an App") {
                Label("In the other app, choose to connect a FileCat library.", systemImage: "1.circle")
                Label("In the folder picker, go to \(deviceName) and select FileCat.", systemImage: "2.circle")
                Label("Tap Open. The app keeps access from then on.", systemImage: "3.circle")
            }

            Section {
                if let manifest {
                    LabeledContent("Library ID") {
                        Text(manifest.libraryID.uuidString.prefix(8) + "…")
                            .monospaced()
                    }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = manifest.libraryID.uuidString
                        }
                    }
                    LabeledContent("Tags Shared", value: "\(manifest.tags.count)")
                    LabeledContent("Servers Listed", value: "\(manifest.servers?.count ?? 0)")
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Apps can send you back here with filecat:// links, for example “Show in FileCat” from a music player. MusiCat can also import your servers: it asks here first, then follows your changes to them.")
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        }
        .navigationTitle("Companion Apps")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            manifest = LibraryManifest.read(from: FileService.documentsDirectory)
        }
    }
}
