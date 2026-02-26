import Foundation
import SwiftUI

/// Command Palette 中的条目类型
enum CommandPaletteItem: Identifiable, Hashable {
    case bookmark(Bookmark)
    case category(Category)
    case action(ActionItem)
    
    var id: String {
        switch self {
        case .bookmark(let bm): "bookmark-\(bm.id.uuidString)"
        case .category(let cat): "category-\(cat.id.uuidString)"
        case .action(let action): "action-\(action.id)"
        }
    }
    
    /// 用于排序和比较的标题
    var title: String {
        switch self {
        case .bookmark(let bm): bm.title.isEmpty ? bm.domain : bm.title
        case .category(let cat): cat.name
        case .action(let action): action.title
        }
    }
    
    /// 副标题或描述
    var subtitle: String {
        switch self {
        case .bookmark(let bm):
            if bm.title.isEmpty {
                return bm.url
            }
            return bm.domain
        case .category:
            return "分类"
        case .action(let action):
            return action.subtitle
        }
    }
    
    /// 图标名称
    var icon: String {
        switch self {
        case .bookmark(let bm):
            if bm.isFavorite { return "heart.fill" }
            if bm.isRead { return "checkmark.circle" }
            return "bookmark"
        case .category(let cat):
            return cat.icon
        case .action(let action):
            return action.icon
        }
    }
    
    /// 快捷键显示
    var shortcut: String? {
        switch self {
        case .action(let action):
            return action.shortcut
        default:
            return nil
        }
    }
    
    /// 用于UI的颜色
    var color: Color? {
        switch self {
        case .category(let cat):
            return cat.color
        default:
            return nil
        }
    }
}

/// 快捷操作项
struct ActionItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}

// 使 ActionItem 可哈希（仅基于 id）
extension ActionItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ActionItem, rhs: ActionItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Command Palette 状态管理
@MainActor
class CommandPaletteManager: ObservableObject {
    @Published var isPresented = false
    @Published var searchText = ""
    @Published var selectedIndex = 0
    @Published var items: [CommandPaletteItem] = []
    
    private var bookmarks: [Bookmark] = []
    private var categories: [Category] = []
    private var actionHandlers: [String: () -> Void] = [:]
    
    /// 初始化并设置数据源
    func configure(bookmarks: [Bookmark], categories: [Category]) {
        self.bookmarks = bookmarks
        self.categories = categories
        rebuildItems()
    }
    
    /// 重建所有条目
    func rebuildItems() {
        var allItems: [CommandPaletteItem] = []
        
        // 添加常用操作
        allItems.append(contentsOf: buildActions())
        
        // 添加分类
        let sortedCategories = categories.sorted { $0.sortOrder < $1.sortOrder }
        allItems.append(contentsOf: sortedCategories.map { .category($0) })
        
        // 添加书签（最近的在前）
        let sortedBookmarks = bookmarks.sorted { $0.createdAt > $1.createdAt }
        allItems.append(contentsOf: sortedBookmarks.map { .bookmark($0) })
        
        items = allItems
    }
    
    /// 过滤后的条目
    var filteredItems: [CommandPaletteItem] {
        if searchText.isEmpty {
            return items
        }
        
        let query = searchText.lowercased()
        return items.filter { item in
            let titleMatch = item.title.lowercased().contains(query)
            let subtitleMatch = item.subtitle.lowercased().contains(query)
            
            // 也搜索书签的标签
            var tagMatch = false
            if case .bookmark(let bm) = item {
                tagMatch = bm.tags.contains { $0.lowercased().contains(query) }
            }
            
            return titleMatch || subtitleMatch || tagMatch
        }
    }
    
    /// 执行选中的条目
    func executeSelected() {
        let filtered = filteredItems
        guard selectedIndex >= 0 && selectedIndex < filtered.count else { return }
        
        let item = filtered[selectedIndex]
        execute(item: item)
    }
    
    /// 执行指定条目
    func execute(item: CommandPaletteItem) {
        switch item {
        case .bookmark(let bm):
            OpenService.open(bm)
            close()
            
        case .category(let cat):
            // 通过通知让 ContentView 切换分类
            NotificationCenter.default.post(
                name: .selectCategory,
                object: cat.id
            )
            close()
            
        case .action(let action):
            action.action()
            close()
        }
    }
    
    /// 打开面板
    func open() {
        rebuildItems()
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
    
    /// 构建快捷操作
    private func buildActions() -> [CommandPaletteItem] {
        actionHandlers.removeAll()
        
        var actions: [CommandPaletteItem] = []
        
        // 新建书签
        let addAction = ActionItem(
            id: "add-bookmark",
            title: "新建书签",
            subtitle: "添加新的书签",
            icon: "plus.circle.fill",
            shortcut: "⌘N"
        ) {
            NotificationCenter.default.post(name: .addBookmark, object: nil)
        }
        actionHandlers[addAction.id] = addAction.action
        actions.append(.action(addAction))
        
        // 导入书签
        let importAction = ActionItem(
            id: "import",
            title: "导入书签",
            subtitle: "从 Chrome、GitHub 或备份导入",
            icon: "square.and.arrow.down.fill",
            shortcut: nil
        ) {
            NotificationCenter.default.post(name: .showImport, object: nil)
        }
        actionHandlers[importAction.id] = importAction.action
        actions.append(.action(importAction))
        
        // 设置
        let settingsAction = ActionItem(
            id: "settings",
            title: "偏好设置",
            subtitle: "应用设置和导出数据",
            icon: "gearshape.fill",
            shortcut: "⌘,"
        ) {
            NotificationCenter.default.post(name: .showSettings, object: nil)
        }
        actionHandlers[settingsAction.id] = settingsAction.action
        actions.append(.action(settingsAction))
        
        // 查看全部
        let allAction = ActionItem(
            id: "view-all",
            title: "查看全部书签",
            subtitle: "显示所有书签",
            icon: "square.grid.2x2",
            shortcut: nil
        ) {
            NotificationCenter.default.post(name: .selectSidebar, object: SidebarSelection.all)
        }
        actionHandlers[allAction.id] = allAction.action
        actions.append(.action(allAction))
        
        // 新建分类
        let addCategoryAction = ActionItem(
            id: "add-category",
            title: "新建分类",
            subtitle: "创建新的书签分类",
            icon: "folder.badge.plus",
            shortcut: nil
        ) {
            NotificationCenter.default.post(name: .showAddCategory, object: nil)
        }
        actionHandlers[addCategoryAction.id] = addCategoryAction.action
        actions.append(.action(addCategoryAction))
        
        return actions
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let selectCategory = Notification.Name("selectCategory")
    static let showImport = Notification.Name("showImport")
    static let selectSidebar = Notification.Name("selectSidebar")
    static let showAddCategory = Notification.Name("showAddCategory")
}
