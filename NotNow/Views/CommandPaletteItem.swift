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
}

/// Command Palette 中的条目 - 只包含书签
struct CommandPaletteItem: Identifiable, Hashable, Sendable {
    let bookmarkID: UUID
    let title: String
    let subtitle: String
    let icon: String
    let categoryID: UUID?
    let categoryName: String?
    
    var id: String {
        "bookmark-\(bookmarkID.uuidString)"
    }
}

private struct CommandPaletteSearchDocument: Sendable {
    let item: CommandPaletteItem
    let searchableText: String
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
    
    private var categories: [Category] = []
    private var categoryMap: [UUID: Category] = [:]
    private var bookmarkMap: [UUID: Bookmark] = [:]
    private var searchDocuments: [CommandPaletteSearchDocument] = []
    private var recentItems: [CommandPaletteItem] = []
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    
    /// 空搜索时显示的最新书签数量
    private let recentLimit = 15
    /// 有搜索词时最多展示的结果数，避免大结果集拖慢输入
    private let searchResultLimit = 120
    
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
    
    private nonisolated static func matches(filter: CategoryFilter, item: CommandPaletteItem) -> Bool {
        switch filter {
        case .all:
            return true
        case .uncategorized:
            return item.categoryID == nil
        case .category(let id):
            return item.categoryID == id
        }
    }

    /// 在后台线程执行搜索，避免阻塞 UI
    private func performSearch(searchQuery: String? = nil) {
        searchTask?.cancel()
        
        let currentDocuments = searchDocuments
        let currentCategoryFilter = selectedCategoryFilter
        let currentSearchText = (searchQuery ?? searchText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let recentLimit = recentLimit
        let searchResultLimit = searchResultLimit
        
        searchTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            let items = await Task.detached(priority: .userInitiated) {
                var results: [CommandPaletteItem] = []
                
                if currentSearchText.isEmpty {
                    for document in currentDocuments where CommandPaletteManager.matches(filter: currentCategoryFilter, item: document.item) {
                        results.append(document.item)
                        if results.count == recentLimit {
                            break
                        }
                    }
                    return results
                }
                
                for document in currentDocuments {
                    guard CommandPaletteManager.matches(filter: currentCategoryFilter, item: document.item) else {
                        continue
                    }
                    if document.searchableText.contains(currentSearchText) {
                        results.append(document.item)
                        if results.count == searchResultLimit {
                            break
                        }
                    }
                }
                
                return results
            }.value
            
            guard !Task.isCancelled else { return }
            
            self.filteredItems = items
            self.selectedIndex = 0
        }
    }
    
    /// 初始化并设置数据源
    func configure(bookmarks: [Bookmark], categories: [Category]) {
        self.categories = categories
        categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        bookmarkMap = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })
        
        searchDocuments = bookmarks.map { bookmark in
            let title = bookmark.title.isEmpty ? bookmark.domain : bookmark.title
            let subtitle = bookmark.title.isEmpty ? bookmark.url : bookmark.domain
            let categoryName = bookmark.category?.name
            
            let searchableText = [
                title,
                bookmark.url,
                bookmark.desc,
                bookmark.notes,
                bookmark.domain,
                bookmark.snippetText,
                bookmark.tags.joined(separator: " "),
                categoryName ?? ""
            ].joined(separator: "\n").lowercased()
            
            let item = CommandPaletteItem(
                bookmarkID: bookmark.id,
                title: title,
                subtitle: subtitle,
                icon: bookmark.isFavorite ? "star.fill" : "bookmark",
                categoryID: bookmark.category?.id,
                categoryName: categoryName
            )
            return CommandPaletteSearchDocument(item: item, searchableText: searchableText)
        }
        
        recentItems = Array(searchDocuments.prefix(recentLimit).map(\.item))
        updateCategoryFilters()
        
        if isPresented {
            refreshFilteredItems()
        } else {
            filteredItems = recentItems
            selectedIndex = 0
        }
    }
    
    /// 更新分类过滤器列表
    private func updateCategoryFilters() {
        var filters: [CategoryFilter] = [.all]
        
        let sortedCategories = categories.sorted { $0.sortOrder < $1.sortOrder }
        for category in sortedCategories {
            filters.append(.category(category.id))
        }
        
        let hasUncategorized = searchDocuments.contains { $0.item.categoryID == nil }
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
            return categoryMap[id]?.name ?? "未知"
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
            return categoryMap[id]?.color
        }
    }

    func categoryColor(for item: CommandPaletteItem) -> Color? {
        guard let categoryID = item.categoryID else { return nil }
        return categoryMap[categoryID]?.color
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
        guard let bookmark = bookmarkMap[item.bookmarkID] else { return }
        OpenService.open(bookmark)
        close()
    }
    
    /// 执行指定条目
    func execute(item: CommandPaletteItem) {
        guard let bookmark = bookmarkMap[item.bookmarkID] else { return }
        OpenService.open(bookmark)
        close()
    }
    
    /// 打开面板
    func open() {
        searchText = ""
        selectedIndex = 0
        selectedCategoryFilter = .all
        filteredItems = recentItems
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
