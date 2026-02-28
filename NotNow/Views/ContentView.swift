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
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @AppStorage("accentTheme") private var accentThemeName = "dark"
    @State private var selection: SidebarSelection = .all
    /// 已生效的搜索词（用于查询）
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var selectedBookmark: Bookmark?
    @State private var columnCount = 5
    @State private var showCategorySheet = false
    @State private var editingCategory: Category?
    @State private var isImporting = false
    @State private var importAlertMessage = ""
    @State private var showImportAlert = false
    @State private var showImportSheet = false
    @State private var selectedImportSource: ImportSource = .chrome
    @State private var githubStarsInput = ""
    @AppStorage("twitterLikes.enabled") private var twitterLikesEnabled = false
    @AppStorage("twitterLikes.binPath") private var twitterLikesBinPath = ""
    @AppStorage("twitterLikes.likesURL") private var twitterLikesURL = ""
    @AppStorage("twitterLikes.maxFetchCount") private var twitterLikesMaxFetchCount = 80
    @AppStorage("twitterLikes.tweetSettleSeconds") private var twitterLikesTweetSettleSeconds = 8
    @State private var notNowZipURL: URL?
    @State private var isBatchMode = false
    @State private var selectedBookmarkIDs: Set<UUID> = []
    @State private var showSettings = false
    @State private var searchFocusRequest = 0
    /// 分页：首屏条数，滚动到底或最后一格出现时加载下一页
    private static let pageSize = 20
    @State private var bookmarks: [Bookmark] = []
    @State private var totalFilteredCount = 0
    @State private var allBookmarkCount = 0
    @State private var currentFetchLimit = ContentView.pageSize
    @State private var isLoadingMore = false
    @State private var categoryBookmarkCounts: [UUID: Int] = [:]
    @State private var uncategorizedBookmarkCount = 0
    @State private var columnBookmarksCache: [[Bookmark]] = []
    @State private var isBatchRetagging = false
    @State private var batchRetagProgressText = ""
    @State private var transientTip: String?
    @State private var tipDismissTask: Task<Void, Never>?
    private let searchDebounceNanoseconds: UInt64 = 450_000_000

    private var currentTheme: AccentTheme {
        AccentTheme(rawValue: accentThemeName) ?? .dark
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.backgroundGradient
                .ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar
                Divider().background(AppTheme.borderSubtle)
                mainContent
            }
            
            // Command Palette
            CommandPaletteView()

            if let tip = transientTip {
                Text(tip)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: transientTip)
        .sheet(isPresented: $showAddSheet) {
            AddBookmarkSheet()
                .preferredColorScheme(currentTheme.colorScheme)
        }
        .sheet(item: $selectedBookmark) { bm in
            BookmarkDetailSheet(bookmark: bm)
                .preferredColorScheme(currentTheme.colorScheme)
        }
        .sheet(isPresented: $showCategorySheet) {
            CategorySheet(editingCategory: editingCategory)
                .preferredColorScheme(currentTheme.colorScheme)
        }
        .sheet(isPresented: $showImportSheet) {
            ImportBookmarksSheet(
                selectedSource: $selectedImportSource,
                githubStarsInput: $githubStarsInput,
                twitterLikesEnabled: twitterLikesEnabled,
                twitterLikesURL: twitterLikesURL,
                notNowZipURL: $notNowZipURL,
                isImporting: isImporting,
                onCancel: { showImportSheet = false },
                onImport: { source in
                    importBookmarks(from: source)
                }
            )
            .preferredColorScheme(currentTheme.colorScheme)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(categories: categories)
                .preferredColorScheme(currentTheme.colorScheme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addBookmark)) { _ in
            showAddSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocusRequest += 1
        }
        .onAppear {
            NSLog("[NotNow] app appeared")
            ensureFavoriteCategoryExists()
            refreshAll()
        }
        .onChange(of: showCategorySheet) {
            if !showCategorySheet {
                editingCategory = nil
                refreshAll()
            }
        }
        .onChange(of: selection) {
            currentFetchLimit = ContentView.pageSize
            fetchBookmarks()
        }
        .onChange(of: columnCount) {
            columnBookmarksCache = splitIntoColumns(bookmarks: bookmarks, columns: columnCount)
        }
        .onChange(of: showAddSheet) {
            if !showAddSheet { refreshAll() }
        }
        .onChange(of: selectedBookmark) { oldValue, newValue in
            if oldValue != nil && newValue == nil { refreshAll() }
        }
        .onChange(of: showImportSheet) {
            if !showImportSheet { refreshAll() }
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
                count: allBookmarkCount,
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
                        let catCount = categoryBookmarkCounts[cat.id] ?? 0
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
                    let uncatCount = uncategorizedBookmarkCount
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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
                DebouncedSearchField(
                    text: $searchText,
                    focusRequest: searchFocusRequest,
                    debounceNanoseconds: searchDebounceNanoseconds
                ) {
                    currentFetchLimit = ContentView.pageSize
                    fetchBookmarks()
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
                ForEach([4, 5, 6], id: \.self) { n in
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
                        Text(selectedBookmarkIDs.count == bookmarks.count ? "清空" : "全选")
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

                    Button {
                        retagSelected()
                    } label: {
                        HStack(spacing: 6) {
                            if isBatchRetagging {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(isBatchRetagging ? batchRetagProgressText : "重打标(\(selectedBookmarkIDs.count))")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .ghostButtonStyle()
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedBookmarkIDs.isEmpty || isBatchRetagging)
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

    /// 瀑布流列分配：按预估高度把书签分到多列，使各列高度尽量均衡，便于 LazyVStack 懒加载
    private func splitIntoColumns(bookmarks: [Bookmark], columns: Int) -> [[Bookmark]] {
        guard columns > 0, !bookmarks.isEmpty else { return bookmarks.isEmpty ? [] : [bookmarks] }
        let spacing: CGFloat = 14
        let estimatedHeight: (Bookmark) -> CGFloat = {
            if $0.isTask { return 120 }
            return $0.hasCover ? 250 : 140
        }
        var columnHeights = [CGFloat](repeating: 0, count: columns)
        var result = [[Bookmark]](repeating: [], count: columns)
        for bm in bookmarks {
            let col = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            result[col].append(bm)
            columnHeights[col] += estimatedHeight(bm) + spacing
        }
        return result
    }

    private func loadMore() {
        guard !isLoadingMore, bookmarks.count < totalFilteredCount else { return }
        isLoadingMore = true
        currentFetchLimit += ContentView.pageSize
        fetchBookmarks()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            isLoadingMore = false
        }
    }

    private var bookmarkGrid: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    if bookmarks.isEmpty {
                        emptyState
                    } else {
                        let contentWidth = max(proxy.size.width - 44, 1)
                        let spacing: CGFloat = 14
                        let columnWidth = (contentWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(max(columnCount, 1))

                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: spacing) {
                                ForEach(0 ..< columnCount, id: \.self) { colIndex in
                                    let columnBookmarks = colIndex < columnBookmarksCache.count ? columnBookmarksCache[colIndex] : []
                                    LazyVStack(spacing: spacing) {
                                        ForEach(Array(columnBookmarks.enumerated()), id: \.element.id) { index, bm in
                                            bookmarkCell(for: bm)
                                                .onAppear {
                                                    let isLastInColumn = index == columnBookmarks.count - 1
                                                    if isLastInColumn, bookmarks.count < totalFilteredCount {
                                                        loadMore()
                                                    }
                                                }
                                        }
                                    }
                                    .frame(width: max(columnWidth, 1), alignment: .top)
                                }
                            }
                            .frame(width: contentWidth, alignment: .topLeading)

                            if bookmarks.count < totalFilteredCount {
                                Color.clear
                                    .frame(height: 20)
                                    .onAppear { loadMore() }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 8)
                    }
                }
                .scrollIndicators(.visible)

                if !bookmarks.isEmpty {
                    listProgressFooter()
                }
            }
        }
    }

    /// 底部固定：已显示数量 / 总数、加载进度，以及强制刷新按钮
    private func listProgressFooter() -> some View {
        VStack(spacing: 6) {
            if isLoadingMore {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 3)
                    .tint(currentTheme.color)
                    .padding(.horizontal, 22)
            }
            HStack {
                Text(bookmarks.count >= totalFilteredCount
                     ? "共 \(totalFilteredCount) 条"
                     : "已显示 \(bookmarks.count) / \(totalFilteredCount) 条")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
                Spacer()
                Button {
                    loadMore()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("强制刷新")
                    }
                    .font(.caption2)
                    .foregroundStyle(currentTheme.color)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 22)
        .background(AppTheme.bgPrimary)
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
        if bm.isTask {
            Button(bm.taskCompleted ? "标记未完成" : "标记完成") {
                bm.taskCompleted.toggle()
                bm.updatedAt = Date()
                try? modelContext.save()
                refreshAll()
            }
            Button("编辑") { selectedBookmark = bm }
            if !bm.url.hasPrefix("task://") {
                Button("打开关联链接") {
                    if let url = URL(string: bm.url) { NSWorkspace.shared.open(url) }
                }
            }
        } else {
            Button(bm.isSnippet ? "复制内容" : "打开") {
                OpenService.open(bm)
                showTip(bm.isSnippet ? "已复制" : "已打开")
            }
            if !bm.isSnippet {
                Button("在浏览器中打开") {
                    if let url = URL(string: bm.url) { NSWorkspace.shared.open(url) }
                }
            }
        }
        Divider()
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
            toggleFavorite(bm)
        }
        Divider()
        if !bm.isTask || !bm.url.hasPrefix("task://") {
            Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bm.url, forType: .string)
                showTip("链接已复制")
            }
        }
        Button("编辑") { selectedBookmark = bm }
        Divider()
        Button("删除", role: .destructive) {
            modelContext.delete(bm)
            refreshAll()
        }
    }

    private func bookmarkCell(for bookmark: Bookmark) -> some View {
        BookmarkCardView(bookmark: bookmark)
            .overlay(alignment: .topLeading) {
                if isBatchMode {
                    batchCheckmark(for: bookmark.id)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isBatchMode {
                    toggleSelection(for: bookmark.id)
                } else if !NSEvent.modifierFlags.contains(.command) {
                    handleClickAction(for: bookmark, isCmdClick: false)
                }
            }
            .modifier(NonBatchGesturesModifier(isBatchMode: isBatchMode) {
                handleClickAction(for: bookmark, isCmdClick: true)
            })
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

    private func toggleSelection(for id: UUID) {
        if selectedBookmarkIDs.contains(id) {
            selectedBookmarkIDs.remove(id)
        } else {
            selectedBookmarkIDs.insert(id)
        }
    }

    private func toggleSelectAll() {
        let visibleIDs = Set(bookmarks.map(\.id))
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
        refreshAll()
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
        refreshAll()
    }

    private func toggleFavorite(_ bm: Bookmark) {
        bm.isFavorite.toggle()
        bm.updatedAt = Date()
        
        // 管理收藏分类
        let favoriteCategory = ensureFavoriteCategory()
        if bm.isFavorite {
            bm.category = favoriteCategory
        } else {
            // 如果当前在收藏分类中，移除分类
            if bm.category?.id == favoriteCategory.id {
                bm.category = nil
            }
        }
        
        try? modelContext.save()
        refreshAll()
    }

    private func ensureFavoriteCategory() -> Category {
        // 查找现有的收藏分类
        if let existing = categories.first(where: { $0.name == "收藏" }) {
            return existing
        }
        
        // 创建新的收藏分类
        let favoriteCategory = Category(
            name: "收藏",
            icon: "star.fill",
            colorHex: 0xFFD700, // 金色
            sortOrder: -1 // 排在最前面
        )
        modelContext.insert(favoriteCategory)
        try? modelContext.save()
        return favoriteCategory
    }

    private func ensureFavoriteCategoryExists() {
        // 检查是否已存在收藏分类
        if categories.contains(where: { $0.name == "收藏" }) {
            return
        }
        
        // 创建默认收藏分类
        let favoriteCategory = Category(
            name: "收藏",
            icon: "star.fill",
            colorHex: 0xFFD700, // 金色
            sortOrder: -1 // 排在最前面
        )
        modelContext.insert(favoriteCategory)
        try? modelContext.save()
    }

    private func retagSelected() {
        guard !selectedBookmarkIDs.isEmpty else { return }
        guard !isBatchRetagging else { return }
        let selected = bookmarks.filter { selectedBookmarkIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        // 分类统计
        let snippets = selected.filter { $0.isSnippet }
        let twitterLinks = selected.filter { isTwitterURL($0.url) && !$0.isSnippet }
        let normalLinks = selected.filter { !isTwitterURL($0.url) && !$0.isSnippet }

        // 检查 Twitter 配置
        let canProcessTwitter = twitterLikesEnabled && !twitterLikesBinPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !twitterLinks.isEmpty && !canProcessTwitter {
            // 显示警告但继续处理其他类型
            importAlertMessage = "检测到 \(twitterLinks.count) 条 Twitter 链接，但未配置 Actionbook。将跳过 Twitter 链接，使用普通链接处理方式。"
            showImportAlert = true
        }

        isBatchRetagging = true
        batchRetagProgressText = "重打标中 0/\(selected.count)"

        Task {
            var stats = BatchRetagStats(total: selected.count)

            for (index, bm) in selected.enumerated() {
                await retagBookmark(bm, canProcessTwitter: canProcessTwitter, stats: &stats)
                await MainActor.run {
                    batchRetagProgressText = "重打标中 \(index + 1)/\(stats.total)"
                }
            }

            await MainActor.run {
                try? modelContext.save()
                isBatchRetagging = false
                batchRetagProgressText = ""
                importAlertMessage = "批量重打标完成：共处理 \(stats.total) 条（Snippet: \(stats.snippets), Task: \(stats.tasks), 普通链接: \(stats.normalLinks), Twitter: \(stats.twitterLinks), 跳过: \(stats.skipped)）"
                showImportAlert = true
            }
        }
    }

    private func refreshAll() {
        fetchSidebarCounts()
        fetchBookmarks()
    }

    private func fetchSidebarCounts() {
        allBookmarkCount = (try? modelContext.fetchCount(FetchDescriptor<Bookmark>())) ?? 0

        var counts: [UUID: Int] = [:]
        for cat in categories {
            let catID = cat.id
            let desc = FetchDescriptor<Bookmark>(predicate: #Predicate<Bookmark> { $0.category?.id == catID })
            counts[catID] = (try? modelContext.fetchCount(desc)) ?? 0
        }
        categoryBookmarkCounts = counts

        let uncatDesc = FetchDescriptor<Bookmark>(predicate: #Predicate<Bookmark> { $0.category == nil })
        uncategorizedBookmarkCount = (try? modelContext.fetchCount(uncatDesc)) ?? 0
    }

    private func fetchBookmarks() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopePredicate = currentScopePredicate()

        if q.isEmpty {
            var descriptor = FetchDescriptor<Bookmark>(
                predicate: scopePredicate,
                sortBy: [SortDescriptor(\Bookmark.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = currentFetchLimit
            bookmarks = (try? modelContext.fetch(descriptor)) ?? []

            var countDescriptor = FetchDescriptor<Bookmark>(predicate: scopePredicate)
            countDescriptor.propertiesToFetch = []
            totalFilteredCount = (try? modelContext.fetchCount(countDescriptor)) ?? 0
        } else {
            let descriptor = FetchDescriptor<Bookmark>(
                predicate: scopePredicate,
                sortBy: [SortDescriptor(\Bookmark.createdAt, order: .reverse)]
            )
            let scopedBookmarks = (try? modelContext.fetch(descriptor)) ?? []
            let filtered = scopedBookmarks.filter { bookmarkMatchesSearch($0, query: q) }
            totalFilteredCount = filtered.count
            bookmarks = Array(filtered.prefix(currentFetchLimit))
        }

        columnBookmarksCache = splitIntoColumns(bookmarks: bookmarks, columns: columnCount)
        selectedBookmarkIDs = selectedBookmarkIDs.intersection(Set(bookmarks.map(\.id)))
    }

    private func currentScopePredicate() -> Predicate<Bookmark> {
        switch selection {
        case .all:
            return #Predicate<Bookmark> { _ in true }
        case .category(let id):
            return #Predicate<Bookmark> { bm in
                bm.category?.id == id
            }
        case .uncategorized:
            return #Predicate<Bookmark> { bm in
                bm.category == nil
            }
        }
    }

    private func bookmarkMatchesSearch(_ bm: Bookmark, query: String) -> Bool {
        if bm.url.localizedStandardContains(query) { return true }
        if bm.title.localizedStandardContains(query) { return true }
        if bm.desc.localizedStandardContains(query) { return true }
        if bm.snippetText.localizedStandardContains(query) { return true }
        if bm.notes.localizedStandardContains(query) { return true }
        if bm.tags.contains(where: { $0.localizedStandardContains(query) }) { return true }
        return false
    }

    private func handleClickAction(for bookmark: Bookmark, isCmdClick: Bool) {
        let action = OpenService.resolveAction(for: bookmark, isCmdClick: isCmdClick)
        if OpenService.executeAction(action, bookmark: bookmark, isCmdClick: isCmdClick) {
            showTipText(for: action)
        } else {
            selectedBookmark = bookmark
        }
    }

    private func showTipText(for action: ClickAction) {
        switch action {
        case .copy:
            showTip("已复制")
        case .browser:
            showTip("已打开")
        case .script:
            showTip("已执行脚本")
        case .edit:
            break
        }
    }

    private func showTip(_ message: String) {
        tipDismissTask?.cancel()
        withAnimation {
            transientTip = message
        }
        tipDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation {
                transientTip = nil
            }
        }
    }

    private func isTwitterURL(_ rawURL: String) -> Bool {
        guard let u = URL(string: rawURL), let host = u.host?.lowercased() else { return false }
        return host.contains("x.com") || host.contains("twitter.com")
    }

    private func urlDedupKey(_ rawURL: String) -> String {
        rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func bookmarkExistsInStore(for normalizedURL: String, dedupKey: String) -> Bool {
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate<Bookmark> { bm in
                bm.url == normalizedURL || bm.url == dedupKey
            }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { tag in
                let lower = tag.lowercased()
                if seen.contains(lower) { return false }
                seen.insert(lower)
                return true
            }
    }

    private func retagBookmark(_ bm: Bookmark, canProcessTwitter: Bool, stats: inout BatchRetagStats) async {
        if bm.isSnippet {
            await retagSnippetBookmark(bm)
            stats.snippets += 1
        } else if bm.isTask {
            await retagTaskBookmark(bm)
            stats.tasks += 1
        } else if isTwitterURL(bm.url) {
            if canProcessTwitter {
                await retagTwitterBookmark(bm)
                stats.twitterLinks += 1
            } else {
                // Twitter 未配置时作为普通链接处理
                await retagNormalBookmark(bm)
                stats.normalLinks += 1
            }
        } else {
            await retagNormalBookmark(bm)
            stats.normalLinks += 1
        }
    }

    private func retagTaskBookmark(_ bm: Bookmark) async {
        let content = await MainActor.run { bm.desc }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let ai = await AIService.shared.refineSnippet(
            content: content,
            originalTitle: await MainActor.run { bm.title },
            originalDesc: await MainActor.run { bm.desc }
        ) {
            await MainActor.run {
                if let t = ai.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    bm.title = t
                }
                if let d = ai.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                    bm.desc = d
                }
                if let tagList = ai.tags {
                    bm.tags = normalizedTags(tagList)
                }
                bm.updatedAt = Date()
            }
        } else {
            await MainActor.run { bm.updatedAt = Date() }
        }
    }

    private func retagSnippetBookmark(_ bm: Bookmark) async {
        let content = await MainActor.run { bm.snippetText }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let ai = await AIService.shared.refineSnippet(
            content: content,
            originalTitle: await MainActor.run { bm.title },
            originalDesc: await MainActor.run { bm.desc }
        ) {
            await MainActor.run {
                if let t = ai.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    bm.title = t
                }
                if let d = ai.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                    bm.desc = d
                }
                if let tagList = ai.tags {
                    bm.tags = normalizedTags(tagList)
                }
                bm.updatedAt = Date()
            }
        } else {
            await MainActor.run { bm.updatedAt = Date() }
        }
    }

    private func retagNormalBookmark(_ bm: Bookmark) async {
        let metadata = await MetadataService.shared.fetch(from: bm.url, fetchImage: true)
        await MainActor.run {
            if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                bm.title = title
            }
            if let desc = metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                bm.desc = desc
            }
            if let imageURL = metadata.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
                bm.coverURL = imageURL
            }
            if let data = metadata.imageData {
                bm.coverData = data
            }
        }

        if let ai = await AIService.shared.refineTitleAndDescription(
            for: bm.url,
            originalTitle: await MainActor.run { bm.title },
            originalDesc: await MainActor.run { bm.desc }
        ) {
            await MainActor.run {
                if let t = ai.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    bm.title = t
                }
                if let d = ai.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                    bm.desc = d
                }
                if let tagList = ai.tags {
                    bm.tags = normalizedTags(tagList)
                }
                bm.updatedAt = Date()
            }
        } else {
            await MainActor.run {
                bm.updatedAt = Date()
            }
        }
    }

    private func retagTwitterBookmark(_ bm: Bookmark) async {
        let binPath = twitterLikesBinPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let settle = max(1, twitterLikesTweetSettleSeconds)
        let extracted = await TwitterTweetExtractor.extractTweet(
            tweetURL: bm.url,
            actionbookBinPath: binPath,
            settleSeconds: settle
        )

        let tweetText = (extracted?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let truncatedDesc = tweetText.isEmpty ? "" : String(tweetText.prefix(280))

        await MainActor.run {
            if !tweetText.isEmpty {
                bm.title = tweetText
                bm.desc = truncatedDesc
            } else if let fallback = extracted?.fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
                bm.title = fallback
            }
            if let imageURL = extracted?.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !imageURL.isEmpty {
                bm.coverURL = imageURL
            }
        }

        if let imageURL = extracted?.imageURL, !imageURL.isEmpty {
            let imageData = await MetadataService.shared.fetchImageData(from: imageURL)
            await MainActor.run {
                if let imageData {
                    bm.coverData = imageData
                }
            }
        }

        if let ai = await AIService.shared.refineTitleAndDescription(
            for: bm.url,
            originalTitle: await MainActor.run { bm.title },
            originalDesc: await MainActor.run { bm.desc }
        ) {
            await MainActor.run {
                if let t = ai.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    bm.title = t
                }
                if let d = ai.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                    bm.desc = d
                }
                if let tagList = ai.tags {
                    bm.tags = normalizedTags(tagList)
                }
                bm.updatedAt = Date()
            }
        } else {
            await MainActor.run {
                bm.updatedAt = Date()
            }
        }
    }

    private func importBookmarks(from source: ImportSource) {
        guard !isImporting else { return }
        showImportSheet = false
        isImporting = true

        Task {
            switch source {
            case .notNow:
                guard let zipURL = notNowZipURL else {
                    await MainActor.run {
                        importAlertMessage = "请先选择 NotNow 备份文件（.zip）。"
                        showImportAlert = true
                        isImporting = false
                    }
                    return
                }
                let result = await NotNowBackupService.import(from: zipURL, into: modelContext)
                await MainActor.run {
                    switch result {
                    case .success(let stats):
                        importAlertMessage = "已恢复 \(stats.bookmarksCreated) 条书签、\(stats.categoriesCreated) 个分类。\(stats.configRestored ? "配置已恢复。" : "")"
                        showImportAlert = true
                    case .failure(let err):
                        let msg: String
                        if case .readFailed(let s) = err { msg = s }
                        else if case .writeFailed(let s) = err { msg = s }
                        else if case .invalidZip = err { msg = "无效的 zip 或非 NotNow 备份。" }
                        else if case .missingCategories = err { msg = "备份缺少 categories.json。" }
                        else if case .missingBookmarks = err { msg = "备份缺少 bookmarks.json。" }
                        else { msg = String(describing: err) }
                        importAlertMessage = "导入失败：\(msg)"
                        showImportAlert = true
                    }
                    isImporting = false
                }
                return
            case .chrome, .githubStars, .twitterLikes:
                break
            }

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
            case .twitterLikes:
                guard twitterLikesEnabled else {
                    await MainActor.run {
                        importAlertMessage = "Twitter 导入未启用，请先到设置中开启「启用 Twitter Likes 导入」。"
                        showImportAlert = true
                        isImporting = false
                    }
                    return
                }
                guard let likesURL = TwitterLikesImporter.parseLikesURL(from: twitterLikesURL) else {
                    await MainActor.run {
                        importAlertMessage = "请先在设置中填写有效的 Likes URL（如 https://x.com/<用户名>/likes）。"
                        showImportAlert = true
                        isImporting = false
                    }
                    return
                }
                let binPath = twitterLikesBinPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if binPath.isEmpty {
                    await MainActor.run {
                        importAlertMessage = "请先在设置中填写 Actionbook BIN Path。"
                        showImportAlert = true
                        isImporting = false
                    }
                    return
                }
                let result = await TwitterLikesImporter.loadAllEntries(
                    likesURL: likesURL,
                    actionbookBinPath: binPath,
                    maxFetchCount: max(1, twitterLikesMaxFetchCount)
                )
                switch result {
                case .success(let list):
                    entries = list
                case .failure(let err):
                    await MainActor.run {
                        importAlertMessage = "Twitter Likes 获取失败：\(err.localizedDescription)"
                        showImportAlert = true
                        isImporting = false
                    }
                    return
                }
            case .notNow:
                return
            }

            let selectedCategory: Category? = {
                if case .category(let selectedID) = selection {
                    return categories.first(where: { $0.id == selectedID })
                }
                return nil
            }()

            await MainActor.run {
                var knownExistingURLKeys = Set<String>()
                var importedCount = 0
                var skippedCount = 0
                var stoppedAtExisting = false
                var importedItems: [Bookmark] = []
                let stopOnFirstExisting = source == .twitterLikes

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
                    let key = urlDedupKey(normalized)
                    if knownExistingURLKeys.contains(key)
                        || bookmarkExistsInStore(for: normalized, dedupKey: key)
                    {
                        knownExistingURLKeys.insert(key)
                        if stopOnFirstExisting {
                            stoppedAtExisting = true
                            break
                        }
                        skippedCount += 1
                        continue
                    }

                    let bm = Bookmark(url: normalized, title: entry.title)
                    bm.category = selectedCategory
                    modelContext.insert(bm)
                    knownExistingURLKeys.insert(key)
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
                if source == .twitterLikes {
                    let stopText = stoppedAtExisting ? "，命中已有记录后已停止增量同步" : ""
                    importAlertMessage = "已导入 \(importedCount) 条到「\(categoryName)」，跳过 \(skippedCount) 条（无效）\(stopText)。正在后台补全标题和封面。"
                } else {
                    importAlertMessage = "已导入 \(importedCount) 条到「\(categoryName)」，跳过 \(skippedCount) 条（重复或无效）。正在后台补全标题和封面。"
                }
                showImportAlert = true
                isImporting = false

                Task {
                    await enrichImportedBookmarks(importedItems, source: source)
                }
            }
        }
    }

    private func enrichImportedBookmarks(_ importedItems: [Bookmark], source: ImportSource) async {
        if source == .twitterLikes {
            await enrichTwitterImportedBookmarks(importedItems)
            return
        }

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

    private func enrichTwitterImportedBookmarks(_ importedItems: [Bookmark]) async {
        let binPath = twitterLikesBinPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let settle = max(1, twitterLikesTweetSettleSeconds)
        for bm in importedItems {
            let extracted = await TwitterTweetExtractor.extractTweet(
                tweetURL: bm.url,
                actionbookBinPath: binPath,
                settleSeconds: settle
            )

            let tweetText = (extracted?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let truncatedDesc = tweetText.isEmpty ? "" : String(tweetText.prefix(280))

            await MainActor.run {
                if bm.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !tweetText.isEmpty {
                        bm.title = tweetText
                    } else if let fallback = extracted?.fallbackTitle, !fallback.isEmpty {
                        bm.title = fallback
                    } else {
                        bm.title = "X 推文"
                    }
                }
                if !truncatedDesc.isEmpty {
                    bm.desc = truncatedDesc
                }
                if let imageURL = extracted?.imageURL, !imageURL.isEmpty {
                    bm.coverURL = imageURL
                }
            }

            if let imageURL = extracted?.imageURL, !imageURL.isEmpty {
                let imageData = await MetadataService.shared.fetchImageData(from: imageURL)
                await MainActor.run {
                    if bm.coverData == nil {
                        bm.coverData = imageData
                    }
                }
            }

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

            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }

        await MainActor.run {
            try? modelContext.save()
        }
    }
}

