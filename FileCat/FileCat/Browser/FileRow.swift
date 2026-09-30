import SwiftUI

struct FileRow: View {
    let item: FileItem
    var showsLocation = false

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item, side: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Tags sit in front of the date and size.
                HStack(spacing: 6) {
                    TagDots(names: item.tags)
                    Text(showsLocation ? "in \(item.parentName)" : item.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct FileGridCell: View {
    let item: FileItem
    var isSelecting = false
    var isSelected = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(item: item, side: 80)
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.white : Color.secondary, isSelected ? Color.accentColor : Color.clear)
                            .background(Circle().fill(.background))
                            .offset(x: 4, y: 4)
                    }
                }

            VStack(spacing: 2) {
                Text(item.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                if let modified = item.modified {
                    HStack(spacing: 4) {
                        TagDots(names: item.tags, size: 8)
                        Text(modified.formatted(date: .numeric, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TagDots(names: item.tags, size: 8)
                }
                if let detail = item.isDirectory ? item.formattedItemCount : item.formattedSize {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }
}
