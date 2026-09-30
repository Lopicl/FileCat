import Foundation

/// Block-level Markdown structure. Inline formatting (bold, links, code spans…) is left as
/// Markdown source and rendered later with `AttributedString(markdown:)`.
indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case rule
}

struct MarkdownList: Hashable, Sendable {
    var ordered: Bool
    var start: Int
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Hashable, Sendable {
    /// `nil` for normal items, `true`/`false` for task-list checkboxes.
    var checked: Bool?
    var blocks: [MarkdownBlock]
}

struct MarkdownTable: Hashable, Sendable {
    enum Alignment: Hashable, Sendable {
        case leading, center, trailing
    }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

/// A small, forgiving parser covering the CommonMark/GFM features people actually use:
/// headings, paragraphs, emphasis, lists (nested, ordered, tasks), quotes, code, tables and rules.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return parseBlocks(lines)
    }

    private static func parseBlocks(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.leadingSpaces

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block
            if indent < 4, let fence = fenceMarker(trimmed) {
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    i += 1
                    if isClosingFence(codeLine.trimmingCharacters(in: .whitespaces), for: fence) { break }
                    code.append(String(codeLine.dropFirst(min(indent, codeLine.leadingSpaces))))
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }

            // Indented code block
            if indent >= 4 {
                var code: [String] = []
                while i < lines.count, lines[i].leadingSpaces >= 4 || lines[i].isBlank {
                    code.append(String(lines[i].dropFirst(min(4, lines[i].leadingSpaces))))
                    i += 1
                }
                while code.last?.isBlank == true { code.removeLast() }
                blocks.append(.code(language: nil, text: code.joined(separator: "\n")))
                continue
            }

            if let heading = atxHeading(trimmed) {
                blocks.append(heading)
                i += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let quoted = lines[i].trimmingCharacters(in: .whitespaces)
                    guard quoted.hasPrefix(">") else { break }
                    var rest = quoted.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    i += 1
                }
                blocks.append(.quote(parseBlocks(inner)))
                continue
            }

