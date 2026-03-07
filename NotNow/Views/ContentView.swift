import AppKit
import SwiftData
import SwiftUI

enum SidebarSelection: Hashable, Sendable {
    case all
    case recommend
    case category(UUID)
    case uncategorized
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @AppStorage("accentTheme") private var accentThemeName = "dark"
    @AppStorage("sidebar.pinnedCategoryIDs") private var pinnedCategoryIDsRaw = ""
    @State private var selection: SidebarSelection = .recommend
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
    @State private var isScopeLoading = false
    @State private var scopeLoadGeneration = 0
    @State private var scopeLoadTask: Task<Void, Never>?
    @State private var sidebarCountsRefreshTask: Task<Void, Never>?
    @State private var categoryBookmarkCounts: [UUID: Int] = [:]
    @State private var uncategorizedBookmarkCount = 0
    @State private var columnBookmarksCache: [[Bookmark]] = []
    @State private var isBatchRetagging = false
    @State private var batchRetagProgressText = ""
    @State private var transientTip: String?
    @State private var tipDismissTask: Task<Void, Never>?
    @State private var recommendationQuery = "推荐我现在最值得看的内容"
    @State private var recommendationSummary = ""
    @State private var recommendedBookmarks: [Bookmark] = []
    @State private var isRecommending = false
    @State private var recommendationTask: Task<Void, Never>?
    @State private var recommendationProgressText = ""
    @State private var recommendationRunID = UUID()
    @State private var recommendationCompletedBatches = 0
    @State private var recommendationTotalBatches = 0
    @State private var recommendationFocusRequest = 0
    @State private var didRunInitialRecommendation = false
    private let searchDebounceNanoseconds: UInt64 = 450_000_000
    private let sidebarCountsDebounceNanoseconds: UInt64 = 180_000_000

    private enum RecommendationStage {
        case idle
        case localRanking
        case aiDeep
        case done
    }

    @State private var recommendationStage: RecommendationStage = .idle

    private struct BookmarkFetchResult {
        let bookmarks: [Bookmark]
        let totalFilteredCount: Int
    }

    private struct RecommendationSnapshot: Sendable {
        let id: UUID
        let url: String
        let title: String
        let desc: String
        let notes: String
        let tags: [String]
        let snippet: String
        let isFavorite: Bool
        let updatedAt: Date
        let createdAt: Date

        init(bookmark: Bookmark) {
            id = bookmark.id
            url = bookmark.url
            title = bookmark.title
            desc = bookmark.desc
            notes = bookmark.notes
            tags = bookmark.tags
            snippet = bookmark.snippetText
            isFavorite = bookmark.isFavorite
            updatedAt = bookmark.updatedAt
            createdAt = bookmark.createdAt
        }
    }

    private var currentTheme: AccentTheme {
        AccentTheme(rawValue: accentThemeName) ?? .dark
    }

    private var pinnedCategoryIDs: Set<UUID> {
        Set(
            pinnedCategoryIDsRaw
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        )
    }

