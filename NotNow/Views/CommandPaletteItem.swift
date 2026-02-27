import Combine
import Foundation
import SwiftUI

/// 分类过滤器选项
enum CategoryFilter: Equatable, Hashable {
    case all
    case category(UUID)
    case uncategorized
    
    var name: String {
        switch self {
        case .all: return "全部"
        case .uncategorized: return "未分类"
        case .category: return ""
        }
    }
    
    func matches(bookmark: Bookmark) -> Bool {
        switch self {
        case .all:
            return true
        case .uncategorized:
            return bookmark.category == nil
        case .category(let id):
            return bookmark.category?.id == id
        }
    }
}

/// Command Palette 中的条目 - 只包含书签
struct CommandPaletteItem: Identifiable, Hashable {
    let bookmark: Bookmark
    
    var id: String {
        "bookmark-\(bookmark.id.uuidString)"
    }
    
    /// 标题
    var title: String {
        bookmark.title.isEmpty ? bookmark.domain : bookmark.title
    }
    
    /// 副标题（域名或 URL）
    var subtitle: String {
        if bookmark.title.isEmpty {
            return bookmark.url
        }
        return bookmark.domain
    }
    
    /// 图标名称
    var icon: String {
        if bookmark.isFavorite { return "star.fill" }
        return "bookmark"
    }
    
    /// 分类颜色
    var color: Color? {
        bookmark.category?.color
    }
    
    /// 分类名称（用于显示）
    var categoryName: String? {
        bookmark.category?.name
    }
}

/// Command Palette 状态管理
@MainActor
class CommandPaletteManager: ObservableObject {
    @Published var isPresented = false
    @Published var searchText = ""
    @Published var selectedIndex = 0
    @Published var selectedCategoryFilter: CategoryFilter = .all
    @Published var categoryFilters: [CategoryFilter] = [.all]
    @Published private(set) var filteredItems: [CommandPaletteItem] = []
    
    private var bookmarks: [Bookmark] = []
    private var categories: [Category] = []
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    
    /// 空搜索时显示的最新书签数量
    private let recentLimit = 15
    
    nonisolated init() {
        // Debounce setup must be deferred to MainActor
        Task { @MainActor [weak self] in
            self?.setupDebounce()
        }
    }
    
    private func setupDebounce() {
        let normalizedSearchQuery = $searchText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()

        Publishers.CombineLatest(normalizedSearchQuery, $selectedCategoryFilter.removeDuplicates())
            .sink { [weak self] query, _ in
                self?.performSearch(searchQuery: query)
            }
            .store(in: &cancellables)
    }
    
    /// 在后台线程执行搜索，避免阻塞 UI
    private func performSearch(searchQuery: String? = nil) {
        // 取消之前的搜索任务
        searchTask?.cancel()
        
        let currentBookmarks = bookmarks
        let currentCategoryFilter = selectedCategoryFilter
        let currentSearchText = (searchQuery ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        
        searchTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // 在后台线程执行过滤
            let items = await Task.detached(priority: .userInitiated) { () -> [CommandPaletteItem] in
                // 先按分类过滤
                let categoryFiltered = currentBookmarks.filter { currentCategoryFilter.matches(bookmark: $0) }
                let sortedBookmarks = categoryFiltered.sorted { $0.createdAt > $1.createdAt }
                
                // 空搜索时显示最近的书签
                if currentSearchText.isEmpty {
                    return sortedBookmarks.prefix(self.recentLimit).map { CommandPaletteItem(bookmark: $0) }
                }
                
                // 执行搜索过滤
                let query = currentSearchText.lowercased()
                let filtered = sortedBookmarks.filter { bm in
                    // 快速路径：检查标题和 URL（最常见的搜索字段）
                    if bm.title.lowercased().contains(query) || bm.url.lowercased().contains(query) {
                        return true
                    }
                    // 慢速路径：检查其他字段
                    if bm.desc.lowercased().contains(query) ||
                       bm.notes.lowercased().contains(query) ||
                       bm.domain.lowercased().contains(query) {
                        return true
                    }
                    // 检查 snippetText（可能较长，最后检查）
                    if bm.snippetText.lowercased().contains(query) {
                        return true
                    }
                    // 检查标签
                    if bm.tags.contains(where: { $0.lowercased().contains(query) }) {
                        return true
                    }
                    // 检查分类名称
                    if let categoryName = bm.category?.name,
                       categoryName.lowercased().contains(query) {
                        return true
                    }
                    return false
                }
                
                return filtered.map { CommandPaletteItem(bookmark: $0) }
            }.value
            
            // 检查任务是否被取消
            guard !Task.isCancelled else { return }
            
            self.filteredItems = items
            // 重置选中索引
            self.selectedIndex = 0
        }
    }
    
