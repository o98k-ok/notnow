import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookmarkDetailSheet: View {
    @Bindable var bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) var categories: [Category]

    @State private var tagsText = ""
    @State private var showOpenWith = false
    @State private var isFetchingCover = false
    @State private var coverFetchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "编辑书签", icon: "pencil.circle.fill") {
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Cover management
                    if !bookmark.isSnippet && !bookmark.isTask {
                        coverManagement
                    }

                    // URL
                    if !bookmark.isSnippet && !bookmark.isTask {
                        VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("链接")
                        HStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textTertiary)
                                TextField("URL", text: $bookmark.url)
                                    .textFieldStyle(.plain)
                                    .font(.subheadline)
                            }
                            .darkTextField()

                            Button { OpenService.open(bookmark) } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 36, height: 36)
                                    .background(AppTheme.accent.opacity(0.15))
                                    .foregroundStyle(AppTheme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("标题")
                        TextField("标题", text: $bookmark.title)
                            .darkTextField()
                            .font(.subheadline)
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("描述")
                        TextField("描述", text: $bookmark.desc)
                            .darkTextField()
                            .font(.subheadline)
                    }

                    if bookmark.isSnippet {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("内容")
                            TextEditor(text: Binding(
                                get: { bookmark.snippetText },
                                set: { bookmark.snippetText = $0 }
                            ))
                                .font(.system(.subheadline, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(10)
                                .frame(minHeight: 180)
                                .background(AppTheme.bgInput)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                                )
                        }
                    }

                    if bookmark.isTask {
                        // Completion toggle
                        HStack(spacing: 12) {
                            statusToggle(
                                bookmark.taskCompleted ? "已完成" : "未完成",
                                icon: bookmark.taskCompleted ? "checkmark.circle.fill" : "circle",
                                isOn: Binding(
                                    get: { bookmark.taskCompleted },
                                    set: { newValue in
                                        bookmark.taskCompleted = newValue
                                        bookmark.updatedAt = Date()
                                    }
                                ),
                                color: .green
                            )

                            if let completedAt = bookmark.completedAt {
                                Text("完成于 \(completedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textTertiary)
                            }
                            Spacer()
                        }

                        // Priority
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("优先级")
                            Picker("", selection: Binding(
                                get: { bookmark.resolvedTaskPriority },
                                set: { newValue in
                                    bookmark.resolvedTaskPriority = newValue
                                    bookmark.updatedAt = Date()
                                }
                            )) {
                                ForEach(TaskPriority.allCases, id: \.rawValue) { p in
                                    Label(p.label, systemImage: p.icon).tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        // Due date
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("截止日期")
                            HStack(spacing: 8) {
                                if let due = bookmark.dueDate {
                                    DatePicker("", selection: Binding(
                                        get: { due },
                                        set: { bookmark.dueDate = $0; bookmark.updatedAt = Date() }
                                    ), displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()

                                    Button {
                                        bookmark.dueDate = nil
                                        bookmark.updatedAt = Date()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textTertiary)
                                    }
                                    .buttonStyle(.plain)

                                    if bookmark.isOverdue {
                                        Text("已逾期")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.red)
                                    }
                                } else {
                                    Button {
                                        bookmark.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                                        bookmark.updatedAt = Date()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "calendar.badge.plus")
                                            Text("设置截止日期")
                                        }
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AppTheme.accent)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(AppTheme.accent.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Task description
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("任务描述")
                            TextEditor(text: $bookmark.desc)
                                .font(.subheadline)
                                .scrollContentBackground(.hidden)
                                .padding(10)
                                .frame(minHeight: 100)
                                .background(AppTheme.bgInput)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                                )
                        }

                        // Optional link for task
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("关联链接")
                            HStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "link")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.textTertiary)
                                    TextField("https://...", text: $bookmark.url)
                                        .textFieldStyle(.plain)
                                        .font(.subheadline)
                                }
                                .darkTextField()

                                if !bookmark.url.hasPrefix("task://") {
                                    Button {
                                        if let url = URL(string: bookmark.url) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption.weight(.bold))
                                            .frame(width: 36, height: 36)
                                            .background(AppTheme.accent.opacity(0.15))
                                            .foregroundStyle(AppTheme.accent)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Tags
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("标签")
                        HStack(spacing: 8) {
                            Image(systemName: "tag")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textTertiary)
                            TextField("逗号分隔", text: $tagsText)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                                .onChange(of: tagsText) {
                                    bookmark.tags =
                                        tagsText.split(separator: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty }
                                }
                        }
                        .darkTextField()

                        // Tag preview
                        if !bookmark.tags.isEmpty {
                            FlowLayout(spacing: 4) {
                                ForEach(bookmark.tags, id: \.self) { tag in
                                    let color = TagColor.color(for: tag)
                                    Text(tag)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(color)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(color.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("备注")
                        TextEditor(text: $bookmark.notes)
                            .font(.subheadline)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 80)
                            .background(AppTheme.bgInput)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
                            )
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("分类")
                        Picker("", selection: Binding(
                            get: { bookmark.category?.id },
                            set: { newID in
                                bookmark.category = categories.first { $0.id == newID }
                                bookmark.updatedAt = Date()
                            }
                        )) {
                            Text("无分类").tag(nil as UUID?)
                            ForEach(categories) { cat in
                                Label(cat.name, systemImage: cat.icon).tag(cat.id as UUID?)
                            }
                        }
                        .labelsHidden()
                    }

                    // Status toggles
                    HStack(spacing: 12) {
                        statusToggle(
                            "收藏", icon: "star.fill",
                            isOn: Binding(
                                get: { bookmark.isFavorite },
                                set: { newValue in
                                    bookmark.isFavorite = newValue
                                    bookmark.updatedAt = Date()
                                    toggleFavoriteCategory(for: bookmark, isFavorite: newValue)
                                }
                            ), color: .yellow
                        )
                    }

                    // Open with section
                    openWithSection
                }
                .padding(24)
            }

            // Bottom
            HStack {
                Button { deleteBookmark() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("删除")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.accentPink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(AppTheme.accentPink.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Spacer()

                Button("完成") { dismiss() }
                    .accentButtonStyle()
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(AppTheme.bgSecondary.opacity(0.5))
        }
        .frame(minWidth: 560, minHeight: 640)
        .background(AppTheme.bgPrimary)
        .onAppear { tagsText = bookmark.tags.joined(separator: ", ") }
        .onChange(of: bookmark.title) { bookmark.updatedAt = Date() }
        .onChange(of: bookmark.desc) { bookmark.updatedAt = Date() }
        .onChange(of: bookmark.snippetText) { bookmark.updatedAt = Date() }
        .onChange(of: bookmark.notes) { bookmark.updatedAt = Date() }
        .onDisappear {
            coverFetchTask?.cancel()
            NotificationCenter.default.post(name: .modelDataDidChange, object: nil)
        }
        .sheet(isPresented: $showOpenWith) {
            OpenWithSheet(bookmark: bookmark)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: - Cover Management

    private var coverManagement: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel("封面")
                Spacer()
                HStack(spacing: 8) {
                    // 获取方式菜单
                    coverFetchMenu

                    // 上传本地文件
                    Button { pickImage() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.badge.plus")
                            Text("本地文件")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.accentCyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.accentCyan.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    if bookmark.coverData != nil {
                        Button { removeCover() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark")
                                Text("移除")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.accentPink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.accentPink.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let data = bookmark.coverData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppTheme.borderSubtle, lineWidth: 1)
                    )
                    .allowsHitTesting(false)
            } else {
                // Placeholder
                Button { pickImage() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(AppTheme.textTertiary)
                        Text("无封面 — 点击选择获取方式或上传本地文件")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                    .background(AppTheme.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppTheme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [6]))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 封面获取方式菜单
    private var coverFetchMenu: some View {
        Menu {
            Button {
                refetchCover(mode: .api)
            } label: {
                Label("API 获取", systemImage: "network")
            }
            
            Divider()
            
            Button {
                refetchCover(mode: .actionbookEval)
            } label: {
                Label("Actionbook 提取", systemImage: "doc.text.magnifyingglass")
            }
            
            Button {
                refetchCover(mode: .actionbookScreenshot)
            } label: {
                Label("Actionbook 截图", systemImage: "photo.on.rectangle.angled")
            }
        } label: {
            HStack(spacing: 4) {
                if isFetchingCover {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("获取")
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.accent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isFetchingCover)
    }
    
    /// 封面获取方式
    private enum CoverFetchMode {
        case api
        case actionbookEval
        case actionbookScreenshot
    }

    // MARK: - Open With

    private var openWithSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("自定义脚本")
                Spacer()
                Button { showOpenWith = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                        Text("配置")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                if let script = bookmark.openWithScript, !script.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal.fill")
                            .font(.caption2)
                        Text(script)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                    .foregroundStyle(AppTheme.accentGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.accentGreen.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption2)
                        Text("使用全局设置")
                            .font(.caption)
                    }
                    .foregroundStyle(AppTheme.textTertiary)
                }
            }
        }
        .padding(14)
        .background(AppTheme.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func statusToggle(_ label: String, icon: String, isOn: Binding<Bool>, color: Color)
        -> some View
    {
        Button {
            isOn.wrappedValue.toggle()
            bookmark.updatedAt = Date()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? icon : icon.replacingOccurrences(of: ".fill", with: ""))
                    .font(.caption)
                    .foregroundStyle(isOn.wrappedValue ? color : AppTheme.textTertiary)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOn.wrappedValue ? AppTheme.textPrimary : AppTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isOn.wrappedValue ? color.opacity(0.12) : AppTheme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isOn.wrappedValue ? color.opacity(0.3) : AppTheme.borderSubtle,
                        lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func refetchCover(mode: CoverFetchMode) {
        guard !bookmark.url.isEmpty else { return }
        coverFetchTask?.cancel()
        isFetchingCover = true
        let currentURL = bookmark.url
        coverFetchTask = Task {
            var imageData: Data?
            var imageURL: String?
            
            switch mode {
            case .api:
                // 方式1: API 获取
                let metadata = await MetadataService.shared.fetch(from: currentURL, fetchImage: false)
                imageURL = metadata.imageURL
                if let url = imageURL, !url.isEmpty {
                    imageData = await MetadataService.shared.fetchImageData(from: url)
                }
                
            case .actionbookEval:
                // 方式2: Actionbook 提取
                let metadata = await ActionbookCoverService.shared.fetchWithEval(from: currentURL)
                imageURL = metadata.imageURL
                imageData = metadata.imageData
                
            case .actionbookScreenshot:
                // 方式3: Actionbook 截图
                let metadata = await ActionbookCoverService.shared.fetchWithScreenshot(from: currentURL)
                imageData = metadata.imageData
            }
            
            if Task.isCancelled { return }
            await MainActor.run {
                if Task.isCancelled || bookmark.url != currentURL { return }
                if let data = imageData {
                    bookmark.coverData = data
                    bookmark.coverURL = imageURL
                    bookmark.updatedAt = Date()
                }
                isFetchingCover = false
            }
        }
    }

    private func pickImage() {
        coverFetchTask?.cancel()
        isFetchingCover = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let fileURL = panel.url {
            bookmark.coverData = try? Data(contentsOf: fileURL)
            bookmark.coverURL = nil
            bookmark.updatedAt = Date()
        }
    }

    private func removeCover() {
        coverFetchTask?.cancel()
        isFetchingCover = false
        bookmark.coverData = nil
        bookmark.coverURL = nil
        bookmark.updatedAt = Date()
    }

    private func deleteBookmark() {
        bookmark.modelContext?.delete(bookmark)
        dismiss()
    }

    private func toggleFavoriteCategory(for bookmark: Bookmark, isFavorite: Bool) {
        guard let modelContext = bookmark.modelContext else { return }
        
        // 查找或创建收藏分类
        let fetchDescriptor = FetchDescriptor<Category>()
        let allCategories = (try? modelContext.fetch(fetchDescriptor)) ?? []
        
        let favoriteCategory: Category
        if let existing = allCategories.first(where: { $0.name == "收藏" }) {
            favoriteCategory = existing
        } else {
            favoriteCategory = Category(
                name: "收藏",
                icon: "star.fill",
                colorHex: 0xFFD700, // 金色
                sortOrder: -1
            )
            modelContext.insert(favoriteCategory)
        }
        
        // 更新书签分类
        if isFavorite {
            bookmark.category = favoriteCategory
        } else {
            // 如果当前在收藏分类中，移除分类
            if bookmark.category?.id == favoriteCategory.id {
                bookmark.category = nil
            }
        }
        
        try? modelContext.save()
    }
}
