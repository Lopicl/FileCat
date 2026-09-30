import FileCatKit
import Foundation
import Observation

/// The user's tag list (names and colors), plus helpers that apply tags to files.
@MainActor
@Observable
final class TagStore {
    enum Coverage {
        case all, some, none
    }

    private(set) var tags: [FileTag] = []
    /// Incremented whenever tags on files change, so views showing files can reload.
    private(set) var revision = 0

    private let defaultsKey = "fileTags"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([FileTag].self, from: data) {
            tags = saved
        } else {
            tags = FileTag.defaults
        }
        writeManifest()
    }

    func tag(named name: String) -> FileTag? {
        tags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func color(for name: String) -> TagColor {
        tag(named: name)?.color ?? .none
    }

    /// Lowercased tag name → color, for writing tags off the main thread.
    var colorMap: [String: TagColor] {
        Dictionary(tags.map { ($0.name.lowercased(), $0.color) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Managing tags

    @discardableResult
    func create(named name: String, color: TagColor, icon: TagIcon? = nil, customColor: CustomTagColor? = nil) throws -> FileTag {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("\n") else { throw FileError.invalidName }
        if let existing = tag(named: clean) { return existing }
        let tag = FileTag(name: clean, color: color, icon: icon, customColor: customColor)
        tags.append(tag)
        save()
        return tag
    }

    /// Renames, recolors or changes the icon of a tag, rewriting every file that carries it under `roots`.
    @discardableResult
    func update(_ tag: FileTag, name newName: String, color: TagColor, icon: TagIcon?, customColor: CustomTagColor? = nil, in roots: [URL]) async throws -> FileTag {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("\n") else { throw FileError.invalidName }
        if let other = self.tag(named: clean), other.name != tag.name {
            throw FileError.nameTaken(other.name)
        }
        let updated = FileTag(name: clean, color: color, icon: icon, customColor: customColor)
        guard let position = tags.firstIndex(of: tag) else { return updated }
        tags[position] = updated
        save()
        // Only the name and (Finder) color are stored on files.
        guard clean != tag.name || updated.color != tag.color else { return updated }

        let oldName = tag.name
        let colors = colorMap
        await Task.detached(priority: .userInitiated) {
            for url in FileService.urls(taggedWith: oldName, in: roots) {
                let names = FileTags.read(url).map { $0.caseInsensitiveCompare(oldName) == .orderedSame ? clean : $0 }
                try? FileTags.write(names, colors: colors, to: url)
            }
        }.value
        revision += 1
        return updated
    }

    /// Deletes a tag and removes it from every file under `roots`.
    func delete(_ tag: FileTag, in roots: [URL]) async {
        tags.removeAll { $0 == tag }
        save()

        let colors = colorMap
        await Task.detached(priority: .userInitiated) {
            for url in FileService.urls(taggedWith: tag.name, in: roots) {
                let names = FileTags.read(url).filter { $0.caseInsensitiveCompare(tag.name) != .orderedSame }
                try? FileTags.write(names, colors: colors, to: url)
            }
        }.value
        revision += 1
    }

    // MARK: Tagging files

    func coverage(of tag: FileTag, on urls: [URL]) -> Coverage {
        let count = urls.filter { FileTags.contains(FileTags.read($0), tag.name) }.count
        return count == 0 ? .none : count == urls.count ? .all : .some
    }

    /// Adds `tag` to every file, or removes it if they all have it already.
    func toggle(_ tag: FileTag, on urls: [URL]) throws {
        if coverage(of: tag, on: urls) == .all {
            try remove(tag, from: urls)
        } else {
            try add(tag, to: urls)
        }
    }

    func add(_ tag: FileTag, to urls: [URL]) throws {
        defer { revision += 1 }
        for url in urls {
            let names = FileTags.read(url)
            guard !FileTags.contains(names, tag.name) else { continue }
            try FileTags.write(names + [tag.name], colors: colorMap, to: url)
        }
    }

    func remove(_ tag: FileTag, from urls: [URL]) throws {
        defer { revision += 1 }
        for url in urls {
            let names = FileTags.read(url)
            guard FileTags.contains(names, tag.name) else { continue }
            try FileTags.write(names.filter { $0.caseInsensitiveCompare(tag.name) != .orderedSame }, colors: colorMap, to: url)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        writeManifest()
    }

    /// Keeps `.FileCat/library.json` in Local Storage up to date, so companion apps can find the
    /// library and show tags with their colors and icons (see FileCatKit).
    private func writeManifest() {
        let tags = tags
        SharedManifest.update { $0.tags = tags }
    }
}
