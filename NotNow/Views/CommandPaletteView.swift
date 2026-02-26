import SwiftData
import SwiftUI

struct CommandPaletteView: View {
    @StateObject private var manager = CommandPaletteManager()
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    
    @FocusState private var isSearchFocused: Bool
    @State private var keyboardMonitor: Any?
    
    var body: some View {
        ZStack {
            // 背景遮罩
            if manager.isPresented {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { manager.close() }
            }
            
            // 命令面板
            if manager.isPresented {
                commandPalette
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: manager.isPresented)
        .onAppear { setupNotifications() }
        .onChange(of: bookmarks) { _, newBookmarks in
            manager.configure(bookmarks: newBookmarks)
        }
        .onChange(of: manager.isPresented) { _, isPresented in
            handlePresentationChange(isPresented: isPresented)
        }
    }
    
    // MARK: - Command Palette
    
    private var commandPalette: some View {
        VStack(spacing: 0) {
            searchBar
            resultsList
        }
        .frame(width: 600)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.bgElevated)
                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderHover, lineWidth: 1)
        )
    }
    
    // MARK: - Search Bar
    
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(AppTheme.textTertiary)
            
            TextField("搜索书签...", text: $manager.searchText)
                .font(.title3.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
                .focused($isSearchFocused)
                .textFieldStyle(.plain)
                .onSubmit { manager.executeSelected() }
            
            if !manager.searchText.isEmpty {
                Button { manager.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            
            Text("↵")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AppTheme.bgSecondary)
    }
    
    // MARK: - Results List
    
    private var resultsList: some View {
        ScrollViewReader { proxy in
            List {
                let items = manager.filteredItems
                
                if items.isEmpty {
                    emptyState
                } else {
                    // Section header
                    sectionHeader(items: items)
                    
                    // Bookmark items
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        bookmarkRow(item: item, index: index)
                            .id(item.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(manager.filteredItems.count) * 56 + 40, 400))
            .background(AppTheme.bgPrimary)
            .onChange(of: manager.selectedIndex) { _, newIndex in
                scrollToSelected(proxy: proxy, index: newIndex)
            }
        }
    }
    
    private func sectionHeader(items: [CommandPaletteItem]) -> some View {
        HStack {
            Text(manager.searchText.isEmpty ? "最近的书签" : "找到 \(items.count) 个结果")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    
    private func bookmarkRow(item: CommandPaletteItem, index: Int) -> some View {
        Button {
            manager.execute(item: item)
        } label: {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(index == manager.selectedIndex ? AppTheme.accent.opacity(0.25) : (item.color?.opacity(0.15) ?? AppTheme.bgSecondary))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(index == manager.selectedIndex ? AppTheme.accent : (item.color ?? AppTheme.textSecondary))
                }
                
                // Title and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                        
                        if let categoryName = item.categoryName {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textTertiary)
                            
                            Text(categoryName)
                                .font(.caption)
                                .foregroundStyle(item.color ?? AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                
                Spacer()
                
                // Selection indicator
                if index == manager.selectedIndex {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(index == manager.selectedIndex ? AppTheme.accent.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.textTertiary)
            Text("没有找到匹配的书签")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.top, 40)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    
    // MARK: - Helper Methods
    
    private func handlePresentationChange(isPresented: Bool) {
        if isPresented {
            manager.configure(bookmarks: bookmarks)
            setupKeyboardMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        } else {
            removeKeyboardMonitor()
        }
    }
    
    private func scrollToSelected(proxy: ScrollViewProxy, index: Int) {
        let items = manager.filteredItems
        guard index >= 0 && index < items.count else { return }
        withAnimation(.easeInOut(duration: 0.1)) {
            proxy.scrollTo(items[index].id, anchor: .center)
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .openCommandPalette,
            object: nil,
            queue: .main
        ) { _ in
            manager.open()
        }
    }
    
    // MARK: - Keyboard Handling
    
    private func setupKeyboardMonitor() {
        removeKeyboardMonitor()
        
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.manager.isPresented else { return event }
            
            switch event.keyCode {
            case 53: // Esc
                self.manager.close()
                return nil
            case 126: // ↑
                self.manager.selectPrevious()
                return nil
            case 125: // ↓
                self.manager.selectNext()
                return nil
            case 36: // Return
                self.manager.executeSelected()
                return nil
            default:
                return event
            }
        }
    }
    
    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }
}

// MARK: - Command Palette Row (Compatibility)

struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    var namespace: Namespace.ID = Namespace().wrappedValue
    
    var body: some View {
        EmptyView()
    }
}
