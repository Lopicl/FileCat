import FileCatKit
import SwiftUI

/// The Tags tab: every tag, with ways to create, edit and delete them.
struct TagsView: View {
    @Environment(LocationStore.self) private var store
    @Environment(TagStore.self) private var tagStore

    /// `tag == nil` means "create a new tag".
    private struct TagEdit: Identifiable {
        let id = UUID()
        let tag: FileTag?
    }

    @State private var tagEdit: TagEdit?
    @State private var pendingDeletion: FileTag?
    @State private var query = ""
    @State private var isSearchPresented = false

    private var visibleTags: [FileTag] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? tagStore.tags : tagStore.tags.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            ForEach(visibleTags) { tag in
                NavigationLink(value: Route.tag(TagDestination(name: tag.name))) {
                    Label {
                        Text(tag.name)
                    } icon: {
                        TagBadge(tag, size: 18)
                    }
                }
                .contextMenu {
                    Button("Edit Tag…", systemImage: "pencil") {
                        tagEdit = TagEdit(tag: tag)
                    }
                    Button("Delete Tag", systemImage: "trash", role: .destructive) {
                        pendingDeletion = tag
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash") {
                        pendingDeletion = tag
                    }
                    .tint(.red)
                    Button("Edit", systemImage: "pencil") {
                        tagEdit = TagEdit(tag: tag)
                    }
                }
            }
        }
        .locationTitle("Tags", screenID: nil)
        .overlay {
            if tagStore.tags.isEmpty {
                ContentUnavailableView {
                    Label("No Tags", systemImage: "tag")
                } description: {
                    Text("Create a tag, then long-press files and choose Tags to add it.")
                } actions: {
                    Button("New Tag") { tagEdit = TagEdit(tag: nil) }
                        .buttonStyle(.bordered)
                }
            } else if visibleTags.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchPill(text: $query, isPresented: $isSearchPresented, prompt: "Search Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SearchToolbarButton(isPresented: $isSearchPresented)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Tag", systemImage: "plus") {
                    tagEdit = TagEdit(tag: nil)
                }
            }
        }
        .sheet(item: $tagEdit) { edit in
            TagDetailsSheet(tag: edit.tag)
        }
        .alert(
            "Delete Tag “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(isPresenting: $pendingDeletion),
            presenting: pendingDeletion
        ) { tag in
            Button("Delete", role: .destructive) {
                Task { await tagStore.delete(tag, in: store.all.map(\.url)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The tag will be removed from all items. The items themselves won't be deleted.")
        }
    }
}
