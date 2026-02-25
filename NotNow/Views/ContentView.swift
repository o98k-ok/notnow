import AppKit
import SwiftData
import SwiftUI

enum SidebarSelection: Hashable {
    case all
    case category(UUID)
    case uncategorized
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @AppStorage("accentTheme") private var accentThemeName = "purple"
    @State private var selection: SidebarSelection = .all
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var selectedBookmark: Bookmark?
    @State private var columnCount = 3
    @State private var showCategorySheet = false
    @State private var editingCategory: Category?
    @State private var isImporting = false
    @State private var importAlertMessage = ""
    @State private var showImportAlert = false
    @State private var showImportSheet = false
    @State private var selectedImportSource: ImportSource = .chrome
    @State private var githubStarsInput = ""
    @State private var isBatchMode = false
    @State private var selectedBookmarkIDs: Set<UUID> = []
    @State private var hoverPreviewBookmark: Bookmark?
    @State private var hoverPreviewTask: DispatchWorkItem?
    @State private var hoverPreviewLocation: CGPoint?
    @State private var showSettings = false
    @FocusState private var isSearchFocused: Bool

    private var filteredBookmarks: [Bookmark] {
        bookmarks.filter { bm in
            switch selection {
            case .all: break
            case .category(let id):
                guard bm.category?.id == id else { return false }
            case .uncategorized:
                guard bm.category == nil else { return false }
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let match =
                    bm.title.lowercased().contains(q)
                    || bm.url.lowercased().contains(q)
                    || bm.desc.lowercased().contains(q)
                    || bm.notes.lowercased().contains(q)
                    || bm.tags.contains { $0.lowercased().contains(q) }
                    || bm.domain.lowercased().contains(q)
                if !match { return false }
            }
            return true
        }
    }

    private var currentTheme: AccentTheme {
        AccentTheme(rawValue: accentThemeName) ?? .purple
    }