            if trimmed.contains("|"), i + 1 < lines.count, let alignments = tableAlignments(lines[i + 1]) {
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(tableCells(row))
                    i += 1
                }
                blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                continue
            }

            if let marker = listMarker(line) {
                let (list, next) = parseList(lines, from: i, first: marker)
                blocks.append(.list(list))
                i = next
                continue
            }

            // Paragraph, possibly turned into a heading by a setext underline (=== or ---).
            var paragraph: [String] = []
            var setextLevel: Int?
            while i < lines.count {
                let paragraphLine = lines[i]
                let content = paragraphLine.trimmingCharacters(in: .whitespaces)
                if content.isEmpty { break }
                if !paragraph.isEmpty {
                    if let level = setextHeadingLevel(content) {
                        setextLevel = level
                        i += 1
                        break
                    }
                    if startsBlock(paragraphLine) { break }
                }
                paragraph.append(paragraphLine)
                i += 1
            }
            let text = joinParagraph(paragraph)
            if let setextLevel {
                blocks.append(.heading(level: setextLevel, text: text))
            } else {
                blocks.append(.paragraph(text))
            }
        }
        return blocks
    }

    // MARK: Lists

    struct ListMarker {
        var indent: Int
        var ordered: Bool
        var number: Int
        /// Column where the item's content starts.
        var contentOffset: Int
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = line.leadingSpaces
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }

        let markerLength: Int
        var ordered = false
        var number = 1
        if first == "-" || first == "*" || first == "+" {
            markerLength = 1
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9 else { return nil }
            let delimiter = rest.dropFirst(digits.count).first
            guard delimiter == "." || delimiter == ")" else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            markerLength = digits.count + 1
        } else {
            return nil
        }

        let afterMarker = rest.dropFirst(markerLength)
        if afterMarker.allSatisfy({ $0 == " " }) {
            return ListMarker(indent: indent, ordered: ordered, number: number, contentOffset: indent + markerLength + 1)
        }
        guard afterMarker.first == " " else { return nil }
        let spaces = afterMarker.prefix { $0 == " " }.count
        let padding = spaces > 4 ? 1 : spaces
        return ListMarker(indent: indent, ordered: ordered, number: number, contentOffset: indent + markerLength + padding)
    }

    private static func parseList(_ lines: [String], from start: Int, first: ListMarker) -> (MarkdownList, Int) {
        var items: [MarkdownListItem] = []
        var i = start

        while true {
            // Blank lines between items don't end the list.
            var j = i
            while j < lines.count, lines[j].isBlank { j += 1 }
            guard j < lines.count,
                  let marker = listMarker(lines[j]),
                  marker.ordered == first.ordered,
                  marker.indent < first.contentOffset,
                  !isRule(lines[j].trimmingCharacters(in: .whitespaces))
            else { break }
            i = j

            var content = [String(lines[i].dropFirst(marker.contentOffset))]
            i += 1

            while i < lines.count {
                let line = lines[i]
                if line.isBlank {
                    // Keep going only if the next non-blank line is indented into this item.
                    var next = i + 1
                    while next < lines.count, lines[next].isBlank { next += 1 }
                    if next < lines.count, lines[next].leadingSpaces >= marker.contentOffset {
                        content.append(contentsOf: Array(repeating: "", count: next - i))
                        i = next
                        continue
                    }
                    break
                }

                let indent = line.leadingSpaces
                if indent >= marker.contentOffset {
                    content.append(String(line.dropFirst(marker.contentOffset)))
                } else if listMarker(line) != nil {
                    // A marker indented past ours is a nested list; otherwise it's a sibling.
                    guard indent > marker.indent else { break }
                    content.append(String(line.dropFirst(indent)))
                } else if startsBlock(line) {
                    break
                } else {
                    // Lazy continuation of the item's paragraph.
                    content.append(line.trimmingCharacters(in: .whitespaces))
                }
                i += 1
            }

            var blocks = parseBlocks(content)
            var checked: Bool?
            if case .paragraph(let text)? = blocks.first, let task = taskPrefix(text) {
                checked = task.checked
                blocks[0] = .paragraph(task.rest)
            }
            items.append(MarkdownListItem(checked: checked, blocks: blocks))
        }

        return (MarkdownList(ordered: first.ordered, start: first.number, items: items), i)
    }

    private static func taskPrefix(_ text: String) -> (checked: Bool, rest: String)? {
        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            guard rest.isEmpty || rest.first == " " else { return nil }
            return (checked, rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Line classification

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return fenceMarker(trimmed) != nil
            || atxHeading(trimmed) != nil
            || isRule(trimmed)
            || trimmed.hasPrefix(">")
            || listMarker(line).map { !$0.ordered || $0.number == 1 } == true
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for character in ["`", "~"] {
            let run = trimmed.prefix { String($0) == character }
            if run.count >= 3 {
                // Backtick fences can't contain backticks in their info string.
                if character == "`", trimmed.dropFirst(run.count).contains("`") { return nil }
                return String(run)
            }
        }
        return nil
    }

    private static func isClosingFence(_ trimmed: String, for fence: String) -> Bool {
        guard let character = fence.first, trimmed.hasPrefix(fence) else { return false }
        return trimmed.allSatisfy { $0 == character }
    }

    private static func atxHeading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }

        var text = rest.trimmingCharacters(in: .whitespaces)
        // Drop an optional closing sequence: "## Title ##"
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0, closing == text.count || text.dropLast(closing).last == " " {
            text = String(text.dropLast(closing)).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: hashes, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func setextHeadingLevel(_ trimmed: String) -> Int? {
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // MARK: Tables

    private static func tableAlignments(_ line: String) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in tableCells(trimmed) {
            guard cell.count >= 1, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    private static func tableCells(_ trimmed: String) -> [String] {
        var row = Substring(trimmed)
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row = row.dropLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Paragraphs

    /// Joins soft-wrapped lines with spaces, honouring hard breaks (two trailing spaces or "\").
    private static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            var content = line.trimmingCharacters(in: .whitespaces)
            let isLast = index == lines.count - 1
            if isLast {
                result += content
            } else if line.hasSuffix("  ") {
                result += content + "\n"
            } else if content.hasSuffix("\\") {
                content.removeLast()
                result += content + "\n"
            } else {
                result += content + " "
            }
        }
        return result
    }
}

private extension String {
    var leadingSpaces: Int {
        prefix { $0 == " " }.count
    }

    var isBlank: Bool {
        allSatisfy(\.isWhitespace)
    }
}
