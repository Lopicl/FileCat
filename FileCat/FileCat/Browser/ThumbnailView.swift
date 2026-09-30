import FileCatKit
import QuickLookThumbnailing
import SwiftUI

extension FileKind {
    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "music.note"
        case .pdf: "doc.richtext.fill"
        case .markdown: "doc.text.fill"
        case .text: "doc.plaintext.fill"
        case .archive: "doc.zipper"
        case .other: "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .folder: .accentColor
        case .image: .orange
        case .video: .purple
        case .audio: .pink
        case .pdf: .red
        case .markdown: .indigo
        case .archive: .brown
        case .text, .other: .gray
        }
    }
}

/// Generic SF Symbol icon for a file kind.
struct FileIcon: View {
    let kind: FileKind
    let side: CGFloat

    var body: some View {
        Image(systemName: kind.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: side * (kind == .folder ? 0.72 : 0.62)))
            .foregroundStyle(kind.tint)
            .frame(width: side, height: side)
    }
}

/// Shows a Quick Look thumbnail when one is available, otherwise the file-kind icon.
struct ThumbnailView: View {
    let item: FileItem
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                let shape = RoundedRectangle(cornerRadius: max(3, side * 0.06), style: .continuous)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
            } else {
                FileIcon(kind: item.kind, side: side)
            }
        }
        .frame(width: side, height: side)
        .task(id: item) {
            guard !item.isDirectory else {
                image = nil
                return
            }
            image = await ThumbnailCache.shared.image(for: item, side: side, scale: displayScale)
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private var failures = Set<String>()

    private init() {
        cache.countLimit = 500
    }

    func removeAll() {
        cache.removeAllObjects()
        failures.removeAll()
    }

    func image(for item: FileItem, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let key = "\(item.url.path(percentEncoded: false))|\(item.modified?.timeIntervalSince1970 ?? 0)|\(Int(side * scale))"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if failures.contains(key) { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failures.insert(key)
            return nil
        }
        let image = representation.uiImage
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
