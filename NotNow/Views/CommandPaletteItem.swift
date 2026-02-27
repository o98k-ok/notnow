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
    
    /// 空搜索时显示的最新书签数量
    private let recentLimit = 15
    
    nonisolated init() {
        // Debounce setup must be deferred to MainActor
        Task { @MainActor [weak self] in
            self?.setupDebounce()
        }
    }
    
    private func setupDebounce() {
        Publishers.CombineLatest($searchText, $selectedCategoryFilter)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshFilteredItems()
            }
            .store(in: &cancellables)
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
    
    /// 刷新过滤后的条目
    private func refreshFilteredItems() {
        let categoryFiltered = bookmarks.filter { selectedCategoryFilter.matches(bookmark: $0) }
        let sortedBookmarks = categoryFiltered.sorted { $0.createdAt > $1.createdAt }
        
        if searchText.isEmpty {
            filteredItems = sortedBookmarks.prefix(recentLimit).map { CommandPaletteItem(bookmark: $0) }
            return
        }
        
        let query = searchText.lowercased()
        let filtered = sortedBookmarks.filter { bm in
            bm.title.lowercased().contains(query)
                || bm.url.lowercased().contains(query)
                || bm.desc.lowercased().contains(query)
                || bm.notes.lowercased().contains(query)
                || bm.snippetText.lowercased().contains(query)
                || bm.domain.lowercased().contains(query)
                || bm.tags.contains { $0.lowercased().contains(query) }
                || bm.category?.name.lowercased().contains(query) ?? false
        }
        
        filteredItems = filtered.map { CommandPaletteItem(bookmark: $0) }
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
        refreshFilteredItems()
        isPresented = true
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
