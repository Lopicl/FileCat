import FileCatKit
import SwiftUI

extension TagColor {
    var color: Color {
        switch self {
        case .none: Color(uiColor: .systemGray3)
        case .gray: .gray
        case .green: .green
        case .purple: .purple
        case .blue: .blue
        case .yellow: .yellow
        case .red: .red
        case .orange: .orange
        }
    }
}

extension CustomTagColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: min(1, max(0, red)), green: min(1, max(0, green)), blue: min(1, max(0, blue)))
    }
}

extension FileTag {
    /// The color the app draws the tag in: the user's own color, or the Finder color.
    var displayColor: Color {
        customColor?.color ?? color.color
    }

    /// "No Color" tags are drawn as rings.
    var isUncolored: Bool {
        customColor == nil && color == .none
    }
}

/// A single tag color circle. "No Color" tags are drawn as a ring, like in Files.
struct TagDot: View {
    let fill: Color
    var isUncolored = false
    var size: CGFloat = 10

    init(color: TagColor, size: CGFloat = 10) {
        fill = color.color
        isUncolored = color == .none
        self.size = size
    }

    init(fill: Color, isUncolored: Bool = false, size: CGFloat = 10) {
        self.fill = fill
        self.isUncolored = isUncolored
        self.size = size
    }

    var body: some View {
        Group {
            if isUncolored {
                Circle().strokeBorder(fill, lineWidth: max(1, size / 7))
            } else {
                Circle().fill(fill)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A tag's icon (a symbol in the tag's color), or its color dot if it has no icon.
struct TagBadge: View {
    let color: Color
    let isUncolored: Bool
    let icon: TagIcon?
    var size: CGFloat = 10

    init(color: Color, isUncolored: Bool = false, icon: TagIcon?, size: CGFloat = 10) {
        self.color = color
        self.isUncolored = isUncolored
        self.icon = icon
        self.size = size
    }

    init(_ tag: FileTag, size: CGFloat = 10) {
        self.init(color: tag.displayColor, isUncolored: tag.isUncolored, icon: tag.icon, size: size)
    }

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundStyle(isUncolored ? Color.secondary : color)
                .frame(width: size, height: size)
        case nil:
            TagDot(fill: color, isUncolored: isUncolored, size: size)
        }
    }
}

/// A file's tags, shown next to its name: overlapping dots, with icons where tags have them.
struct TagDots: View {
    let names: [String]
    var size: CGFloat = 10

    @Environment(TagStore.self) private var store
    @AppStorage(AppSettings.showsFileTags) private var showsFileTags = true
    @AppStorage(AppSettings.tagsEnabled) private var tagsEnabled = true

