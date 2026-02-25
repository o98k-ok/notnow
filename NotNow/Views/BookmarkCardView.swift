import SwiftUI

struct BookmarkCardView: View {
    let bookmark: Bookmark
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmark.hasCover {
                coverCard
            } else {
                compactCard
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .glassCard(isHovered: isHovered)
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }

    // MARK: - Card With Cover

    private var coverCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover image with overlay
            ZStack(alignment: .bottomLeading) {
                if let data = bookmark.coverData, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 130)
                        .clipped()
                }

                // Gradient overlay
                AppTheme.coverOverlay
                    .frame(height: 64)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // Domain on cover
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                    Text(bookmark.domain)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial.opacity(0.6))
                .clipShape(Capsule())
                .padding(10)

                // Favorite badge
                if bookmark.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(height: 130)
            .clipped()

            // Content below cover
            VStack(alignment: .leading, spacing: 8) {
                Text(bookmark.title.isEmpty ? bookmark.domain : bookmark.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)

                if !bookmark.desc.isEmpty {
                    Text(bookmark.desc)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }

                tagsAndMeta
            }
            .padding(12)
        }
    }

    // MARK: - Compact Card (No Cover)

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with icon
            HStack(alignment: .top, spacing: 10) {
                // Site icon placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.accent.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Text(String(bookmark.domain.prefix(1)).uppercased())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(bookmark.title.isEmpty ? bookmark.domain : bookmark.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 9))
                        Text(bookmark.domain)
                            .font(.caption2)
                    }
                    .foregroundStyle(AppTheme.textTertiary)
                }

                Spacer()

                if bookmark.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }

            if !bookmark.desc.isEmpty {
                Text(bookmark.desc)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }

            tagsAndMeta
        }
        .padding(14)
    }

    // MARK: - Tags & Meta

    private var tagsAndMeta: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !bookmark.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(bookmark.tags.prefix(3)), id: \.self) { tag in
                        tagPill(tag)
                    }
                    if bookmark.tags.count > 3 {
                        Text("+\(bookmark.tags.count - 3)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 18)
            }

            // Bottom meta row
            HStack(spacing: 8) {
                if bookmark.isRead {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                        Text("已读")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(AppTheme.accentGreen)
                }
                if bookmark.openWithApp != nil || bookmark.openWithScript != nil {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.accentPink)
                }
                Spacer()
                Text(bookmark.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    private func tagPill(_ tag: String) -> some View {
        let color = TagColor.color(for: tag)
        return Text(tag)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .lineLimit(1)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.width ?? 0, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (i, pos) in result.positions.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (
        size: CGSize, positions: [CGPoint]
    ) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowH = max(rowH, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + rowH), positions)
    }
}
