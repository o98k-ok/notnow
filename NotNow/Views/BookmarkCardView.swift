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
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.name = "NotNow.CoverImageCache"
        c.countLimit = 120
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    static func image(for id: UUID, data: Data?) -> NSImage? {
        guard let data else { return nil }
        let key = cacheKey(id: id, data: data)
        return cache.object(forKey: key)
    }

    static func set(_ image: NSImage?, for id: UUID, data: Data) {
        guard let image else { return }
        let key = cacheKey(id: id, data: data)
        if cache.object(forKey: key) != nil { return }
        cache.setObject(image, forKey: key, cost: imageMemoryCost(image: image))
    }

    private static func cacheKey(id: UUID, data: Data) -> NSString {
        "\(id.uuidString)-\(signature(for: data))" as NSString
    }

    private static func imageMemoryCost(image: NSImage) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        return max(1, cg.bytesPerRow * cg.height)
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
    @State private var coverLoadTask: Task<Void, Never>?

    var body: some View {
        decoratedCard {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    if bookmark.isAPI {
                        apiCard
                    } else if bookmark.isTask {
                        taskCard
                    } else if bookmark.isSnippet {
                        snippetCard
                    } else if bookmark.hasCover {
                        coverCard
                    } else {
                        compactCard
                    }
                }
                if isBentoStyle {
                    bentoTopDots
                        .padding(.top, 9)
                        .padding(.trailing, 9)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshRelativeCreatedAtText()
            guard bookmark.hasCover, displayCover == nil else { return }
            scheduleCoverLoad()
        }
        .onChange(of: bookmark.coverData) {
            scheduleCoverLoad()
        }
        .onDisappear {
            coverLoadTask?.cancel()
            coverLoadTask = nil
            displayCover = nil
        }
    }

    private var isBentoStyle: Bool { AppTheme.isBento }
    private var isBentoLightStyle: Bool { AccentTheme.current == .bentoLight }
    private var bentoPatternStyle: Int {
        if bookmark.isAPI { return 2 }
        if bookmark.isTask { return 0 }
        if bookmark.isSnippet { return 1 }
        return abs(bookmark.id.hashValue) % 2 == 0 ? 2 : 3
    }

    private func scheduleCoverLoad() {
        coverLoadTask?.cancel()
        coverLoadTask = Task { await loadCoverIfNeeded() }
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
        guard !Task.isCancelled else { return }
        // Decode downsampled thumbnail instead of full-size image to cap memory usage.
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard !Task.isCancelled else { return }
            if let cgImage {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                CoverImageCache.set(image, for: bookmark.id, data: data)
                displayCover = image
            } else {
                displayCover = nil
            }
        }
    }

    @ViewBuilder
    private func decoratedCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isBentoStyle {
            let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            content()
                .background(
                    cardShape
                        .fill(AppTheme.bgCard)
                        .overlay(
                            cardShape
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            AppTheme.accent.opacity(0.16),
                                            AppTheme.secondary.opacity(0.08),
                                            Color.clear
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                )
                .clipShape(cardShape)
                .overlay(
                    cardShape
                        .stroke(AppTheme.borderSubtle, lineWidth: isBentoLightStyle ? 1.15 : 1)
                )
                .overlay(
                    cardShape
                        .stroke(
                            AppTheme.borderHover.opacity(isBentoLightStyle ? 0.24 : 0.38),
                            lineWidth: isBentoLightStyle ? 0.65 : 0.8
                        )
                        .padding(1.2)
                )
        } else {
            content()
                .glassCard(isHovered: false)
        }
    }

    private var bentoTopDots: some View {
        HStack(spacing: 3) {
            Circle().fill(AppTheme.textTertiary).frame(width: 3.5, height: 3.5)
            Circle().fill(AppTheme.textTertiary).frame(width: 3.5, height: 3.5)
            Circle().fill(AppTheme.textTertiary).frame(width: 3.5, height: 3.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.bgPrimary.opacity(0.35))
        .clipShape(Capsule())
    }

    private func bentoPatternStrip(style: Int) -> some View {
        let ink = isBentoLightStyle ? Color.black.opacity(0.34) : Color.black.opacity(0.46)
        return HStack(spacing: 8) {
            switch style {
            case 0:
                Capsule().fill(ink).frame(width: 24, height: 4)
                Circle().fill(ink).frame(width: 5, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 14, height: 4)
                Capsule().fill(ink.opacity(0.9)).frame(width: 10, height: 3)
                RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 14, height: 4)
                Circle().fill(ink).frame(width: 5, height: 5)
                Capsule().fill(ink).frame(width: 24, height: 4)
            case 1:
                let widths: [CGFloat] = [20, 14, 8]
                ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ink)
                        .frame(width: width, height: 4)
                }
                Circle().fill(ink.opacity(0.9)).frame(width: 6, height: 6)
                ForEach(Array(widths.reversed().enumerated()), id: \.offset) { _, width in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ink)
                        .frame(width: width, height: 4)
                }
            case 2:
                let heights: [CGFloat] = [6, 10, 14]
                Capsule().fill(ink).frame(width: 18, height: 3)
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(ink.opacity(0.8))
                        .frame(width: 3, height: height)
                }
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.95)).frame(width: 16, height: 4)
                ForEach(Array(heights.reversed().enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(ink.opacity(0.8))
                        .frame(width: 3, height: height)
                }
                Capsule().fill(ink).frame(width: 18, height: 3)
            default:
                RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 20, height: 3)
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(ink).frame(width: 6, height: 6)
                }
                Capsule().fill(ink.opacity(0.9)).frame(width: 12, height: 3)
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(ink).frame(width: 6, height: 6)
                }
                RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 20, height: 3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(AppTheme.accentGradient)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - API Card

    private var apiCard: some View {
        let method = bookmark.resolvedAPIMethod
        let urlText = bookmark.url
        let bodyPreview: String = {
            guard let body = bookmark.apiBody?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { return "" }
            return String(body.prefix(200))
        }()

        return VStack(alignment: .leading, spacing: 0) {
            // Method + URL header
            HStack(spacing: 8) {
                Text(method.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(method.color)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text(urlText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Body preview
            if !bodyPreview.isEmpty {
                Text(bodyPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 14)
            }

            // Title + info
            VStack(alignment: .leading, spacing: 8) {
                if !bookmark.title.isEmpty {
                    Text(bookmark.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    tagPill("api")
                    if let bodyType = bookmark.apiBodyType, !bodyType.isEmpty {
                        tagPill(bodyType)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 18)

                tagsAndMeta
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
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
                if isBentoStyle {
                    bentoPatternStrip(style: 0)
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
                        .fill(
                            isBentoStyle
                                ? AnyShapeStyle(AppTheme.accentGradient)
                                : AnyShapeStyle(AppTheme.accent.opacity(0.15))
                        )
                        .frame(width: 36, height: 36)
                    Text(String(bookmark.domain.prefix(1)).uppercased())
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isBentoStyle ? Color.black.opacity(0.8) : AppTheme.accent)
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
            if isBentoStyle {
                bentoPatternStrip(style: bentoPatternStyle)
            }
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