    /// 初始化并设置数据源
    func configure(bookmarks: [Bookmark], categories: [Category]) {
        self.bookmarks = bookmarks
        self.categories = categories
        updateCategoryFilters()
        refreshFilteredItems()
    }
    
    /// 更新分类过滤器列表
    private func updateCategoryFilters() {
        var filters: [CategoryFilter] = [.all]
        
        // 添加已排序的分类
        let sortedCategories = categories.sorted { $0.sortOrder < $1.sortOrder }
        for category in sortedCategories {
            filters.append(.category(category.id))
        }
        
        // 如果有未分类的书签，添加未分类选项
        let hasUncategorized = bookmarks.contains { $0.category == nil }
        if hasUncategorized {
            filters.append(.uncategorized)
        }
        
        categoryFilters = filters
    }
    
    /// 获取分类名称
    func categoryName(for filter: CategoryFilter) -> String {
        switch filter {
        case .all:
            return "全部"
        case .uncategorized:
            return "未分类"
        case .category(let id):
            return categories.first { $0.id == id }?.name ?? "未知"
        }
    }
    
    /// 获取分类颜色
    func categoryColor(for filter: CategoryFilter) -> Color? {
        switch filter {
        case .all:
            return nil
        case .uncategorized:
            return AppTheme.textTertiary
        case .category(let id):
            return categories.first { $0.id == id }?.color
        }
    }
    
    /// 切换到下一个分类
    func selectNextCategory() {
        guard let currentIndex = categoryFilters.firstIndex(of: selectedCategoryFilter) else { return }
        let nextIndex = (currentIndex + 1) % categoryFilters.count
        selectedCategoryFilter = categoryFilters[nextIndex]
        selectedIndex = 0 // 重置选中项
    }
    
    /// 切换到上一个分类
    func selectPreviousCategory() {
        guard let currentIndex = categoryFilters.firstIndex(of: selectedCategoryFilter) else { return }
        let prevIndex = (currentIndex - 1 + categoryFilters.count) % categoryFilters.count
        selectedCategoryFilter = categoryFilters[prevIndex]
        selectedIndex = 0 // 重置选中项
    }
    
    /// 刷新过滤后的条目（直接调用，用于初始化等场景）
    private func refreshFilteredItems() {
        performSearch()
    }
    
    /// 执行选中的条目
    func executeSelected() {
        let items = filteredItems
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        
        let item = items[selectedIndex]
        OpenService.open(item.bookmark)
        close()
    }
    
    /// 执行指定条目
    func execute(item: CommandPaletteItem) {
        OpenService.open(item.bookmark)
        close()
    }
    
    /// 打开面板
    func open() {
        searchText = ""
        selectedIndex = 0
        selectedCategoryFilter = .all
        // 直接使用缓存数据快速显示，不触发完整搜索
        let sortedBookmarks = bookmarks.sorted { $0.createdAt > $1.createdAt }
        filteredItems = sortedBookmarks.prefix(recentLimit).map { CommandPaletteItem(bookmark: $0) }
        isPresented = true
    }
    
    deinit {
        searchTask?.cancel()
    }
    
    /// 关闭面板
    func close() {
        isPresented = false
    }
    
    /// 选择上一个
    func selectPrevious() {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }
    
    /// 选择下一个
    func selectNext() {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + 1) % count
    }
}
