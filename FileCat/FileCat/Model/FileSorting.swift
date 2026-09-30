import Foundation

enum SortKey: String, CaseIterable, Identifiable {
    case name, date, size, kind

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// Names read best A→Z; dates and sizes read best newest/largest first.
    var defaultAscending: Bool {
        self == .name || self == .kind
    }
}

enum ViewStyle: String {
    case list, grid
}

extension Array where Element == FileItem {
    /// Folders always come first, like the Files app.
    func sorted(by key: SortKey, ascending: Bool) -> [FileItem] {
        sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            let result: ComparisonResult = switch key {
            case .name: a.name.localizedStandardCompare(b.name)
            case .date: compareValues(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .size: compareValues(a.size ?? Int64(a.childCount ?? 0), b.size ?? Int64(b.childCount ?? 0))
            case .kind: a.url.pathExtension.localizedStandardCompare(b.url.pathExtension)
            }

            if result == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}

private func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
}