    private var orderedCategories: [Category] {
        let pinned = pinnedCategoryIDs
        return categories.sorted { lhs, rhs in
            let lhsPinned = pinned.contains(lhs.id)
            let rhsPinned = pinned.contains(rhs.id)
            if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .modelDataDidChange)) { notification in
            handleModelDataDidChange(notification)
        }
        .onAppear {
            NSLog("[NotNow] app appeared")
            ensureFavoriteCategoryExists()
            cleanupPinnedCategoryIDs()
            refreshAll()
        }
        .onChange(of: showCategorySheet) {
            if !showCategorySheet {
                editingCategory = nil
                refreshAll()
            }
        }
        .onChange(of: selection) {
            if selection == .recommend {
                scopeLoadTask?.cancel()
                scopeLoadTask = nil
                isScopeLoading = false
                isLoadingMore = false
                if recommendationQuery.isEmpty {
                    recommendationQuery = "推荐我现在最值得看的内容"
                }
                recommendationFocusRequest += 1
                if !didRunInitialRecommendation {
                    didRunInitialRecommendation = true
                    refreshRecommendations()
                }
            } else {
                recommendationTask?.cancel()
                recommendationTask = nil
                isRecommending = false
                recommendationStage = .idle
                recommendationProgressText = ""
                recommendationCompletedBatches = 0
                recommendationTotalBatches = 0
                requestBookmarksReload(resetLimit: true)
            }
        }
        .onChange(of: columnCount) {
            columnBookmarksCache = splitIntoColumns(bookmarks: bookmarks, columns: columnCount)
        }
        .onDisappear {
            recommendationTask?.cancel()
            recommendationTask = nil
            isRecommending = false
            recommendationStage = .idle
            recommendationProgressText = ""
            recommendationCompletedBatches = 0
            recommendationTotalBatches = 0
            scopeLoadTask?.cancel()
            scopeLoadTask = nil
            sidebarCountsRefreshTask?.cancel()
            sidebarCountsRefreshTask = nil
            isScopeLoading = false
            isLoadingMore = false
        }
        .alert("导入结果", isPresented: $showImportAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(importAlertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBookmarkByID)) { notification in
            guard let targetID = notification.userInfo?["id"] as? UUID else { return }
            var descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.id == targetID })
            descriptor.fetchLimit = 1
            if let bookmark = try? modelContext.fetch(descriptor).first {
                selectedBookmark = bookmark
            }
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

            sidebarItem(
                label: "推荐", icon: "sparkles",
                isActive: selection == .recommend,
                count: selection == .recommend ? recommendedBookmarks.count : nil,
                accentColor: currentTheme.color
            ) { selection = .recommend }

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
                    .buttonStyle(.notNowPlainInteractive)
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
                .buttonStyle(.notNowPlainInteractive)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Category list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(orderedCategories) { cat in
                        let catCount = categoryBookmarkCounts[cat.id] ?? 0
                        sidebarItem(
                            label: cat.name, icon: cat.icon,
                            isActive: selection == .category(cat.id),
                            count: catCount,
                            accentColor: cat.color,
                            isPinned: pinnedCategoryIDs.contains(cat.id)
                        ) { selection = .category(cat.id) }
                            .contextMenu {
                                Button(pinnedCategoryIDs.contains(cat.id) ? "取消置顶" : "置顶") {
                                    toggleCategoryPin(cat)
                                }
                                Divider()
                                Button("编辑") {
                                    editingCategory = cat
                                    showCategorySheet = true
                                }
                                Button("删除", role: .destructive) {
                                    if selection == .category(cat.id) { selection = .all }
                                    let catID = cat.id
                                    let desc = FetchDescriptor<Bookmark>(predicate: #Predicate<Bookmark> { $0.category?.id == catID })
                                    if let affected = try? modelContext.fetch(desc) {
                                        for bm in affected { bm.category = nil }
                                    }
                                    modelContext.delete(cat)
                                    clearPinnedCategory(cat.id)
                                    try? modelContext.save()
                                    refreshAll()
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
        count: Int? = nil, accentColor: Color, isPinned: Bool = false,
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
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                }
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
        .buttonStyle(.notNowPlainInteractive)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            if selection == .recommend {
                recommendationTopBar
                recommendationGrid
            } else {
                topBar
                bookmarkGrid
            }
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
                    requestBookmarksReload(resetLimit: true)
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
                    .buttonStyle(.notNowPlainInteractive)
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
                    .buttonStyle(.notNowPlainInteractive)

                    Menu {
                        Button("移到未分类") { moveSelected(to: nil) }
                        if !categories.isEmpty {
                            Divider()
                            ForEach(orderedCategories) { cat in
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
                    .buttonStyle(.notNowPlainInteractive)
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
                    .buttonStyle(.notNowPlainInteractive)
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
                    .buttonStyle(.notNowPlainInteractive)
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
            .buttonStyle(.notNowPlainInteractive)
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
            .buttonStyle(.notNowPlainInteractive)
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
            .buttonStyle(.notNowPlainInteractive)

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
            .buttonStyle(.notNowPlainInteractive)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var recommendationTopBar: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                PromptEditor(
                    text: $recommendationQuery,
                    focusRequest: recommendationFocusRequest,
                    placeholder: "例如：推荐 github 里高质量、可直接上手的 Swift 项目"
                )

                HStack(spacing: 10) {
                    Label("自然语言推荐", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textTertiary)
                    Spacer()
                    Button {
                        didRunInitialRecommendation = true
                        refreshRecommendations()
                    } label: {
                        HStack(spacing: 6) {
                            if isRecommending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.trianglehead.clockwise")
                            }
                            Text("刷新推荐")
                        }
                        .ghostButtonStyle()
                    }
                    .buttonStyle(.notNowPlainInteractive)
                    .disabled(isRecommending)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .background(AppTheme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            )

            if !recommendationProgressText.isEmpty {
                Text(recommendationProgressText)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(maxWidth: 760, alignment: .leading)
            }

            if !recommendationSummary.isEmpty {
                Text(recommendationSummary)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    private var recommendationGrid: some View {
        let columns = [
            GridItem(.flexible(minimum: 220, maximum: 360), spacing: 14, alignment: .top),
            GridItem(.flexible(minimum: 220, maximum: 360), spacing: 14, alignment: .top),
            GridItem(.flexible(minimum: 220, maximum: 360), spacing: 14, alignment: .top),
            GridItem(.flexible(minimum: 220, maximum: 360), spacing: 14, alignment: .top),
        ]
        return GeometryReader { _ in
            ZStack {
                ScrollView {
                    if recommendedBookmarks.isEmpty {
                        recommendationEmptyState
                    } else {
                        let display = Array(recommendedBookmarks.prefix(recommendationDisplayLimit))

                        VStack {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(display, id: \.id) { bm in
                                    bookmarkCell(for: bm)
                                }
                            }
                            .frame(maxWidth: 1460, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 8)
                    }
                }
                .scrollIndicators(.visible)
                .allowsHitTesting(!shouldShowRecommendationPipeline)
                .blur(radius: shouldShowRecommendationPipeline ? 2 : 0)
                .opacity(shouldShowRecommendationPipeline ? 0.2 : 1)
                .animation(.easeOut(duration: 0.2), value: shouldShowRecommendationPipeline)

                if shouldShowRecommendationPipeline {
                    recommendationPipelineOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(2)
                }
            }
        }
    }

    private var recommendationEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isRecommending ? "hourglass" : "sparkles")
                .font(.title2)
                .foregroundStyle(AppTheme.textTertiary)
            Text(isRecommending
                 ? (recommendationProgressText.isEmpty ? "正在分析你的数据..." : recommendationProgressText)
                 : "输入你的需求，AI 会推荐最有价值的卡片")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(.horizontal, 24)
    }

    private var recommendationDisplayLimit: Int {
        8
    }

    private var shouldShowRecommendationPipeline: Bool {
        selection == .recommend && isRecommending
    }

    private var recommendationProgressFraction: Double {
        switch recommendationStage {
        case .idle:
            return 0
        case .localRanking:
            return 0.3
        case .aiDeep:
            guard recommendationTotalBatches > 0 else { return 0.72 }
            let progress = Double(recommendationCompletedBatches) / Double(recommendationTotalBatches)
            return min(1, max(0, progress))
        case .done:
            return 1
        }
    }

    private var recommendationPipelineTitle: String {
        switch recommendationStage {
        case .idle: "准备推荐"
        case .localRanking: "全量初排中"
        case .aiDeep: "AI 深度分析中"
        case .done: "推荐完成"
        }
    }

    private var recommendationPipelineSubtitle: String {
        if !recommendationProgressText.isEmpty {
            return recommendationProgressText
        }
        switch recommendationStage {
        case .idle:
            return "正在准备推荐流程"
        case .localRanking:
            return "正在覆盖全部卡片并计算基础相关度"
        case .aiDeep:
            return "正在进行多轮筛选与精排"
        case .done:
            return "推荐结果已生成"
        }
    }

    private var recommendationPipelineOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(currentTheme.color)
                    Text("正在生成推荐")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }

                recommendationStepIndicator
                recommendationProgressBar

                Text(recommendationPipelineTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(recommendationPipelineSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(AppTheme.bgInput.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            )
            .padding(.horizontal, 22)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var recommendationStepIndicator: some View {
        HStack(spacing: 10) {
            recommendationStepBadge(
                title: "全量初排",
                isActive: recommendationStage == .localRanking,
                isCompleted: recommendationStage == .aiDeep || recommendationStage == .done
            )
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
            recommendationStepBadge(
                title: "AI 深度分析",
                isActive: recommendationStage == .aiDeep,
                isCompleted: recommendationStage == .done
            )
        }
    }

    private func recommendationStepBadge(title: String, isActive: Bool, isCompleted: Bool) -> some View {
        let tint: Color = isCompleted ? AppTheme.accentGreen : (isActive ? currentTheme.color : AppTheme.textTertiary)
        let bg: Color = isCompleted ? AppTheme.accentGreen.opacity(0.14) : (isActive ? currentTheme.color.opacity(0.14) : AppTheme.bgElevated)
        let icon = isCompleted ? "checkmark.circle.fill" : (isActive ? "hourglass" : "circle")
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bg)
        .clipShape(Capsule())
    }

    private var recommendationProgressBar: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.bgElevated)
                if recommendationStage == .localRanking {
                    TimelineView(.animation(minimumInterval: 0.03, paused: false)) { context in
                        let duration = 1.2
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: duration) / duration
                        let segment = max(52, width * 0.28)
                        let offset = ((width + segment) * phase) - segment
                        Capsule()
                            .fill(currentTheme.gradient)
                            .frame(width: segment)
                            .offset(x: offset)
                    }
                } else {
                    Capsule()
                        .fill(currentTheme.gradient)
                        .frame(width: width * recommendationProgressFraction)
                        .animation(.easeOut(duration: 0.25), value: recommendationProgressFraction)
                }
            }
        }
        .frame(height: 8)
    }

    private var topBarTitle: String {
        switch selection {
        case .all: "全部书签"
        case .recommend: "智能推荐"
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
        guard !isLoadingMore, !isScopeLoading, bookmarks.count < totalFilteredCount else { return }
        isLoadingMore = true
        currentFetchLimit += ContentView.pageSize
        requestBookmarksReload(resetLimit: false)
    }

    private var bookmarkGrid: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    if isScopeLoading && bookmarks.isEmpty {
                        loadingState
                    } else if bookmarks.isEmpty {
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
            if isScopeLoading || isLoadingMore {
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
                .buttonStyle(.notNowPlainInteractive)
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
                .buttonStyle(.notNowPlainInteractive)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("正在加载目录内容...")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textTertiary)
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
                Button("无分类") { moveBookmark(bm, to: nil) }
                Divider()
                ForEach(orderedCategories) { cat in
                    Button(cat.name) { moveBookmark(bm, to: cat) }
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
            deleteBookmark(bm)
        }
    }

    private func bookmarkCell(for bookmark: Bookmark) -> some View {
        Button {
            if isBatchMode {
                toggleSelection(for: bookmark.id)
            } else if !NSEvent.modifierFlags.contains(.command) {
                handleClickAction(for: bookmark, isCmdClick: false)
            }
        } label: {
            BookmarkCardView(bookmark: bookmark)
                .overlay(alignment: .topLeading) {
                    if isBatchMode {
                        batchCheckmark(for: bookmark.id)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.notNowPlainInteractive)
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

    private func savePinnedCategoryIDs(_ ids: Set<UUID>) {
        pinnedCategoryIDsRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private func clearPinnedCategory(_ id: UUID) {
        var ids = pinnedCategoryIDs
        guard ids.remove(id) != nil else { return }
        savePinnedCategoryIDs(ids)
    }

    private func toggleCategoryPin(_ category: Category) {
        var ids = pinnedCategoryIDs
        if ids.contains(category.id) {
            ids.remove(category.id)
        } else {
            ids.insert(category.id)
        }
        savePinnedCategoryIDs(ids)
    }

    private func cleanupPinnedCategoryIDs() {
        let validIDs = Set(categories.map(\.id))
        let cleaned = pinnedCategoryIDs.intersection(validIDs)
        if cleaned != pinnedCategoryIDs {
            savePinnedCategoryIDs(cleaned)
        }
    }

    private func moveBookmark(_ bookmark: Bookmark, to category: Category?) {
        bookmark.category = category
        bookmark.updatedAt = Date()
        try? modelContext.save()
        refreshAll()
    }

    private func deleteBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
        try? modelContext.save()
        refreshAll()
    }

    private func retagSelected() {
        guard !selectedBookmarkIDs.isEmpty else { return }
        guard !isBatchRetagging else { return }
        let selected = bookmarks.filter { selectedBookmarkIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        // 分类统计
        let twitterLinks = selected.filter { isTwitterURL($0.url) && !$0.isSnippet }

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
                importAlertMessage = "批量重打标完成：共处理 \(stats.total) 条（Snippet: \(stats.snippets), Task: \(stats.tasks), API: \(stats.apis), 普通链接: \(stats.normalLinks), Twitter: \(stats.twitterLinks), 跳过: \(stats.skipped)）"
                showImportAlert = true
            }
        }
    }

    private func refreshAll() {
        cleanupPinnedCategoryIDs()
        scheduleSidebarCountsRefresh(immediate: true)
        if selection == .recommend {
            if !didRunInitialRecommendation {
                didRunInitialRecommendation = true
                refreshRecommendations()
            }
        } else {
            requestBookmarksReload(resetLimit: false)
        }
    }

    private func handleModelDataDidChange(_ notification: Notification) {
        let rawKind = notification.userInfo?[Notification.modelDataChangeKindKey] as? String
        let changeKind = ModelDataChangeKind(rawValue: rawKind ?? "") ?? .fullRefresh

        if changeKind == .fullRefresh {
            refreshAll()
            return
        }

        if changeKind == .categoryChanged {
            cleanupPinnedCategoryIDs()
        }

        scheduleSidebarCountsRefresh()
        if selection == .recommend {
            if didRunInitialRecommendation {
                refreshRecommendations()
            }
        } else {
            requestBookmarksReload(resetLimit: false)
        }
    }

    private func scheduleSidebarCountsRefresh(immediate: Bool = false) {
        sidebarCountsRefreshTask?.cancel()
        sidebarCountsRefreshTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: sidebarCountsDebounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            fetchSidebarCounts()
        }
    }

    private func fetchSidebarCounts() {
        let allCount = (try? modelContext.fetchCount(FetchDescriptor<Bookmark>())) ?? 0
        var counts = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, 0) })
        for category in categories {
            let categoryID = category.id
            let descriptor = FetchDescriptor<Bookmark>(
                predicate: #Predicate<Bookmark> { bm in
                    bm.category?.id == categoryID
                }
            )
            counts[categoryID] = (try? modelContext.fetchCount(descriptor)) ?? 0
        }
        let uncategorizedDescriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate<Bookmark> { bm in
                bm.category == nil
            }
        )
        let uncategorized = (try? modelContext.fetchCount(uncategorizedDescriptor)) ?? 0

        withAnimation(.easeOut(duration: 0.16)) {
            allBookmarkCount = allCount
            categoryBookmarkCounts = counts
            uncategorizedBookmarkCount = uncategorized
        }
    }

    private func requestBookmarksReload(resetLimit: Bool) {
        guard selection != .recommend else { return }

        if resetLimit {
            currentFetchLimit = ContentView.pageSize
            isLoadingMore = false
        }

        scopeLoadTask?.cancel()
        scopeLoadGeneration += 1
        let generation = scopeLoadGeneration
        let selectedScope = selection
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = currentFetchLimit
        isScopeLoading = true

        scopeLoadTask = Task(priority: .userInitiated) { @MainActor in
            await Task.yield()
            if Task.isCancelled { return }
            let result = fetchBookmarksResult(selection: selectedScope, query: query, limit: limit)
            if Task.isCancelled { return }
            guard generation == scopeLoadGeneration else { return }

            bookmarks = result.bookmarks
            totalFilteredCount = result.totalFilteredCount
            columnBookmarksCache = splitIntoColumns(bookmarks: result.bookmarks, columns: columnCount)
            selectedBookmarkIDs = selectedBookmarkIDs.intersection(Set(result.bookmarks.map(\.id)))
            isScopeLoading = false
            isLoadingMore = false
        }
    }

    @MainActor
    private func fetchBookmarksResult(
        selection: SidebarSelection,
        query: String,
        limit: Int
    ) -> BookmarkFetchResult {
        let scopePredicate = scopePredicate(for: selection)

        if query.isEmpty {
            var descriptor = FetchDescriptor<Bookmark>(
                predicate: scopePredicate,
                sortBy: [SortDescriptor(\Bookmark.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let rows = (try? modelContext.fetch(descriptor)) ?? []
            return BookmarkFetchResult(
                bookmarks: rows,
                totalFilteredCount: cachedScopeCount(for: selection)
            )
        }

        let descriptor = FetchDescriptor<Bookmark>(
            predicate: scopePredicate,
            sortBy: [SortDescriptor(\Bookmark.createdAt, order: .reverse)]
        )
        let scopedBookmarks = (try? modelContext.fetch(descriptor)) ?? []
        let filtered = scopedBookmarks.filter { bookmarkMatchesSearch($0, query: query) }
        return BookmarkFetchResult(
            bookmarks: Array(filtered.prefix(limit)),
            totalFilteredCount: filtered.count
        )
    }

    private func cachedScopeCount(for selection: SidebarSelection) -> Int {
        switch selection {
        case .all, .recommend:
            return allBookmarkCount
        case .category(let id):
            return categoryBookmarkCounts[id, default: 0]
        case .uncategorized:
            return uncategorizedBookmarkCount
        }
    }

    private func scopePredicate(for selection: SidebarSelection) -> Predicate<Bookmark> {
        switch selection {
        case .all:
            return #Predicate<Bookmark> { _ in true }
        case .recommend:
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

    private func refreshRecommendations() {
        recommendationTask?.cancel()
        recommendationTask = nil

        let query = recommendationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            isRecommending = false
            recommendationStage = .idle
            recommendationProgressText = ""
            recommendationCompletedBatches = 0
            recommendationTotalBatches = 0
            recommendationSummary = ""
            recommendedBookmarks = []
            return
        }

        let runID = UUID()
        recommendationRunID = runID
        recommendationTask = Task(priority: .userInitiated) { @MainActor in
            isRecommending = true
            recommendationStage = .localRanking
            recommendationProgressText = "阶段 1/2：全量初排中..."
            recommendationCompletedBatches = 0
            recommendationTotalBatches = 0
            recommendationSummary = ""

            let descriptor = FetchDescriptor<Bookmark>(
                sortBy: [SortDescriptor(\Bookmark.updatedAt, order: .reverse)]
            )
            let allBookmarks = (try? modelContext.fetch(descriptor)) ?? []

            guard !Task.isCancelled, runID == recommendationRunID else { return }
            guard !allBookmarks.isEmpty else {
                isRecommending = false
                recommendationStage = .idle
                recommendationProgressText = ""
                recommendationCompletedBatches = 0
                recommendationTotalBatches = 0
                recommendationSummary = "暂无可推荐的数据。"
                recommendedBookmarks = []
                return
            }

            let snapshots = allBookmarks.map(RecommendationSnapshot.init(bookmark:))
            let bookmarkByID = Dictionary(uniqueKeysWithValues: allBookmarks.map { ($0.id, $0) })
            let localRanked = await Task.detached(priority: .userInitiated) {
                ContentView.fallbackRecommendations(query: query, candidates: snapshots)
            }.value

            guard !Task.isCancelled, runID == recommendationRunID else { return }

            let limit = recommendationDisplayLimit
            let localDisplay = resolveSnapshots(localRanked, bookmarkByID: bookmarkByID, limit: limit)
            recommendedBookmarks = localDisplay
            recommendationSummary = "已完成全量初排，正在进行 AI 深度分析。"
            recommendationStage = .aiDeep
            recommendationProgressText = "阶段 2/2：AI 深度分析中..."

            let aiCandidates = localRanked.map { snapshot in
                AIRecommendationCandidate(
                    url: snapshot.url,
                    title: snapshot.title,
                    desc: snapshot.desc,
                    notes: snapshot.notes,
                    tags: snapshot.tags,
                    snippet: snapshot.snippet
                )
            }

            let aiResult = await AIService.shared.recommendBookmarksTournament(
                query: query,
                candidates: aiCandidates,
                maxResults: limit,
                chunkSize: 120,
                shortlistPerChunk: 12,
                concurrency: 3
            ) { completed, total in
                Task { @MainActor in
                    guard runID == recommendationRunID else { return }
                    recommendationCompletedBatches = max(0, completed)
                    recommendationTotalBatches = max(0, total)
                    recommendationProgressText = "阶段 2/2：AI 深度分析中（\(completed)/\(total)）"
                }
            }

            guard !Task.isCancelled, runID == recommendationRunID else { return }

            let snapshotByURLKey = Dictionary(grouping: localRanked, by: { urlDedupKey($0.url) })
            var finalSnapshots: [RecommendationSnapshot] = []
            var selectedIDs = Set<UUID>()

            if let aiResult {
                for url in aiResult.selectedURLs {
                    let key = urlDedupKey(url)
                    guard let matched = snapshotByURLKey[key]?.first else { continue }
                    if selectedIDs.insert(matched.id).inserted {
                        finalSnapshots.append(matched)
                        if finalSnapshots.count >= limit { break }
                    }
                }
            }

            if finalSnapshots.count < limit {
                for snapshot in localRanked {
                    guard selectedIDs.insert(snapshot.id).inserted else { continue }
                    finalSnapshots.append(snapshot)
                    if finalSnapshots.count >= limit { break }
                }
            }

            recommendedBookmarks = resolveSnapshots(finalSnapshots, bookmarkByID: bookmarkByID, limit: limit)
            recommendationSummary = aiResult?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "已基于全量书签完成推荐。"
            recommendationCompletedBatches = recommendationTotalBatches
            recommendationProgressText = "推荐完成"
            recommendationStage = .done
            isRecommending = false
        }
    }

    private func resolveSnapshots(
        _ snapshots: [RecommendationSnapshot],
        bookmarkByID: [UUID: Bookmark],
        limit: Int
    ) -> [Bookmark] {
        var result: [Bookmark] = []
        result.reserveCapacity(min(limit, snapshots.count))
        for snapshot in snapshots {
            guard let bookmark = bookmarkByID[snapshot.id] else { continue }
            result.append(bookmark)
            if result.count >= limit { break }
        }
        return result
    }

    nonisolated private static func fallbackRecommendations(
        query: String,
        candidates: [RecommendationSnapshot]
    ) -> [RecommendationSnapshot] {
        let cleanedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = cleanedQuery
            .split { $0 == " " || $0 == "," || $0 == "，" || $0 == "。" || $0 == ";" || $0 == "；" }
            .map(String.init)
            .filter { !$0.isEmpty }

        let now = Date()
        return candidates.sorted { lhs, rhs in
            recommendationScore(for: lhs, query: cleanedQuery, tokens: tokens, now: now)
                > recommendationScore(for: rhs, query: cleanedQuery, tokens: tokens, now: now)
        }
    }

    nonisolated private static func recommendationScore(
        for snapshot: RecommendationSnapshot,
        query: String,
        tokens: [String],
        now: Date
    ) -> Double {
        let title = snapshot.title.lowercased()
        let desc = snapshot.desc.lowercased()
        let notes = snapshot.notes.lowercased()
        let snippet = snapshot.snippet.lowercased()
        let url = snapshot.url.lowercased()
        let tags = snapshot.tags.map { $0.lowercased() }

        var score = 0.0
        if !query.isEmpty {
            if title.contains(query) { score += 8 }
            if desc.contains(query) { score += 6 }
            if notes.contains(query) { score += 4 }
            if snippet.contains(query) { score += 4 }
            if url.contains(query) { score += 3 }
            if tags.contains(where: { $0.contains(query) }) { score += 7 }
        }

        for token in tokens where token.count >= 2 {
            if title.contains(token) { score += 3 }
            if desc.contains(token) { score += 2 }
            if notes.contains(token) { score += 1.5 }
            if snippet.contains(token) { score += 1.5 }
            if tags.contains(where: { $0.contains(token) }) { score += 2.5 }
        }

        if snapshot.isFavorite { score += 1.8 }
        let recencyDays = max(0, now.timeIntervalSince(snapshot.updatedAt) / 86_400)
        score += max(0, 2.2 - min(recencyDays / 10, 2.2))
        return score
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
        } else if bm.isAPI {
            await retagAPIBookmark(bm)
            stats.apis += 1
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

    private func retagAPIBookmark(_ bm: Bookmark) async {
        let url = await MainActor.run { bm.url }
        let method = await MainActor.run { bm.apiMethod ?? "GET" }
        let bodySnippet = await MainActor.run { bm.apiBody }
        let originalTitle = await MainActor.run { bm.title }
        let originalDesc = await MainActor.run { bm.desc }

        if let ai = await AIService.shared.refineAPI(
            url: url,
            method: method,
            bodySnippet: bodySnippet,
            originalTitle: originalTitle,
            originalDesc: originalDesc
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
                        refreshAll()
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
                refreshAll()

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

private struct PromptEditor: View {
    @Binding var text: String
    let focusRequest: Int
    let placeholder: String

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 86, maxHeight: 122)

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(AppTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: focusRequest) {
            isFocused = true
        }
    }
}

private struct DebouncedSearchField: View {
    @Binding var text: String
    let focusRequest: Int
    let debounceNanoseconds: UInt64
    let placeholder: String
    let onDebouncedCommit: () -> Void

    @State private var draftText = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    init(
        text: Binding<String>,
        focusRequest: Int,
        debounceNanoseconds: UInt64,
        placeholder: String = "搜索书签...",
        onDebouncedCommit: @escaping () -> Void
    ) {
        _text = text
        self.focusRequest = focusRequest
        self.debounceNanoseconds = debounceNanoseconds
        self.placeholder = placeholder
        self.onDebouncedCommit = onDebouncedCommit
    }

    var body: some View {
        Group {
            TextField(placeholder, text: $draftText)
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
                .buttonStyle(.notNowPlainInteractive)
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
    var apis: Int = 0
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
                        .buttonStyle(.notNowPlainInteractive)
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
                            .buttonStyle(.notNowPlainInteractive)
                            if notNowZipURL != nil {
                                Button {
                                    notNowZipURL = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.textTertiary)
                                }
                                .buttonStyle(.notNowPlainInteractive)
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
                .buttonStyle(.notNowPlainInteractive)

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
                .buttonStyle(.notNowPlainInteractive)
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
                .buttonStyle(.notNowPlainInteractive)
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
            .buttonStyle(.notNowPlainInteractive)

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
            .buttonStyle(.notNowPlainInteractive)
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
                .buttonStyle(.notNowPlainInteractive)
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
                .buttonStyle(.notNowPlainInteractive)
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