    var body: some View {
        if tagsEnabled, showsFileTags, !names.isEmpty {
            let tags = names.prefix(4).map { store.tag(named: $0) ?? FileTag(name: $0, color: .none) }
            // Plain dots overlap like in Files; icons need a little room to stay legible.
            let hasIcons = tags.contains { $0.icon != nil }
            HStack(spacing: hasIcons ? 2 : -size * 0.35) {
                ForEach(tags) { tag in
                    if tag.icon == nil {
                        TagBadge(tag, size: size)
                            .background(Circle().fill(Color(uiColor: .systemBackground)).padding(-1.5))
                    } else {
                        TagBadge(tag, size: size * 1.2)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Tags: \(names.joined(separator: ", "))")
        }
    }
}

/// Identifies the files a tag editor sheet is working on.
struct TagRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Tagging files

/// Toggle tags on one or more files, or create a new tag and apply it.
struct TagEditorSheet: View {
    let urls: [URL]

    @Environment(TagStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newColor = TagColor.blue
    @State private var newCustomColor: CustomTagColor?
    @State private var newIcon: TagIcon?
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("New Tag") {
                    HStack {
                        TextField("Tag Name", text: $newName)
                            .focused($isNameFocused)
                            .onSubmit(addNewTag)
                            .submitLabel(.done)
                        Button("Add", action: addNewTag)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    TagColorPicker(selection: $newColor, custom: $newCustomColor)
                    TagIconPicker(selection: $newIcon, color: newCustomColor?.color ?? newColor.color, layout: .row)
                }

                Section {
                    // Coverage is read from the files, which SwiftUI can't observe. Computing it here
                    // (keyed on `revision`) and passing it down as a value makes every row refresh.
                    let coverage = tagCoverage(revision: store.revision)
                    ForEach(store.tags) { tag in
                        let state = coverage[tag.name] ?? TagStore.Coverage.none
                        Button {
                            perform { try store.toggle(tag, on: urls) }
                        } label: {
                            HStack(spacing: 12) {
                                TagBadge(tag, size: 16)
                                    .frame(width: 20)
                                Text(tag.name)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                coverageMark(state)
                            }
                        }
                        .accessibilityAddTraits(state == .all ? .isSelected : [])
                        .accessibilityIdentifier("tagRow-\(tag.name)")
                    }
                }
            }
            .navigationTitle(urls.count == 1 ? "Tags" : "Tag \(urls.count) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Something Went Wrong", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func tagCoverage(revision: Int) -> [String: TagStore.Coverage] {
        Dictionary(uniqueKeysWithValues: store.tags.map { ($0.name, store.coverage(of: $0, on: urls)) })
    }

    @ViewBuilder
    private func coverageMark(_ coverage: TagStore.Coverage) -> some View {
        switch coverage {
        case .all:
            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
        case .some:
            Image(systemName: "minus").fontWeight(.semibold).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    private func addNewTag() {
        perform {
            let tag = try store.create(named: newName, color: newColor, icon: newIcon, customColor: newCustomColor)
            try store.add(tag, to: urls)
            newName = ""
            newIcon = nil
            // Put the keyboard away so the new tag's row, now checked, can be seen.
            isNameFocused = false
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The Finder colors, plus a color wheel for picking any other color.
struct TagColorPicker: View {
    @Binding var selection: TagColor
    /// Set when the user picked a color of their own; `selection` then holds the nearest Finder color.
    @Binding var custom: CustomTagColor?

    var body: some View {
        HStack {
            ForEach(TagColor.pickerOrder) { color in
                Button {
                    selection = color
                    custom = nil
                } label: {
                    TagDot(color: color, size: 26)
                        .padding(3)
                        .overlay {
                            if custom == nil, selection == color {
                                Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                            }
                        }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(custom == nil && selection == color ? .isSelected : [])
            }
            ColorPicker("Custom Color", selection: customBinding, supportsOpacity: false)
                .labelsHidden()
                .padding(3)
                .overlay {
                    if custom != nil {
                        Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                            .padding(-1)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("customTagColor")
        }
        .padding(.vertical, 4)
    }

    private var customBinding: Binding<Color> {
        Binding {
            custom?.color ?? selection.color
        } set: { color in
            let picked = CustomTagColor(color)
            custom = picked
            selection = picked.nearestTagColor
        }
    }
}

// MARK: - Creating and editing tags

/// Creates a new tag, or renames / recolors an existing one.
struct TagDetailsSheet: View {
    /// `nil` to create a new tag.
    let tag: FileTag?
    let onSave: (FileTag) -> Void

    @Environment(TagStore.self) private var store
    @Environment(LocationStore.self) private var locations
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var color: TagColor
    @State private var customColor: CustomTagColor?
    @State private var icon: TagIcon?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(tag: FileTag?, onSave: @escaping (FileTag) -> Void = { _ in }) {
        self.tag = tag
        self.onSave = onSave
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: tag?.color ?? .blue)
        _customColor = State(initialValue: tag?.customColor)
        _icon = State(initialValue: tag?.icon)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tag Name", text: $name)
                        .onSubmit(save)
                }
                Section("Color") {
                    TagColorPicker(selection: $color, custom: $customColor)
                }
                Section("Icon") {
                    TagIconPicker(selection: $icon, color: customColor?.color ?? color.color, isUncolored: customColor == nil && color == .none)
                }
            }
            .navigationTitle(tag == nil ? "New Tag" : "Edit Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(tag == nil ? "Create" : "Save", action: save)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .alert("Something Went Wrong", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                if let tag {
                    onSave(try await store.update(tag, name: name, color: color, icon: icon, customColor: customColor, in: locations.all.map(\.url)))
                } else {
                    onSave(try store.create(named: name, color: color, icon: icon, customColor: customColor))
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Choose an SF Symbol from a curated set, or no icon: as a grid, or a single scrolling row
/// where space is tight.
struct TagIconPicker: View {
    enum Layout {
        case grid, row
    }

    @Binding var selection: TagIcon?
    let color: Color
    var isUncolored = false
    var layout = Layout.grid

    var body: some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                cells
            }
            .padding(.vertical, 4)
        case .row:
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    cells
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        cell(for: nil, label: "No Icon") {
            Image(systemName: "circle.slash")
                .foregroundStyle(.secondary)
        }
        ForEach(TagIcon.symbols, id: \.self) { name in
            cell(for: .symbol(name), label: name) {
                TagBadge(color: color, isUncolored: isUncolored, icon: .symbol(name), size: 20)
            }
        }
    }

    private func cell(for icon: TagIcon?, label: String, @ViewBuilder content: () -> some View) -> some View {
        let isSelected = selection == icon
        return Button {
            selection = icon
        } label: {
            content()
                .frame(width: 40, height: 40)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("tagIcon-\(label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Browsing by tag

/// Every file and folder with a given tag, across all locations.
struct TaggedFilesView: View {
    let tagName: String

    @Environment(TagStore.self) private var store
    @Environment(LocationStore.self) private var locations
    @Environment(Router.self) private var router
    @Environment(AudioPlayer.self) private var player

    @State private var items: [FileItem] = []
    @State private var isLoaded = false
    @State private var tagRequest: TagRequest?
    @State private var errorMessage: String?

    var body: some View {
        List(items) { item in
            row(for: item)
                .contextMenu {
                    Button("Tags…", systemImage: "tag") { tagRequest = TagRequest(urls: [item.url]) }
                    if let tag = store.tag(named: tagName) {
                        Button("Remove “\(tag.name)” Tag", systemImage: "tag.slash") {
                            do {
                                try store.remove(tag, from: [item.url])
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    ShareLink(item: item.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
        }
        .listStyle(.plain)
        .locationTitle(tagName, screenID: Route.tag(TagDestination(name: tagName)).screenID)
        .overlay {
            if !isLoaded {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("No Tagged Items", systemImage: "tag")
                } description: {
                    Text("Long-press a file or folder and choose Tags to add it here.")
                }
            }
        }
        .task(id: store.revision) {
            let tagName = tagName
            let roots = locations.all.map(\.url)
            items = await Task.detached(priority: .userInitiated) {
                FileService.items(taggedWith: tagName, in: roots)
                    .sorted(by: .name, ascending: true)
            }.value
            isLoaded = true
        }
        .sheet(item: $tagRequest) { request in
            TagEditorSheet(urls: request.urls)
        }
        .alert("Something Went Wrong", isPresented: Binding(isPresenting: $errorMessage), presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        let row = FileRow(item: item, showsLocation: true)
        if item.isDirectory {
            NavigationLink(value: Route.file(item)) { row }
        } else {
            Button {
                if item.kind == .audio {
                    player.play(item, in: items.filter { $0.kind == .audio })
                    router.showsNowPlaying = true
                } else {
                    router.push(.file(item))
                }
            } label: {
                row
            }
            .tint(Color.primary)
        }
    }
}
