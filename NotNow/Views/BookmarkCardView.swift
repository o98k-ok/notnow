import SwiftUI

/// 限制封面解码并发数，避免同时解码过多导致卡顿
private actor CoverDecodeLimiter {
    static let shared = CoverDecodeLimiter()
    private var active = 0
    private let maxConcurrent = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    func release() {
        active -= 1
        if let cont = waiters.first {
            waiters.removeFirst()
            cont.resume()
        }
    }
}

/// In-memory cache for decoded cover images to avoid repeated main-thread decode during scroll.
private enum CoverImageCache {
    private static let maxEntries = 80
    private struct CacheKey: Hashable {
        let id: UUID
        let signature: UInt64
    }
    private static var cache: [CacheKey: NSImage] = [:]
    private static var order: [CacheKey] = []
    private static let lock = NSLock()

    static func image(for id: UUID, data: Data?) -> NSImage? {
        guard let data else { return nil }
        let key = CacheKey(id: id, signature: signature(for: data))
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        return nil
    }

    static func set(_ image: NSImage?, for id: UUID, data: Data) {
        guard let image else { return }
        let key = CacheKey(id: id, signature: signature(for: data))
        lock.lock()
        if cache[key] != nil { lock.unlock(); return }
        while order.count >= maxEntries, let first = order.first {
            order.removeFirst()
            cache[first] = nil
        }
        cache[key] = image
        order.append(key)
        lock.unlock()
    }

    private static func signature(for data: Data) -> UInt64 {
        var hash: UInt64 = UInt64(data.count)
        let prefixCount = min(32, data.count)
        for byte in data.prefix(prefixCount) {
            hash = (hash &* 16777619) ^ UInt64(byte)
        }
        if data.count > 32 {
            for byte in data.suffix(16) {
                hash = (hash &* 16777619) ^ UInt64(byte)
            }
        }
        return hash
    }
}

struct BookmarkCardView: View {
    let bookmark: Bookmark
    /// Decoded cover image; loaded async to avoid blocking main thread during scroll.
    @State private var displayCover: NSImage?
    @State private var relativeCreatedAtText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmark.isTask {
                taskCard
            } else if bookmark.isSnippet {
                snippetCard
            } else if bookmark.hasCover {
                coverCard
            } else {
                compactCard
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .glassCard(isHovered: false)
        .onAppear {
            refreshRelativeCreatedAtText()
            guard bookmark.hasCover, displayCover == nil else { return }
            Task { await loadCoverIfNeeded() }
        }
        .onChange(of: bookmark.coverData) {
            Task { await loadCoverIfNeeded() }
        }
    }

    private func loadCoverIfNeeded() async {
        guard let data = bookmark.coverData else {
            await MainActor.run { displayCover = nil }
            return
        }
        if let cached = CoverImageCache.image(for: bookmark.id, data: data) {
            await MainActor.run { displayCover = cached }
            return
        }
        await CoverDecodeLimiter.shared.acquire()
        defer { Task { await CoverDecodeLimiter.shared.release() } }
        // 在后台线程解码，但返回 CGImage 避免 Sendable 问题
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }.value
        await MainActor.run {
            if let cgImage {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                CoverImageCache.set(image, for: bookmark.id, data: data)
                displayCover = image
            } else {
                displayCover = nil
            }
        }
    }

    // MARK: - Task Card

    private var taskCard: some View {
        let completed = bookmark.taskCompleted
        let priority = bookmark.resolvedTaskPriority

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                // Checkbox — click to toggle completion
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        bookmark.taskCompleted.toggle()
                        bookmark.updatedAt = Date()
                        try? bookmark.modelContext?.save()
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(completed ? AppTheme.accentGreen : AppTheme.textTertiary.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(completed ? AppTheme.accentGreen.opacity(0.15) : Color.clear)
                            )
                        if completed {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.accentGreen)
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(bookmark.title.isEmpty ? "未命名任务" : bookmark.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(completed ? AppTheme.textTertiary : AppTheme.textPrimary)
                        .strikethrough(completed, color: AppTheme.textTertiary)
                        .lineLimit(2)

                    // Task badges (type / status)，参考 snippet 卡片的打标风格
                    HStack(spacing: 4) {
                        tagPill("task")
                        if completed {
                            tagPill("done")
                        } else if bookmark.isOverdue {
                            tagPill("overdue")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 18)
                }

                Spacer()

                // Priority indicator
                if priority != .none {
                    Image(systemName: priority.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(priority.color)
                        .padding(4)
                        .background(priority.color.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(14)

            if !bookmark.desc.isEmpty {
                Divider()
                    .background(AppTheme.borderSubtle)
                    .padding(.horizontal, 14)

                Text(bookmark.desc)
                    .font(.caption)
                    .foregroundStyle(completed ? AppTheme.textTertiary.opacity(0.6) : AppTheme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Due date + tags row
                HStack(spacing: 6) {
                    if let due = bookmark.dueDate {
                        let overdue = bookmark.isOverdue
                        HStack(spacing: 3) {
                            Image(systemName: overdue ? "exclamationmark.circle.fill" : "calendar")
                                .font(.system(size: 9))
                            Text(due.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(completed ? AppTheme.textTertiary : (overdue ? Color.red : AppTheme.textSecondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((overdue && !completed ? Color.red : AppTheme.textTertiary).opacity(0.1))
                        .clipShape(Capsule())
                    }

                    if !bookmark.tags.isEmpty {
                        ForEach(Array(bookmark.tags.prefix(2)), id: \.self) { tag in
                            tagPill(tag)
                        }
                        if bookmark.tags.count > 2 {
                            Text("+\(bookmark.tags.count - 2)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    // Show link icon if task has a real URL
                    if !bookmark.url.hasPrefix("task://") {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.accent.opacity(0.6))
                    }
                    Spacer()
                    Text(relativeCreatedAtText)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            .padding(14)
        }
        .opacity(completed ? 0.7 : 1)
    }

    // MARK: - Card With Cover

    private var snippetCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Markdown content area (cover position)
            Group {
                if let md = try? AttributedString(markdown: snippetPreviewText, options: .init(interpretedSyntax: .full)) {
                    Text(md)
                } else {
                    Text(snippetPreviewText)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(8)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .padding(12)
            .background(AppTheme.bgInput)

            // Content below
            VStack(alignment: .leading, spacing: 8) {
                Text(bookmark.title.isEmpty ? "Snippet" : bookmark.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    tagPill("snippet")
                    Spacer(minLength: 0)
                }
                .frame(height: 18)

                tagsAndMeta
            }
            .padding(12)
        }
    }

    private var coverCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover image with overlay (use pre-decoded displayCover, never decode in body)
            ZStack(alignment: .bottomLeading) {
                if let img = displayCover {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 130)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(AppTheme.bgInput)
                        .frame(height: 130)
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
                if bookmark.openWithScript != nil {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.accentPink)
                }
                Spacer()
                Text(relativeCreatedAtText)
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

    private func refreshRelativeCreatedAtText() {
        relativeCreatedAtText = bookmark.createdAt.formatted(.relative(presentation: .named))
    }

    private var snippetPreviewText: String {
        let text = bookmark.snippetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return bookmark.desc }
        return text
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
