import FileCatKit
import SwiftUI
import UniformTypeIdentifiers

struct FileInfoView: View {
    let item: FileItem

    @Environment(\.dismiss) private var dismiss
    @Environment(TagStore.self) private var tagStore
    @AppStorage(AppSettings.tagsEnabled) private var tagsEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        ThumbnailView(item: item, side: 120)
                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Information") {
                    LabeledContent("Kind", value: kindDescription)
                    if let size = item.formattedSize {
                        LabeledContent("Size", value: size)
                    }
                    if let count = item.formattedItemCount {
                        LabeledContent("Contains", value: count)
                    }
                    if let created = item.created {
                        LabeledContent("Created", value: created.formatted(date: .long, time: .shortened))
                    }
                    if let modified = item.modified {
                        LabeledContent("Modified", value: modified.formatted(date: .long, time: .shortened))
                    }
                    LabeledContent("Where", value: item.parentName)
                }

                if tagsEnabled, !item.tags.isEmpty {
                    Section("Tags") {
                        ForEach(item.tags, id: \.self) { name in
                            Label {
                                Text(name)
                            } icon: {
                                TagBadge(tagStore.tag(named: name) ?? FileTag(name: name, color: .none), size: 16)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var kindDescription: String {
        if item.isDirectory { return "Folder" }
        return UTType(filenameExtension: item.url.pathExtension)?.localizedDescription ?? "Document"
    }
}
