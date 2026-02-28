import AppKit
import Foundation
import SwiftData
import SwiftUI

struct CommandPaletteView: View {
    @StateObject private var manager = CommandPaletteManager()
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    
    @State private var searchFocusRequest = 0
    @State private var keyboardMonitor: Any?
    @State private var openPaletteObserver: NSObjectProtocol?
    private let searchDebounceNanoseconds: UInt64 = 150_000_000
    
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
        .onAppear {
            setupNotifications()
            manager.configure(bookmarks: bookmarks, categories: categories)
        }
        .onDisappear {
            removeKeyboardMonitor()
            removeNotifications()
        }
        .onChange(of: bookmarks) { _, newBookmarks in
            manager.configure(bookmarks: newBookmarks, categories: categories)
        }
        .onChange(of: categories) { _, newCategories in
            manager.configure(bookmarks: bookmarks, categories: newCategories)
        }
        .onChange(of: manager.isPresented) { _, isPresented in
            handlePresentationChange(isPresented: isPresented)
        }
    }
    
    // MARK: - Command Palette
    
    private var commandPalette: some View {
        VStack(spacing: 0) {
            searchBar
            categorySelector
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
            
            CommandPaletteSearchField(
                text: $manager.searchText,
                focusRequest: searchFocusRequest,
                debounceNanoseconds: searchDebounceNanoseconds
            ) {
                manager.executeSelected()
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
    
    // MARK: - Category Selector
    
    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(manager.categoryFilters.enumerated()), id: \.element) { index, filter in
                    categoryButton(filter: filter, index: index)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(AppTheme.bgSecondary.opacity(0.5))
    }
    
    private func categoryButton(filter: CategoryFilter, index: Int) -> some View {
        let isSelected = manager.selectedCategoryFilter == filter
        let name = manager.categoryName(for: filter)
        let color = manager.categoryColor(for: filter)
        
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                manager.selectedCategoryFilter = filter
                manager.selectedIndex = 0
            }
        } label: {
            HStack(spacing: 4) {
                // 分类图标
                if filter == .all {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption2)
                } else if filter == .uncategorized {
                    Image(systemName: "tray")
                        .font(.caption2)
                } else {
                    Circle()
                        .fill(color ?? AppTheme.textSecondary)
                        .frame(width: 6, height: 6)
                }
                
                Text(name)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? (color ?? AppTheme.textPrimary) : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? (color?.opacity(0.15) ?? AppTheme.bgElevated) : AppTheme.bgElevated.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? (color?.opacity(0.5) ?? AppTheme.borderHover) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
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
            let categoryName = manager.categoryName(for: manager.selectedCategoryFilter)
            let prefix = manager.searchText.isEmpty ? "最近的" : "找到"
            Text("\(prefix) \(items.count) 个\(categoryName == "全部" ? "" : "于\(categoryName)")")
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
                    let categoryColor = manager.categoryColor(for: item)
                    Circle()
                        .fill(index == manager.selectedIndex ? AppTheme.accent.opacity(0.25) : (categoryColor?.opacity(0.15) ?? AppTheme.bgSecondary))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(index == manager.selectedIndex ? AppTheme.accent : (categoryColor ?? AppTheme.textSecondary))
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
                                .foregroundStyle(manager.categoryColor(for: item) ?? AppTheme.textSecondary)
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
            searchFocusRequest += 1
            setupKeyboardMonitor()
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
        guard openPaletteObserver == nil else { return }
        openPaletteObserver = NotificationCenter.default.addObserver(
            forName: .openCommandPalette, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                manager.open()
            }
        }
    }

    private func removeNotifications() {
        if let observer = openPaletteObserver {
            NotificationCenter.default.removeObserver(observer)
            openPaletteObserver = nil
        }
    }

    // MARK: - Keyboard Handling
    
    private func setupKeyboardMonitor() {
        removeKeyboardMonitor()
        
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.manager.isPresented else { return event }
            if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
               textView.hasMarkedText()
            {
                return event
            }
            
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
            case 48: // Tab - switch to next category
                if event.modifierFlags.contains(.shift) {
                    self.manager.selectPreviousCategory()
                } else {
                    self.manager.selectNextCategory()
                }
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

private struct CommandPaletteSearchField: View {
    @Binding var text: String
    let focusRequest: Int
    let debounceNanoseconds: UInt64
    let onSubmit: () -> Void

    @State private var draftText = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            TextField("搜索书签...", text: $draftText)
                .font(.title3.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .onSubmit { onSubmit() }
            if !draftText.isEmpty {
                Button {
                    draftText = ""
                    commitImmediately()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
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
            if draftText != text {
                draftText = text
            }
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
        }
    }

    private func commitImmediately() {
        debounceTask?.cancel()
        debounceTask = nil
        let pending = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending != text else { return }
        text = pending
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
