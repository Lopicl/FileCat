import SwiftUI

struct MarkdownViewer: View {
    let item: FileItem

    @AppStorage("textFontSize") private var fontSize = 16.0
    @AppStorage("textMonospaced") private var monospaced = false

    @State private var source: String?
    @State private var blocks: [MarkdownBlock] = []
    @State private var showsSource = false
    @State private var errorMessage: String?
    @State private var findRequest = 0
    @State private var textEdit: TextEditRequest?
    /// Bumped after an edit, to load the file again.
    @State private var revision = 0
    @Environment(\.fileSaveHandler) private var fileSaveHandler

    var body: some View {
        Group {
            if let source {
                if showsSource {
                    TextContentView(text: source, fontSize: fontSize, monospaced: monospaced, findRequest: findRequest)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ScrollView {
                        MarkdownBlocksView(blocks: blocks)
                            .textSelection(.enabled)
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Can't Open File", systemImage: "doc.questionmark", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Edit", systemImage: "square.and.pencil") {
                    textEdit = TextEditRequest(url: item.url, name: item.name, afterSave: fileSaveHandler)
                }
                .accessibilityIdentifier("editText")
                if showsSource {
                    Button("Find", systemImage: "magnifyingglass") { findRequest += 1 }
                    TextOptionsMenu(fontSize: $fontSize, monospaced: $monospaced)
                }
                Toggle(isOn: $showsSource.animation()) {
                    Label("Show Source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                ShareLink(item: item.url)
            }
        }
        .textEditor($textEdit) { revision += 1 }
        .task(id: revision) {
            do {
                let url = item.url
                let (text, parsed) = try await Task.detached(priority: .userInitiated) {
                    let text = try TextLoader.load(url).text
                    return (text, MarkdownParser.parse(text))
                }.value
                blocks = parsed
                source = text
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Rendering

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .lineSpacing(3)

        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .quote(let inner):
            MarkdownBlocksView(blocks: inner, spacing: 8)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color(uiColor: .tertiaryLabel))
                        .frame(width: 3)
                }

        case .list(let list):
            MarkdownListView(list: list)

        case .table(let table):
            MarkdownTableView(table: table)

        case .rule:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.weight(.semibold)
        case 4: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item, at: index)
                    MarkdownBlocksView(blocks: item.blocks, spacing: 6)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, at index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
        } else if list.ordered {
            Text("\(list.start + index).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
        } else {
            Text("•")
                .foregroundStyle(.secondary)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    private var columnCount: Int {
        max(table.header.count, table.rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(table.header, column)
                            .fontWeight(.semibold)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            cell(row, column)
                        }
                    }
                }
            }
            .padding(12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(uiColor: .separator))
        )
    }

    private func cell(_ row: [String], _ column: Int) -> Text {
        Text(inlineMarkdown(column < row.count ? row[column] : ""))
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// Renders inline Markdown (emphasis, code spans, links, strikethrough) into an AttributedString.
private func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
