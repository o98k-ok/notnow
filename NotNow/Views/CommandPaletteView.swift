import SwiftData
import SwiftUI

struct CommandPaletteView: View {
    @StateObject private var manager = CommandPaletteManager()
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    
    @FocusState private var isSearchFocused: Bool
    @Namespace private var animationNamespace
    
    var body: some View {
        ZStack {
            backgroundOverlay
            commandPaletteContent
        }
        .animation(.easeInOut(duration: 0.15), value: manager.isPresented)
        .onAppear(perform: setupNotifications)
        .onChange(of: bookmarks) { _, _ in handleDataChange() }
        .onChange(of: categories) { _, _ in handleDataChange() }
        .onChange(of: manager.isPresented) { _, isPresented in handlePresentationChange(isPresented: isPresented) }
    }
    
    // MARK: - View Components
    
    @ViewBuilder
    private var backgroundOverlay: some View {
        if manager.isPresented {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture { manager.close() }
        }
    }
    
    @ViewBuilder
    private var commandPaletteContent: some View {
        if manager.isPresented {
            VStack(spacing: 0) {
                searchBar
                resultsList
            }
            .frame(width: 600, height: 500)
            .background(paletteBackground)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }
    
    private var paletteBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(AppTheme.bgElevated)
            .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.borderHover, lineWidth: 1)
            )
    }
    
    // MARK: - 搜索栏
    
    private var searchBar: some View {
        HStack(spacing: 12) {
            searchIcon
            searchField
            clearButton
            shortcutHint
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AppTheme.bgSecondary)
    }
    
    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .font(.title3)
            .foregroundStyle(AppTheme.textTertiary)
    }
    
    private var searchField: some View {
        TextField("搜索书签、分类或命令...", text: $manager.searchText)
            .font(.title3.weight(.medium))
            .foregroundStyle(AppTheme.textPrimary)
            .focused($isSearchFocused)
            .textFieldStyle(.plain)
            .onSubmit { manager.executeSelected() }
    }
    
    @ViewBuilder
    private var clearButton: some View {
        if !manager.searchText.isEmpty {
            Button { manager.searchText = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var shortcutHint: some View {
        HStack(spacing: 4) {
            Text("↵")
            Text("打开")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(AppTheme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    // MARK: - 结果列表
    
    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    resultsContent
                }
                .padding(.vertical, 8)
            }
            .onChange(of: manager.selectedIndex) { _, newIndex in
                scrollToSelected(proxy: proxy, index: newIndex)
            }
        }
        .frame(minHeight: 100, maxHeight: 400)
        .background(AppTheme.bgPrimary)
    }
    
    @ViewBuilder
    private var resultsContent: some View {
        let items = manager.filteredItems
        
        if items.isEmpty {
            emptyState
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                CommandPaletteRow(
                    item: item,
                    isSelected: index == manager.selectedIndex,
                    namespace: animationNamespace
                )
                .id(item.id)
                .onTapGesture { handleItemTap(index: index, item: item) }
                .onHover { isHovered in handleItemHover(index: index, isHovered: isHovered) }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.textTertiary)
            Text("没有找到匹配的项目")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.top, 40)
    }
    
    // MARK: - Helper Methods
    
    private func handleDataChange() {
        if manager.isPresented {
            manager.rebuildItems()
        }
    }
    
    private func handlePresentationChange(isPresented: Bool) {
        if isPresented {
            manager.configure(bookmarks: bookmarks, categories: categories)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
    }
    
    private func handleItemTap(index: Int, item: CommandPaletteItem) {
        manager.selectedIndex = index
        manager.execute(item: item)
    }
    
    private func handleItemHover(index: Int, isHovered: Bool) {
        if isHovered {
            manager.selectedIndex = index
        }
    }
    
    private func scrollToSelected(proxy: ScrollViewProxy, index: Int) {
        let items = manager.filteredItems
        guard index >= 0 && index < items.count else { return }
        withAnimation(.easeInOut(duration: 0.1)) {
            proxy.scrollTo(items[index].id, anchor: .center)
        }
    }
    
    // MARK: - 通知处理
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .openCommandPalette,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                manager.open()
            }
        }
    }
}

// MARK: - 命令行项目视图

struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    var namespace: Namespace.ID
    
    var body: some View {
        HStack(spacing: 12) {
            iconView
            textContent
            Spacer()
            shortcutView
            selectionIndicator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
    }
    
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(iconBackgroundColor)
                .frame(width: 36, height: 36)
            
            Image(systemName: item.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
        }
    }
    
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
    }
    
    @ViewBuilder
    private var shortcutView: some View {
        if let shortcut = item.shortcut {
            Text(shortcut)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
    
    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .matchedGeometryEffect(id: "selection", in: namespace)
        }
    }
    
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? AppTheme.accent.opacity(0.15) : Color.clear)
    }
    
    private var iconBackgroundColor: Color {
        if isSelected {
            return AppTheme.accent.opacity(0.25)
        }
        if let color = item.color {
            return color.opacity(0.15)
        }
        return AppTheme.bgSecondary
    }
    
    private var iconColor: Color {
        if isSelected {
            return AppTheme.accent
        }
        if let color = item.color {
            return color
        }
        return AppTheme.textSecondary
    }
}

// MARK: - 键盘事件处理

struct CommandPaletteKeyboardHandler: NSViewRepresentable {
    @ObservedObject var manager: CommandPaletteManager
    
    func makeNSView(context: Context) -> NSView {
        let view = CommandPaletteKeyView()
        view.manager = manager
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CommandPaletteKeyView)?.manager = manager
    }
    
    class CommandPaletteKeyView: NSView {
        var manager: CommandPaletteManager?
        
        override var acceptsFirstResponder: Bool { true }
        
        override func keyDown(with event: NSEvent) {
            guard let manager = manager, manager.isPresented else {
                super.keyDown(with: event)
                return
            }
            
            switch event.keyCode {
            case 53: // Esc
                manager.close()
            case 126: // ↑
                manager.selectPrevious()
            case 125: // ↓
                manager.selectNext()
            case 36: // Return
                manager.executeSelected()
            default:
                super.keyDown(with: event)
            }
        }
    }
}

// Command Palette uses the notification defined in NotNowApp.swift
