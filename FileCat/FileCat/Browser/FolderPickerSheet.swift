import SwiftUI

/// Lets the user browse to a destination folder for Move / Copy.
struct FolderPickerSheet: View {
    let transfer: Transfer
    let onPick: (URL) -> Void

    @Environment(LocationStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Locations") {
                    ForEach(store.all) { location in
                        NavigationLink(value: Destination(url: location.url, title: location.name)) {
                            Label(location.name, systemImage: location.systemImage)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { destination in
                FolderPickerList(url: destination.url, title: destination.title, transfer: transfer) { url in
                    onPick(url)
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        let count = transfer.urls.count
        let noun = count == 1 ? "“\(transfer.urls[0].lastPathComponent)”" : "\(count) Items"
        return "\(transfer.mode.actionTitle) \(noun)"
    }
}

private struct FolderPickerList: View {
    let url: URL
    let title: String
    let transfer: Transfer
    let onPick: (URL) -> Void

    @State private var folders: [FileItem] = []

    var body: some View {
        List(folders) { folder in
            NavigationLink(value: Destination(url: folder.url, title: folder.name)) {
                Label {
                    Text(folder.name)
                } icon: {
                    FileIcon(kind: .folder, side: 24)
                }
            }
            // A folder can't be moved into itself.
            .disabled(transfer.urls.contains { FileService.isSameLocation($0, folder.url) })
        }
        .accessibilityIdentifier("folderPicker")
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(transfer.mode.actionTitle) { onPick(url) }
            }
        }
        .task {
            folders = ((try? FileService.contents(of: url)) ?? [])
                .filter(\.isDirectory)
                .sorted(by: .name, ascending: true)
        }
    }
}

private struct Destination: Hashable {
    let url: URL
    let title: String
}