    var body: some View {
        ZStack {
            AppTheme.backgroundGradient
                .ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar
                Divider().background(AppTheme.borderSubtle)
                mainContent
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddBookmarkSheet()
                .preferredColorScheme(.dark)
        }
        .sheet(item: $selectedBookmark) { bm in
            BookmarkDetailSheet(bookmark: bm)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showCategorySheet) {
            CategorySheet(editingCategory: editingCategory)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showImportSheet) {
            ImportBookmarksSheet(
                selectedSource: $selectedImportSource,
                githubStarsInput: $githubStarsInput,
                isImporting: isImporting,
                onCancel: { showImportSheet = false },
                onImport: { source in
                    importBookmarks(from: source)
                }
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(.dark)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addBookmark)) { _ in
            showAddSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            isSearchFocused = true
        }
        .onAppear {
            NSLog("[NotNow] app appeared, bookmarks: %d", bookmarks.count)
        }
        .onChange(of: showCategorySheet) {
            if !showCategorySheet { editingCategory = nil }
        }
        .alert("导入结果", isPresented: $showImportAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(importAlertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            showSettings = true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(currentTheme.gradient)
                Text("NotNow")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)

            // All
            sidebarItem(
                label: "全部", icon: "square.grid.2x2",
                isActive: selection == .all,
                count: bookmarks.count,
                accentColor: currentTheme.color
            ) { selection = .all }

            // Categories header
            HStack {
                Text("分类")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                if case .category(let selectedID) = selection,
                    let selected = categories.first(where: { $0.id == selectedID })
                {
                    Button {
                        editingCategory = selected
                        showCategorySheet = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.textTertiary)
                            .frame(width: 20, height: 20)
                            .background(AppTheme.bgElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    editingCategory = nil
                    showCategorySheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(AppTheme.bgElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Category list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(categories) { cat in
                        let catCount = bookmarks.filter { $0.category?.id == cat.id }.count
                        sidebarItem(
                            label: cat.name, icon: cat.icon,
                            isActive: selection == .category(cat.id),
                            count: catCount,
                            accentColor: cat.color
                        ) { selection = .category(cat.id) }
                            .contextMenu {
                                Button("编辑") {
                                    editingCategory = cat
                                    showCategorySheet = true
                                }
                                Button("删除", role: .destructive) {
                                    if selection == .category(cat.id) { selection = .all }
                                    modelContext.delete(cat)
                                }
                            }
                    }

                    // Uncategorized
                    let uncatCount = bookmarks.filter { $0.category == nil }.count
                    if uncatCount > 0 {
                        sidebarItem(
                            label: "未分类", icon: "tray",
                            isActive: selection == .uncategorized,
                            count: uncatCount,
                            accentColor: AppTheme.textTertiary
                        ) { selection = .uncategorized }
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()

            // Spacer bottom
        }
        .frame(width: 200)
        .background(AppTheme.bgSecondary)
    }

    private func sidebarItem(
        label: String, icon: String, isActive: Bool,
        count: Int? = nil, accentColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(isActive ? accentColor : AppTheme.textTertiary)
                    .frame(width: 20)
                Text(label)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AppTheme.textPrimary : AppTheme.textSecondary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.bgElevated)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? accentColor.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            topBar
            bookmarkGrid
        }
        .background(AppTheme.bgPrimary)
        .overlay {
            GeometryReader { geo in
                ZStack {
                    MouseTrackingView(location: $hoverPreviewLocation, active: hoverPreviewBookmark != nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    if let bm = hoverPreviewBookmark, let loc = hoverPreviewLocation {
                        let w: CGFloat = 260
                        let h: CGFloat = 140
                        let pad: CGFloat = 16
                        let cx = min(max(loc.x + 24, w / 2 + pad), geo.size.width - w / 2 - pad)
                        let cy = min(max(loc.y - 24, h / 2 + pad), geo.size.height - h / 2 - pad)
                        HoverPreviewCard(bookmark: bm)
                            .frame(width: w, height: h, alignment: .topLeading)
                            .position(x: cx, y: cy)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Text(topBarTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textTertiary)
                TextField("搜索书签...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AppTheme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            )
            .frame(maxWidth: 280)

            // Columns
            HStack(spacing: 4) {
                ForEach([2, 3, 4], id: \.self) { n in
                    Button { columnCount = n } label: {
                        Image(systemName: gridIcon(for: n))
                            .font(.caption)
                            .foregroundStyle(
                                columnCount == n ? currentTheme.color : AppTheme.textTertiary
                            )
                            .frame(width: 28, height: 28)
                            .background(
                                columnCount == n ? currentTheme.color.opacity(0.12) : .clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isBatchMode {
                HStack(spacing: 8) {
                    Button {
                        toggleSelectAll()
                    } label: {
                        Text(selectedBookmarkIDs.count == filteredBookmarks.count ? "清空" : "全选")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .ghostButtonStyle()
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("移到未分类") { moveSelected(to: nil) }
                        if !categories.isEmpty {
                            Divider()
                            ForEach(categories) { cat in
                                Button(cat.name) { moveSelected(to: cat) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("移动(\(selectedBookmarkIDs.count))")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .ghostButtonStyle()
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedBookmarkIDs.isEmpty)

                    Button {
                        deleteSelected()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("删除(\(selectedBookmarkIDs.count))")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .ghostButtonStyle()
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedBookmarkIDs.isEmpty)
                }
            }

            Button { showAddSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("添加")
                }
                .accentButtonStyle()
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n")

            Button {
                showImportSheet = true
            } label: {
                HStack(spacing: 6) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text("导入")
                }
                .ghostButtonStyle()
            }
            .buttonStyle(.plain)
            .disabled(isImporting)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isBatchMode.toggle()
                    if !isBatchMode {
                        selectedBookmarkIDs.removeAll()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isBatchMode ? "checkmark.circle.fill" : "checklist")
                    Text(isBatchMode ? "完成批量" : "批量")
                }
                .ghostButtonStyle()
            }
            .buttonStyle(.plain)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.bgElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var topBarTitle: String {
        switch selection {
        case .all: "全部书签"
        case .category(let id): categories.first { $0.id == id }?.name ?? "分类"
        case .uncategorized: "未分类"
        }
    }

    // MARK: - Grid

    private var bookmarkGrid: some View {
        GeometryReader { proxy in
            ScrollView {
                if filteredBookmarks.isEmpty {
                    emptyState
                } else {
                    let contentWidth = max(proxy.size.width - 44, 1)
                    MasonryLayout(columns: columnCount, spacing: 14) {
                        ForEach(filteredBookmarks) { bm in
                            bookmarkCell(for: bm)
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(currentTheme.color.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "bookmark.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(currentTheme.color)
            }
            Text(searchText.isEmpty ? "还没有书签" : "没有找到匹配的书签")
                .font(.title3.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
            Text(searchText.isEmpty ? "点击添加按钮或按 ⌘N 开始收藏" : "尝试不同的关键词")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textTertiary)
            if searchText.isEmpty {
                Button { showAddSheet = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("添加书签")
                    }
                    .accentButtonStyle()
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for bm: Bookmark) -> some View {
        Button("打开") { OpenService.open(bm) }
        Button("在浏览器中打开") {
            if let url = URL(string: bm.url) { NSWorkspace.shared.open(url) }
        }
        Divider()
        // Move to category
        if !categories.isEmpty {
            Menu("移动到分类") {
                Button("无分类") { bm.category = nil; bm.updatedAt = Date() }
                Divider()
                ForEach(categories) { cat in
                    Button(cat.name) { bm.category = cat; bm.updatedAt = Date() }
                }
            }
        }
        Button(bm.isFavorite ? "取消收藏" : "收藏") {
            bm.isFavorite.toggle(); bm.updatedAt = Date()
        }
        Button(bm.isRead ? "标为未读" : "标为已读") {
            bm.isRead.toggle(); bm.updatedAt = Date()
        }
        Divider()
        Button("复制链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bm.url, forType: .string)
        }
        Button("编辑") { selectedBookmark = bm }
        Divider()
        Button("删除", role: .destructive) { modelContext.delete(bm) }
    }

    private func bookmarkCell(for bookmark: Bookmark) -> some View {
        BookmarkCardView(bookmark: bookmark)
            .onHover { inside in
                handleHover(for: bookmark, isInside: inside)
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if isBatchMode {
                    batchCheckmark(for: bookmark.id)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if !isBatchMode { OpenService.open(bookmark) }
            }
            .simultaneousGesture(
                TapGesture()
                    .modifiers(.command)
                    .onEnded { OpenService.open(bookmark) }
            )
            .onTapGesture {
                if isBatchMode {
                    toggleSelection(for: bookmark.id)
                } else {
                    selectedBookmark = bookmark
                }
            }
            .contextMenu { contextMenu(for: bookmark) }
    }

    private func gridIcon(for n: Int) -> String {
        switch n {
        case 2: "square.grid.2x2"
        case 3: "square.grid.3x3"
        default: "square.grid.4x3.fill"
        }
    }

    @ViewBuilder
    private func batchCheckmark(for id: UUID) -> some View {
        let selected = selectedBookmarkIDs.contains(id)
        ZStack {
            Circle()
                .fill(selected ? currentTheme.color : AppTheme.bgElevated)
            Image(systemName: selected ? "checkmark" : "")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().stroke(AppTheme.borderHover, lineWidth: 1))
        .padding(8)
    }

    private func handleHover(for bookmark: Bookmark, isInside: Bool) {
        if isInside {
            scheduleHoverPreview(for: bookmark)
        } else {
            scheduleHoverPreview(for: nil)
        }
    }

    private func scheduleHoverPreview(for bookmark: Bookmark?) {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil

        guard let bookmark else {
            withAnimation(.easeOut(duration: 0.15)) {
                hoverPreviewBookmark = nil
                hoverPreviewLocation = nil
            }
            return
        }

        let task = DispatchWorkItem {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.15)) {
                    hoverPreviewBookmark = bookmark
                }
            }
        }
        hoverPreviewTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }

    private func toggleSelection(for id: UUID) {
        if selectedBookmarkIDs.contains(id) {
            selectedBookmarkIDs.remove(id)
        } else {
            selectedBookmarkIDs.insert(id)
        }
    }

    private func toggleSelectAll() {
        let visibleIDs = Set(filteredBookmarks.map(\.id))
        if selectedBookmarkIDs.count == visibleIDs.count {
            selectedBookmarkIDs.removeAll()
        } else {
            selectedBookmarkIDs = visibleIDs
        }
    }

    private func moveSelected(to category: Category?) {
        guard !selectedBookmarkIDs.isEmpty else { return }
        let selected = bookmarks.filter { selectedBookmarkIDs.contains($0.id) }
        for bm in selected {
            bm.category = category
            bm.updatedAt = Date()
        }
        try? modelContext.save()
        selectedBookmarkIDs.removeAll()
        isBatchMode = false
    }

    private func deleteSelected() {
        guard !selectedBookmarkIDs.isEmpty else { return }
        let selected = bookmarks.filter { selectedBookmarkIDs.contains($0.id) }
        for bm in selected {
            modelContext.delete(bm)
        }
        try? modelContext.save()
        selectedBookmarkIDs.removeAll()
        isBatchMode = false
    }

    private func importBookmarks(from source: ImportSource) {
        guard !isImporting else { return }
        showImportSheet = false
        isImporting = true

        Task {
            let entries: [ImportEntry]
            switch source {
            case .chrome:
                entries = ChromeBookmarksImporter.loadAllEntries().map {
                    ImportEntry(title: $0.title, url: $0.url)
                }
            case .githubStars:
                guard let username = GitHubStarsImporter.parseUsername(from: githubStarsInput) else {
                    await MainActor.run {
                        importAlertMessage = "请输入有效的 GitHub 用户名或 profile 链接（如 https://github.com/用户名）。"
                        showImportAlert = true
                        isImporting = false
                    }
                    return
                }
                let result = await GitHubStarsImporter.loadAllEntries(username: username)
                switch result {
                case .success(let list):
                    entries = list
                case .failure(let err):
                    await MainActor.run {
                        importAlertMessage = "GitHub 获取失败：\(err.localizedDescription)"
                        showImportAlert = true
                        isImporting = false
                    }
                    return
                }
            }

            let selectedCategory: Category? = {
                if case .category(let selectedID) = selection {
                    return categories.first(where: { $0.id == selectedID })
                }
                return nil
            }()

            await MainActor.run {
                var existingURLs = Set(bookmarks.map { $0.url.lowercased() })
                var importedCount = 0
                var skippedCount = 0
                var importedItems: [Bookmark] = []

                for entry in entries {
                    let normalized = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else {
                        skippedCount += 1
                        continue
                    }
                    guard URL(string: normalized) != nil else {
                        skippedCount += 1
                        continue
                    }
                    let key = normalized.lowercased()
                    if existingURLs.contains(key) {
                        skippedCount += 1
                        continue
                    }

                    let bm = Bookmark(url: normalized, title: entry.title)
                    bm.category = selectedCategory
                    modelContext.insert(bm)
                    existingURLs.insert(key)
                    importedCount += 1
                    importedItems.append(bm)
                }

                do {
                    try modelContext.save()
                } catch {
                    importAlertMessage = "导入失败：\(error.localizedDescription)"
                    showImportAlert = true
                    isImporting = false
                    return
                }

                let categoryName = selectedCategory?.name ?? "未分类"
                importAlertMessage = "已导入 \(importedCount) 条到「\(categoryName)」，跳过 \(skippedCount) 条（重复或无效）。正在后台补全标题和封面。"
                showImportAlert = true
                isImporting = false

                Task {
                    await enrichImportedBookmarks(importedItems)
                }
            }
        }
    }

    private func enrichImportedBookmarks(_ importedItems: [Bookmark]) async {
        for bm in importedItems {
            let metadata = await MetadataService.shared.fetch(from: bm.url, fetchImage: true)
            await MainActor.run {
                if bm.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let title = metadata.title, !title.isEmpty
                {
                    bm.title = title
                }
                if bm.desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let desc = metadata.description, !desc.isEmpty
                {
                    bm.desc = desc
                }
                if bm.coverData == nil {
                    bm.coverData = metadata.imageData
                }
                if let imageURL = metadata.imageURL, !imageURL.isEmpty {
                    bm.coverURL = imageURL
                }
            }

            // AI refinement for imported items (title/desc/tags)
            if let ai = await AIService.shared.refineTitleAndDescription(
                for: bm.url,
                originalTitle: await MainActor.run { bm.title },
                originalDesc: await MainActor.run { bm.desc }
            ) {
                await MainActor.run {
                    if let t = ai.title,
                        !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        bm.title = t
                    }
                    if let d = ai.desc,
                        !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        bm.desc = d
                    }
                    if let tagList = ai.tags, !tagList.isEmpty {
                        let normalized = tagList
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if !normalized.isEmpty {
                            var seen = Set<String>()
                            let existing = bm.tags
                            let combined = (existing + normalized).filter { tag in
                                let lower = tag.lowercased()
                                if seen.contains(lower) { return false }
                                seen.insert(lower)
                                return true
                            }
                            bm.tags = combined
                        }
                    }
                    bm.updatedAt = Date()
                }
            } else {
                await MainActor.run {
                    bm.updatedAt = Date()
                }
            }
        }
        await MainActor.run {
            try? modelContext.save()
        }
    }
}

private struct MasonryLayout: Layout {
    let columns: Int
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        guard let width = proposal.width, width > 0 else {
            let fallbackWidth: CGFloat = 1000
            return measureLayout(for: fallbackWidth, subviews: subviews).size
        }
        return measureLayout(for: width, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty, bounds.width > 0 else { return }
        let measured = measureLayout(for: bounds.width, subviews: subviews)
        for (index, frame) in measured.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: nil)
            )
        }
    }

    private func measureLayout(for width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let columnCount = max(columns, 1)
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let columnWidth = max((width - totalSpacing) / CGFloat(columnCount), 1)

        var columnHeights = Array(repeating: CGFloat(0), count: columnCount)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)

        for subview in subviews {
            let targetColumn = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let x = CGFloat(targetColumn) * (columnWidth + spacing)
            let y = columnHeights[targetColumn]
            let fit = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let h = fit.height
            frames.append(CGRect(x: x, y: y, width: columnWidth, height: h))
            columnHeights[targetColumn] += h + spacing
        }

        let contentHeight = max((columnHeights.max() ?? spacing) - spacing, 0)
        return (CGSize(width: width, height: contentHeight), frames)
    }
}

// MARK: - Mouse tracking for follow-cursor preview

private final class MouseTrackingHostView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onExit: (() -> Void)?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onMove?(p)
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func mouseEntered(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onMove?(p)
    }
}

private struct MouseTrackingView: NSViewRepresentable {
    @Binding var location: CGPoint?
    var active: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MouseTrackingHostView {
        let v = MouseTrackingHostView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: MouseTrackingHostView, context: Context) {
        let binding = $location
        nsView.onMove = active ? { p in
            DispatchQueue.main.async { binding.wrappedValue = p }
        } : nil
        nsView.onExit = active ? {
            DispatchQueue.main.async { binding.wrappedValue = nil }
        } : nil
        if active, !context.coordinator.wasActive, let window = nsView.window {
            context.coordinator.wasActive = true
            let screenLoc = NSEvent.mouseLocation
            let winLoc = window.convertPoint(fromScreen: screenLoc)
            let viewLoc = nsView.convert(winLoc, from: nil)
            if nsView.bounds.contains(viewLoc) {
                DispatchQueue.main.async { binding.wrappedValue = viewLoc }
            }
        }
        if !active {
            context.coordinator.wasActive = false
        }
    }

    final class Coordinator {
        var wasActive = false
    }
}

private struct HoverPreviewCard: View {
    let bookmark: Bookmark

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bookmark.title.isEmpty ? bookmark.domain : bookmark.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)

            if !bookmark.desc.isEmpty {
                Text(bookmark.desc)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(3)
            }

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                Text(bookmark.domain)
                    .font(.caption2)
                Spacer()
                Text(bookmark.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
            }
            .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(12)
        .background(AppTheme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: AppTheme.glowAccent.opacity(0.4), radius: 16)
    }
}

private enum ImportSource: String, CaseIterable, Identifiable {
    case chrome
    case githubStars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome: return "Chrome"
        case .githubStars: return "GitHub Stars"
        }
    }

    var description: String {
        switch self {
        case .chrome:
            return "从 Chrome 浏览器书签中导入数据。"
        case .githubStars:
            return "从 GitHub 星标仓库列表导入，需提供用户名或 profile 链接。"
        }
    }

    var systemImageName: String {
        switch self {
        case .chrome: return "globe"
        case .githubStars: return "star.circle"
        }
    }
}

private struct ImportEntry {
    let title: String
    let url: String
}

private struct ImportBookmarksSheet: View {
    @Binding var selectedSource: ImportSource
    @Binding var githubStarsInput: String
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: (ImportSource) -> Void

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "导入书签", icon: "square.and.arrow.down") {
                onCancel()
            }

            VStack(alignment: .leading, spacing: 20) {
                Text("选择来源")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textTertiary)
                    .textCase(.uppercase)

                VStack(spacing: 10) {
                    ForEach(ImportSource.allCases) { source in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedSource = source
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: source.systemImageName)
                                    .font(.title3)
                                    .foregroundStyle(
                                        selectedSource == source
                                            ? AppTheme.accent : AppTheme.textTertiary
                                    )
                                    .frame(width: 28, height: 28)
                                    .background(
                                        selectedSource == source
                                            ? AppTheme.accent.opacity(0.18) : AppTheme.bgInput
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(source.description)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }

                                Spacer()

                                if selectedSource == source {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        selectedSource == source
                                            ? AppTheme.bgInput.opacity(0.9) : AppTheme.bgInput
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedSource == .githubStars {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GitHub 用户名或链接")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                            .textCase(.uppercase)
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textTertiary)
                            TextField("例如：octocat 或 https://github.com/octocat", text: $githubStarsInput)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                        }
                        .padding(12)
                        .background(AppTheme.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppTheme.borderSubtle, lineWidth: 1)
                        )
                        Text("无需 Token，公开 star 列表每小时最多约 60 次请求。")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                }

                Spacer()
            }
            .padding(24)

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .ghostButtonStyle()
                .buttonStyle(.plain)

                Button {
                    onImport(selectedSource)
                } label: {
                    HStack(spacing: 6) {
                        if isImporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text("开始导入")
                    }
                    .accentButtonStyle()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting)
            }
            .padding(20)
            .background(AppTheme.bgSecondary.opacity(0.5))
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(AppTheme.bgPrimary)
    }
}

private enum ChromeBookmarksImporter {
    struct Entry {
        let title: String
        let url: String
    }

    static func loadAllEntries() -> [Entry] {
        var all: [Entry] = []
        for fileURL in chromeBookmarkFiles() {
            all.append(contentsOf: parseBookmarkFile(fileURL))
        }
        return all
    }

    private static func chromeBookmarkFiles() -> [URL] {
        let fm = FileManager.default
        guard
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return [] }

        let chromeRoot = appSupport
            .appendingPathComponent("Google")
            .appendingPathComponent("Chrome")

        let names = (try? fm.contentsOfDirectory(
            atPath: chromeRoot.path(percentEncoded: false))
        ) ?? []

        var files: [URL] = []
        for name in names where name == "Default" || name.hasPrefix("Profile ") {
            let file = chromeRoot.appendingPathComponent(name).appendingPathComponent("Bookmarks")
            if fm.fileExists(atPath: file.path(percentEncoded: false)) {
                files.append(file)
            }
        }
        return files
    }

    private static func parseBookmarkFile(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let roots = root["roots"] as? [String: Any]
        else { return [] }

        var entries: [Entry] = []
        for (_, node) in roots {
            collectEntries(from: node, into: &entries)
        }
        return entries
    }

    private static func collectEntries(from any: Any, into entries: inout [Entry]) {
        guard let node = any as? [String: Any] else { return }
        let type = node["type"] as? String
        if type == "url" {
            let title = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (node["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url, !url.isEmpty {
                entries.append(Entry(title: title ?? "", url: url))
            }
        }
        if let children = node["children"] as? [Any] {
            for child in children {
                collectEntries(from: child, into: &entries)
            }
        }
    }
}

// MARK: - GitHub Stars

private enum GitHubStarsImporterError: Error {
    case message(String)
    var localizedDescription: String {
        if case .message(let s) = self { return s }
        return ""
    }
}

private enum GitHubStarsImporter {
    private static let perPage = 100
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func parseUsername(from input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.contains("github.com") {
            guard let url = URL(string: raw.hasPrefix("http") ? raw : "https://" + raw),
                  url.host?.lowercased().contains("github") == true
            else { return nil }
            let comps = url.pathComponents.filter { $0 != "/" }
            guard let first = comps.first, !first.isEmpty else { return nil }
            return first
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    static func loadAllEntries(username: String) async -> Result<[ImportEntry], GitHubStarsImporterError> {
        var all: [ImportEntry] = []
        var page = 1
        while true {
            guard let reqURL = URL(string: "https://api.github.com/users/\(username)/starred?per_page=\(perPage)&page=\(page)") else {
                return .failure(.message("无效请求"))
            }
            var request = URLRequest(url: reqURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                return .failure(.message(error.localizedDescription))
            }

            guard let http = response as? HTTPURLResponse else {
                return .failure(.message("无效响应"))
            }
            if http.statusCode == 404 {
                return .failure(.message("用户不存在或列表不可见"))
            }
            if http.statusCode == 403 {
                return .failure(.message("请求过于频繁（约 60 次/小时），请稍后再试"))
            }
            guard http.statusCode == 200 else {
                return .failure(.message("HTTP \(http.statusCode)"))
            }

            let repos: [GitHubRepoItem]
            do {
                repos = try JSONDecoder().decode([GitHubRepoItem].self, from: data)
            } catch {
                return .failure(.message("解析失败：\(error.localizedDescription)"))
            }

            for repo in repos {
                all.append(ImportEntry(title: repo.full_name, url: repo.html_url))
            }
            if repos.count < perPage {
                break
            }
            page += 1
        }
        return .success(all)
    }

    private struct GitHubRepoItem: Decodable {
        let full_name: String
        let html_url: String
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("accentTheme") private var accentThemeName = "purple"

    @AppStorage("ai.enabled") private var aiEnabled = false
    @AppStorage("ai.apiURL") private var aiAPIURL = ""
    @AppStorage("ai.apiKey") private var aiAPIKey = ""
    @AppStorage("ai.model") private var aiModel = ""

    @State private var aiTesting = false
    @State private var aiTestMessage = ""
    @State private var aiTestLog = ""

    private var currentTheme: AccentTheme {
        AccentTheme(rawValue: accentThemeName) ?? .purple
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("设置")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(AppTheme.bgElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("外观")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textTertiary)
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    ForEach(AccentTheme.allCases) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                accentThemeName = theme.rawValue
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 20, height: 20)
                                if currentTheme == theme {
                                    Circle()
                                        .stroke(.white, lineWidth: 2)
                                        .frame(width: 14, height: 14)
                                }
                            }
                            .shadow(
                                color: theme.color.opacity(currentTheme == theme ? 0.6 : 0),
                                radius: 4
                            )
                        }
                        .buttonStyle(.plain)
                        .help(theme.label)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("AI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textTertiary)
                    .textCase(.uppercase)

                Toggle(isOn: $aiEnabled) {
                    Text("启用 AI 生成标题与描述")
                        .foregroundStyle(AppTheme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    TextField("例如：gpt-4.1-mini 或 longcat 对应模型名", text: $aiModel)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .padding(8)
                        .background(AppTheme.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Base URL")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    TextField("例如：https://your-endpoint/v1/chat/completions", text: $aiAPIURL)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .padding(8)
                        .background(AppTheme.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    SecureField("用于 Authorization: Bearer ...", text: $aiAPIKey)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .padding(8)
                        .background(AppTheme.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text("说明：密钥保存在本机 UserDefaults，仅供本应用访问你的自建 AI 服务。请自行确保后端安全。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        if !aiEnabled {
                            aiTestMessage = "请先开启上方 AI 开关。"
                            aiTestLog = ""
                            return
                        }
                        aiTesting = true
                        aiTestMessage = "测试中，请稍候..."
                        aiTestLog = ""
                        let url = "https://example.com"
                        Task {
                            let result = await AIService.shared.refineTitleAndDescription(
                                for: url,
                                originalTitle: "Test title",
                                originalDesc: "Test description"
                            )
                            await MainActor.run {
                                aiTesting = false
                                if result != nil {
                                    aiTestMessage = "AI 调用成功：服务返回了有效结果。"
                                } else {
                                    aiTestMessage = "AI 调用未返回有效结果，请检查 URL、Key 或服务端实现。"
                                }
                                let log = UserDefaults.standard.string(forKey: "ai.lastLog") ?? ""
                                aiTestLog = log
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if aiTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text("测试 AI 配置")
                        }
                        .ghostButtonStyle()
                    }
                    .buttonStyle(.plain)
                    .disabled(aiTesting)
                }

                if !aiTestMessage.isEmpty {
                    Text(aiTestMessage)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !aiTestLog.isEmpty {
                    Text("最近一次 AI 请求日志：")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.textTertiary)
                    ScrollView {
                        Text(aiTestLog)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .background(AppTheme.bgPrimary)
    }
}

