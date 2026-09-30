import SwiftUI

/// Opens the text editor for a file. `afterSave` runs once the file has been written, e.g. to
/// upload a server file's local copy back to the server.
struct TextEditRequest: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var afterSave: FileSaveHandler?
}

/// Runs after an edited file was saved on the device.
struct FileSaveHandler: Sendable {
    let handle: @MainActor @Sendable (URL) async throws -> Void

    init(_ handle: @escaping @MainActor @Sendable (URL) async throws -> Void) {
        self.handle = handle
    }
}

extension EnvironmentValues {
    /// Set by screens showing a copy of a server file, so edits made in a viewer go back to the server.
    @Entry var fileSaveHandler: FileSaveHandler?
}

extension View {
    func textEditor(_ request: Binding<TextEditRequest?>, onSave: @escaping () -> Void = {}) -> some View {
        sheet(item: request) { request in
            TextEditorView(request: request, onSave: onSave)
        }
    }
}

/// Edits any file as text: source code, configuration, logs, or even a binary file (whose bytes are
/// kept as they are, one character per byte). The file keeps its text encoding and its tags.
struct TextEditorView: View {
    let request: TextEditRequest
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage("textFontSize") private var fontSize = 16.0
    @AppStorage("textMonospaced") private var monospaced = false

    @State private var document: TextLoader.EditableText?
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @State private var findRequest = 0

    private var hasChanges: Bool {
        document.map { $0.text != text } ?? false
    }

    var body: some View {
        NavigationStack {
            Group {
                if document != nil {
                    EditableTextView(text: $text, fontSize: fontSize, monospaced: monospaced, findRequest: findRequest)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("textEditor")
                } else if let errorMessage {
                    ContentUnavailableView("Can't Edit File", systemImage: "doc.questionmark", description: Text(errorMessage))
                } else {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if document?.isBinary == true {
                    Text("This file doesn't look like text. Changing it may damage it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
            }
            .navigationTitle(request.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog("Discard your changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Find", systemImage: "magnifyingglass") { findRequest += 1 }
                    TextOptionsMenu(fontSize: $fontSize, monospaced: $monospaced)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!hasChanges)
                            .accessibilityIdentifier("saveText")
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .alert("Couldn't Save", isPresented: Binding(isPresenting: $saveError), presenting: saveError) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
        .task {
            let url = request.url
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try TextLoader.loadForEditing(url) }.value
                document = loaded
                text = loaded.text
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let document, !isSaving else { return }
        isSaving = true
        let url = request.url
        let text = text
        Task {
            defer { isSaving = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TextLoader.save(text, encoding: document.encoding, to: url)
                }.value
                try await request.afterSave?.handle(url)
                onSave()
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

/// An editable UITextView: handles big files, and has the system find and replace bar.
struct EditableTextView: UIViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let monospaced: Bool
    var findRequest = 0

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var findRequest = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text)
        coordinator.findRequest = findRequest
        return coordinator
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = true
        view.isFindInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.text = text
        view.font = font
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text {
            view.text = text
        }
        if view.font != font {
            view.font = font
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.findInteraction?.presentFindNavigator(showingReplace: true)
        }
    }

    private var font: UIFont {
        monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
    }
}
