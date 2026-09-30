import SwiftUI

/// Routes a file or folder to the right viewer.
struct FileDestination: View {
    let item: FileItem

    var body: some View {
        switch item.kind {
        case .folder:
            FolderView(url: item.url, title: item.name)
        case .image, .video:
            MediaViewer(item: item)
        case .pdf:
            PDFViewer(item: item)
        case .markdown:
            MarkdownViewer(item: item)
        case .text:
            TextViewer(item: item)
        case .archive:
            ArchiveView(archive: item.url, title: item.name)
        case .audio, .other:
            // Audio normally opens in the music player; Quick Look covers everything else
            // (Office documents, Keynote, RTF, 3D models, …).
            QuickLookViewer(item: item)
        }
    }
}
