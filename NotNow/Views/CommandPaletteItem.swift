import Foundation
import SwiftUI

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
        if bookmark.isFavorite { return "heart.fill" }
        if bookmark.isRead { return "checkmark.circle" }
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
    
    private var bookmarks: [Bookmark] = []
    
    /// 空搜索时显示的最新书签数量
    private let recentLimit = 15
    
    /// 初始化并设置数据源
    func configure(bookmarks: [Bookmark]) {
        self.bookmarks = bookmarks
    }
    
    /// 过滤后的条目
    var filteredItems: [CommandPaletteItem] {
        // 按创建时间倒序排列
        let sortedBookmarks = bookmarks.sorted { $0.createdAt > $1.createdAt }
        
        if searchText.isEmpty {
            // 没有输入时只显示最近的 n 条
            return sortedBookmarks.prefix(recentLimit).map { CommandPaletteItem(bookmark: $0) }
        }
        
        // 有输入时过滤
        let query = searchText.lowercased()
        let filtered = sortedBookmarks.filter { bm in
            let titleMatch = bm.title.lowercased().contains(query)
            let urlMatch = bm.url.lowercased().contains(query)
            let descMatch = bm.desc.lowercased().contains(query)
            let notesMatch = bm.notes.lowercased().contains(query)
            let domainMatch = bm.domain.lowercased().contains(query)
            let tagMatch = bm.tags.contains { $0.lowercased().contains(query) }
            let categoryMatch = bm.category?.name.lowercased().contains(query) ?? false
            
            return titleMatch || urlMatch || descMatch || notesMatch || domainMatch || tagMatch || categoryMatch
        }
        
        return filtered.map { CommandPaletteItem(bookmark: $0) }
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
