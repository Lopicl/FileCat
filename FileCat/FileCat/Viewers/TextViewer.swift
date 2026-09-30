import SwiftUI

/// Read-only viewer for plain text and source files.
struct TextViewer: View {
    let item: FileItem

    @AppStorage("textFontSize") private var fontSize = 16.0
    @AppStorage("textMonospaced") private var monospaced = false

    @State private var text: String?
    @State private var truncated = false
    @State private var errorMessage: String?
    @State private var findRequest = 0
    @State private var textEdit: TextEditRequest?
    /// Bumped after an edit, to load the file again.
    @State private var revision = 0
    @Environment(\.fileSaveHandler) private var fileSaveHandler

    var body: some View {
        Group {
            if let text {
                TextContentView(text: text, fontSize: fontSize, monospaced: monospaced, findRequest: findRequest)
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorMessage {
                ContentUnavailableView("Can't Open File", systemImage: "doc.questionmark", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if truncated {
                Text("Showing the first \(TextLoader.maxBytes / 1_048_576) MB of this file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // First, so it stays out of the overflow menu when space is short.
                Button("Edit", systemImage: "square.and.pencil") {
                    textEdit = TextEditRequest(url: item.url, name: item.name, afterSave: fileSaveHandler)
                }
                .accessibilityIdentifier("editText")
                Button("Find", systemImage: "magnifyingglass") { findRequest += 1 }
                TextOptionsMenu(fontSize: $fontSize, monospaced: $monospaced)
                ShareLink(item: item.url)
            }
        }
        .textEditor($textEdit) { revision += 1 }
        .task(id: revision) {
            do {
                let url = item.url
                let result = try await Task.detached(priority: .userInitiated) { try TextLoader.load(url) }.value
                text = result.text
                truncated = result.truncated
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct TextOptionsMenu: View {
    @Binding var fontSize: Double
    @Binding var monospaced: Bool

    var body: some View {
        Menu {
            ControlGroup {
                Button("Smaller", systemImage: "textformat.size.smaller") {
                    fontSize = max(10, fontSize - 2)
                }
                Button("Larger", systemImage: "textformat.size.larger") {
                    fontSize = min(40, fontSize + 2)
                }
            }
            Toggle("Monospaced", systemImage: "chevron.left.forwardslash.chevron.right", isOn: $monospaced)
        } label: {
            Label("Text Options", systemImage: "textformat.size")
        }
    }
}

/// UITextView handles very large files far better than SwiftUI's Text, and gives us
/// selection and the system find bar for free.
struct TextContentView: UIViewRepresentable {
    let text: String
    let fontSize: Double
    let monospaced: Bool
    var findRequest = 0

    final class Coordinator {
        var findRequest = 0
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.findRequest = findRequest
        return coordinator
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.text = text
        view.font = font
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // The file can change underneath, e.g. after editing it.
        if view.text != text {
            view.text = text
        }
        if view.font != font {
            view.font = font
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    private var font: UIFont {
        monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
    }
}