private struct DebouncedSearchField: View {
    @Binding var text: String
    let focusRequest: Int
    let debounceNanoseconds: UInt64
    let onDebouncedCommit: () -> Void

    @State private var draftText = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            TextField("搜索书签...", text: $draftText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($isFocused)
            if !draftText.isEmpty {
                Button {
                    draftText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            draftText = text
        }
        .onChange(of: focusRequest) {
            isFocused = true
        }
        .onChange(of: text) { _, newValue in
            if newValue != draftText {
                draftText = newValue
            }
        }
        .onChange(of: draftText) {
            scheduleCommit()
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    private func scheduleCommit() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            let pending = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard pending != text else { return }
            text = pending
            onDebouncedCommit()
        }
    }
}

// MARK: - Batch Retag Stats

private struct BatchRetagStats {
    var total: Int
    var snippets: Int = 0
    var tasks: Int = 0
    var normalLinks: Int = 0
    var twitterLinks: Int = 0
    var skipped: Int = 0

    init(total: Int) {
        self.total = total
    }
}

private struct NonBatchGesturesModifier: ViewModifier {
    let isBatchMode: Bool
    let onCmdClick: () -> Void

    func body(content: Content) -> some View {
        if isBatchMode {
            content
        } else {
            content
                .simultaneousGesture(
                    TapGesture()
                        .modifiers(.command)
                        .onEnded { onCmdClick() }
                )
        }
    }
}

private enum ImportSource: String, CaseIterable, Identifiable {
    case chrome
    case githubStars
    case twitterLikes
    case notNow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome: return "Chrome"
        case .githubStars: return "GitHub Stars"
        case .twitterLikes: return "Twitter Likes"
        case .notNow: return "NotNow 备份"
        }
    }

    var description: String {
        switch self {
        case .chrome:
            return "从 Chrome 浏览器书签中导入数据。"
        case .githubStars:
            return "从 GitHub 星标仓库列表导入，需提供用户名或 profile 链接。"
        case .twitterLikes:
            return "从 X(Twitter) 点赞流增量导入，遇到已存在链接即停止。"
        case .notNow:
            return "从本机 NotNow 导出的 .zip 备份恢复书签、分类与配置。"
        }
    }

    var systemImageName: String {
        switch self {
        case .chrome: return "globe"
        case .githubStars: return "star.circle"
        case .twitterLikes: return "heart.circle"
        case .notNow: return "doc.zipper"
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
    let twitterLikesEnabled: Bool
    let twitterLikesURL: String
    @Binding var notNowZipURL: URL?
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

                if selectedSource == .twitterLikes {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Twitter Likes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                            .textCase(.uppercase)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(twitterLikesEnabled ? "已启用：将使用设置中的 BIN Path 与 Likes URL。" : "未启用：请先到设置中开启 Twitter Likes 导入。")
                                .font(.caption)
                                .foregroundStyle(twitterLikesEnabled ? AppTheme.textSecondary : AppTheme.accentPink)
                            Text(twitterLikesURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Likes URL: (未设置)" : "Likes URL: \(twitterLikesURL)")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textTertiary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .background(AppTheme.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppTheme.borderSubtle, lineWidth: 1)
                        )
                        Text("导入规则：只拉最新，命中库内已有链接即停止。")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                }

                if selectedSource == .notNow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备份文件 (.zip)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                            .textCase(.uppercase)
                        HStack(spacing: 8) {
                            Button {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.zip]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    notNowZipURL = url
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.zipper")
                                    Text(notNowZipURL == nil ? "选择备份文件" : notNowZipURL!.lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(AppTheme.bgInput)
                                .foregroundStyle(AppTheme.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            if notNowZipURL != nil {
                                Button {
                                    notNowZipURL = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("由本应用的「导出数据与配置」生成的 zip 包。")
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
                .disabled(
                    isImporting
                        || (selectedSource == .notNow && notNowZipURL == nil)
                        || (selectedSource == .twitterLikes && !twitterLikesEnabled)
                )
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

// MARK: - Twitter Likes (External Command / Actionbook)

private enum TwitterLikesImporterError: Error {
    case message(String)
    var localizedDescription: String {
        if case .message(let s) = self { return s }
        return ""
    }
}

private enum TwitterLikesImporter {
    static func parseLikesURL(from input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let url = URL(string: raw.hasPrefix("http") ? raw : "https://" + raw),
              let host = url.host?.lowercased()
        else { return nil }
        guard host == "x.com" || host == "twitter.com" || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com") else {
            return nil
        }
        let path = url.path.lowercased()
        guard path.hasSuffix("/likes") else { return nil }
        return url.absoluteString
    }

    static func loadAllEntries(likesURL: String, actionbookBinPath: String, maxFetchCount: Int) async -> Result<[ImportEntry], TwitterLikesImporterError> {
        guard let scriptPath = scriptPath() else {
            return .failure(.message("未找到脚本 scripts/twitter_likes_actionbook.sh。"))
        }
        let safeCount = max(1, maxFetchCount)
        let command = "ACTIONBOOK_BIN=\(shellSingleQuote(actionbookBinPath)) sh \(shellSingleQuote(scriptPath)) \(shellSingleQuote(likesURL)) \(safeCount)"
        let result = await runShell(command: command)
        switch result {
        case .failure(let err):
            return .failure(err)
        case .success(let output):
            let lines = output
                .split(whereSeparator: { $0.isNewline })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if lines.isEmpty {
                return .success([])
            }
            if let json = parseJSONEntries(output: output), !json.isEmpty {
                return .success(json)
            }
            let entries = parseTextEntries(lines: lines)
            if entries.isEmpty {
                return .failure(.message("命令执行成功，但无法解析输出。请输出 JSON 数组或每行一个 URL。"))
            }
            return .success(entries)
        }
    }

    private static func parseJSONEntries(output: String) -> [ImportEntry]? {
        guard let data = output.data(using: .utf8) else { return nil }
        if let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var result: [ImportEntry] = []
            for obj in objects {
                let url = (obj["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if url.isEmpty { continue }
                let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ImportEntry(title: title, url: url))
            }
            return result
        }
        return nil
    }

    private static func parseTextEntries(lines: [String]) -> [ImportEntry] {
        var result: [ImportEntry] = []
        for line in lines {
            if line.hasPrefix("#") { continue }
            if line.contains("\t") {
                let comps = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let title = String(comps[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = comps.count > 1
                    ? String(comps[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                if !url.isEmpty { result.append(ImportEntry(title: title, url: url)) }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                result.append(ImportEntry(title: "", url: trimmed))
            }
        }
        return result
    }

    private static func runShell(command: String) async -> Result<String, TwitterLikesImporterError> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(.message("启动命令失败：\(error.localizedDescription)")))
                return
            }

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus != 0 {
                    if err.isEmpty {
                        continuation.resume(returning: .failure(.message("命令失败，退出码 \(proc.terminationStatus)。")))
                    } else {
                        continuation.resume(returning: .failure(.message(err)))
                    }
                    return
                }
                continuation.resume(returning: .success(out))
            }
        }
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func scriptPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        let cwdCandidate = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("scripts/twitter_likes_actionbook.sh")
            .path(percentEncoded: false)
        candidates.append(cwdCandidate)

        // Build-time source path hint (useful when app cwd is not repository root).
        let sourceBased = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/twitter_likes_actionbook.sh")
            .path(percentEncoded: false)
        candidates.append(sourceBased)

        // Workspace fallback for current project.
        candidates.append("/Users/shadow/Documents/code/notnow/scripts/twitter_likes_actionbook.sh")

        for path in candidates where fm.fileExists(atPath: path) { return path }

        if let bundleCandidate = Bundle.main.resourceURL?
            .appendingPathComponent("scripts/twitter_likes_actionbook.sh"),
           fm.fileExists(atPath: bundleCandidate.path(percentEncoded: false))
        {
            return bundleCandidate.path(percentEncoded: false)
        }

        return nil
    }
}

private struct ExtractedTweetData {
    let text: String
    let imageURL: String?
    let fallbackTitle: String?
}

private enum TwitterTweetExtractor {
    private static let maxAttempts = 4

    static func extractTweet(tweetURL: String, actionbookBinPath: String, settleSeconds: Int) async -> ExtractedTweetData? {
        let binPath = actionbookBinPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !binPath.isEmpty else { return nil }
        let settle = max(1, settleSeconds)
        var debugLines: [String] = []
        debugLines.append("extract start: \(tweetURL)")
        for _ in 0..<maxAttempts {
            guard let scriptPath = scriptPath() else {
                storeDebugLog("extract failed: missing scripts/twitter_tweet_extract.sh")
                return nil
            }
            let command = "ACTIONBOOK_BIN=\(shellSingleQuote(binPath)) TWITTER_TWEET_SETTLE_SECONDS=\(settle) sh \(shellSingleQuote(scriptPath)) \(shellSingleQuote(tweetURL))"
            guard let output = await runShell(command: command) else {
                debugLines.append("attempt failed: script run")
                try? await Task.sleep(nanoseconds: 900_000_000)
                continue
            }
            let jsonString = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = jsonString.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                debugLines.append("attempt failed: json parse")
                try? await Task.sleep(nanoseconds: 900_000_000)
                continue
            }

            let text = ((obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let imageURLRaw = ((obj["image_url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let titleRaw = ((obj["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            debugLines.append("attempt ok: text=\(text.count) media=\(imageURLRaw.isEmpty ? 0 : 1)")
            if !text.isEmpty || !imageURLRaw.isEmpty {
                storeDebugLog(debugLines.joined(separator: "\n"))
                return ExtractedTweetData(
                    text: text,
                    imageURL: imageURLRaw.isEmpty ? nil : imageURLRaw,
                    fallbackTitle: titleRaw.isEmpty ? nil : titleRaw
                )
            }

            debugLines.append("attempt empty payload")
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        storeDebugLog(debugLines.joined(separator: "\n"))
        return nil
    }

    private static func runShell(command: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            process.terminationHandler = { proc in
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: String(data: outData, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func scriptPath() -> String? {
        let fm = FileManager.default
        let paths = [
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("scripts/twitter_tweet_extract.sh")
                .path(percentEncoded: false),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/twitter_tweet_extract.sh")
                .path(percentEncoded: false),
            "/Users/shadow/Documents/code/notnow/scripts/twitter_tweet_extract.sh",
        ]
        for p in paths where fm.fileExists(atPath: p) { return p }
        return nil
    }

    private static func storeDebugLog(_ text: String) {
        UserDefaults.standard.set(text, forKey: "twitterLikes.lastExtractLog")
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let categories: [Category]

    @AppStorage("accentTheme") private var accentThemeName = "dark"

    @AppStorage("ai.enabled") private var aiEnabled = false
    @AppStorage("ai.apiURL") private var aiAPIURL = ""
    @AppStorage("ai.apiKey") private var aiAPIKey = ""
    @AppStorage("ai.model") private var aiModel = ""
    @AppStorage("twitterLikes.enabled") private var twitterLikesEnabled = false
    @AppStorage("twitterLikes.binPath") private var twitterLikesBinPath = ""
    @AppStorage("twitterLikes.likesURL") private var twitterLikesURL = ""
    @AppStorage("twitterLikes.maxFetchCount") private var twitterLikesMaxFetchCount = 80
    @AppStorage("twitterLikes.tweetSettleSeconds") private var twitterLikesTweetSettleSeconds = 8
    @AppStorage("link.clickAction") private var linkClickAction = ClickAction.browser.rawValue
    @AppStorage("link.cmdClickAction") private var linkCmdClickAction = ClickAction.edit.rawValue
    @AppStorage("link.clickScript") private var linkClickScript = ""
    @AppStorage("link.cmdClickScript") private var linkCmdClickScript = ""
    @AppStorage("snippet.clickAction") private var snippetClickAction = ClickAction.copy.rawValue
    @AppStorage("snippet.cmdClickAction") private var snippetCmdClickAction = ClickAction.edit.rawValue
    @AppStorage("snippet.clickScript") private var snippetClickScript = ""
    @AppStorage("snippet.cmdClickScript") private var snippetCmdClickScript = ""

    @State private var aiTesting = false
    @State private var aiTestMessage = ""
    @State private var aiTestLog = ""
    @State private var isExporting = false
    @State private var exportError: String?

    @State private var expandedSection: SettingsSectionID?

    private enum SettingsSectionID: Hashable {
        case twitter, clickAction, appearance, ai
    }

    private var currentTheme: AccentTheme {
        AccentTheme(rawValue: accentThemeName) ?? .dark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("设置")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(AppTheme.bgElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // MARK: 数据 (always visible)
                    dataSection

                    // MARK: Twitter Likes
                    settingsSection(
                        id: .twitter,
                        icon: "heart.circle",
                        title: "Twitter Likes",
                        badge: twitterLikesEnabled ? "已启用" : nil,
                        badgeColor: AppTheme.accentCyan
                    ) {
                        twitterSection
                    }

                    // MARK: 点击行为
                    settingsSection(
                        id: .clickAction,
                        icon: "cursorarrow.click.2",
                        title: "点击行为",
                        badge: clickActionSummary,
                        badgeColor: AppTheme.accent
                    ) {
                        clickActionSection
                    }

                    // MARK: 外观
                    settingsSection(
                        id: .appearance,
                        icon: "paintpalette",
                        title: "外观",
                        trailingAccessory: {
                            Circle()
                                .fill(currentTheme.color)
                                .frame(width: 12, height: 12)
                        }
                    ) {
                        appearanceSection
                    }

                    // MARK: AI
                    settingsSection(
                        id: .ai,
                        icon: "wand.and.stars",
                        title: "AI",
                        badge: aiEnabled ? "已启用" : nil,
                        badgeColor: AppTheme.accentGreen
                    ) {
                        aiSection
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(AppTheme.bgPrimary)
    }

    // MARK: - Collapsible Section

    @ViewBuilder
    private func settingsSection<Content: View>(
        id: SettingsSectionID,
        icon: String,
        title: String,
        badge: String? = nil,
        badgeColor: Color = AppTheme.accent,
        @ViewBuilder trailingAccessory: @escaping () -> some View = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = expandedSection == id

        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedSection = isExpanded ? nil : id
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(isExpanded ? AppTheme.accent : AppTheme.textTertiary)
                        .frame(width: 20)

                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.textPrimary)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(badgeColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    trailingAccessory()

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(AppTheme.bgInput.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isExpanded ? AppTheme.borderHover : AppTheme.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - 数据

    private var dataSection: some View {
        HStack(spacing: 12) {
            Button {
                isExporting = true
                exportError = nil
                let config = NotNowExportConfig(
                    accentTheme: accentThemeName,
                    aiEnabled: aiEnabled,
                    aiAPIURL: aiAPIURL,
                    aiAPIKey: aiAPIKey,
                    aiModel: aiModel
                )
                Task {
                    let result = await NotNowBackupService.export(
                        bookmarks: (try? modelContext.fetch(FetchDescriptor<Bookmark>())) ?? [],
                        categories: categories,
                        config: config
                    )
                    await MainActor.run {
                        isExporting = false
                        switch result {
                        case .success(let zipURL):
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = zipURL.lastPathComponent
                            panel.allowedContentTypes = [.zip]
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let dest = panel.url {
                                do {
                                    if FileManager.default.fileExists(atPath: dest.path) {
                                        try FileManager.default.removeItem(at: dest)
                                    }
                                    try FileManager.default.copyItem(at: zipURL, to: dest)
                                } catch {
                                    exportError = "保存失败：\(error.localizedDescription)"
                                }
                            }
                        case .failure(let err):
                            let msg: String
                            if case .writeFailed(let s) = err { msg = s }
                            else { msg = String(describing: err) }
                            exportError = msg
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text("导出数据与配置")
                }
                .ghostButtonStyle()
            }
            .buttonStyle(.plain)
            .disabled(isExporting)

            if let exportError {
                Text(exportError)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.accentPink)
            } else {
                Text("含书签、分类、封面及当前配置")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    // MARK: - Twitter Likes

    private var twitterSection: some View {
        Group {
            Toggle(isOn: $twitterLikesEnabled) {
                Text("启用 Twitter Likes 导入")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
                TextField("Actionbook BIN Path（绝对路径）", text: $twitterLikesBinPath)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
            }
            .darkTextField()

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
                TextField("Likes URL（例如：https://x.com/<user>/likes）", text: $twitterLikesURL)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }
            .darkTextField()

            HStack(spacing: 8) {
                Image(systemName: "number")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
                Text("每次获取上限")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                TextField("80", value: $twitterLikesMaxFetchCount, format: .number)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            .darkTextField()

            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
                Text("推文页面稳定等待(秒)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                TextField("8", value: $twitterLikesTweetSettleSeconds, format: .number)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            .darkTextField()

            Text("仅在启用后可导入；导入时只拉最新，命中库内已有链接即停止。")
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // MARK: - 点击行为

    private var clickActionSummary: String {
        let linkLabel = ClickAction(rawValue: linkClickAction)?.label ?? "浏览器打开"
        let snippetLabel = ClickAction(rawValue: snippetClickAction)?.label ?? "复制"
        return "链接:\(linkLabel) · Snippet:\(snippetLabel)"
    }

    private var clickActionSection: some View {
        Group {
            Text("链接类型")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            clickActionPicker(label: "点击", selection: $linkClickAction, scriptBinding: $linkClickScript)
            clickActionPicker(label: "⌘ 点击", selection: $linkCmdClickAction, scriptBinding: $linkCmdClickScript)

            Divider().background(AppTheme.borderSubtle)

            Text("Snippet 类型")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            clickActionPicker(label: "点击", selection: $snippetClickAction, scriptBinding: $snippetClickScript)
            clickActionPicker(label: "⌘ 点击", selection: $snippetCmdClickAction, scriptBinding: $snippetCmdClickScript)

            Text("自定义脚本使用 {TEXT} 作为占位符（链接为 URL，Snippet 为内容）")
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        let columns = [
            GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 8),
            GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 8),
            GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 8)
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(AccentTheme.allCases) { theme in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        accentThemeName = theme.rawValue
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.previewColor)
                                .frame(height: 34)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.gradient)
                                        .frame(height: 10)
                                        .padding(.horizontal, 10)
                                )
                            if currentTheme == theme {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.color, lineWidth: 2)
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: theme.icon)
                                .font(.system(size: 10))
                            Text(theme.label)
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(currentTheme == theme ? theme.color : AppTheme.textSecondary)
                        .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.bgElevated.opacity(currentTheme == theme ? 0.9 : 0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                currentTheme == theme ? theme.color.opacity(0.55) : AppTheme.borderSubtle,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(theme.label)
            }
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        Group {
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

            Text("密钥保存在本机 UserDefaults，仅供本应用访问你的自建 AI 服务。")
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
    }

    // MARK: - Helpers

    @ViewBuilder
    private func clickActionPicker(label: String, selection: Binding<String>, scriptBinding: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 50, alignment: .trailing)
            Picker("", selection: selection) {
                ForEach(ClickAction.allCases, id: \.rawValue) { action in
                    Text(action.label).tag(action.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }

        if selection.wrappedValue == ClickAction.script.rawValue {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
                TextField("脚本命令（如: open -a Safari {TEXT}）", text: scriptBinding)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
            }
            .darkTextField()
        }
    }
}
