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
                    if !bookmark.isSnippet {
                        coverManagement
                    }

                    // URL
                    if !bookmark.isSnippet {
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
                    // Re-fetch cover
                    Button { refetchCover() } label: {
                        HStack(spacing: 4) {
                            if isFetchingCover {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("重新获取")
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

                    // Upload custom
                    Button { pickImage() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.badge.plus")
                            Text("自定义")
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
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppTheme.borderSubtle, lineWidth: 1)
                    )
            } else {
                // Placeholder
                Button { pickImage() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(AppTheme.textTertiary)
                        Text("无封面 — 点击上传或重新获取")
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

    private func refetchCover() {
        guard !bookmark.url.isEmpty else { return }
        coverFetchTask?.cancel()
        isFetchingCover = true
        let currentURL = bookmark.url
        coverFetchTask = Task {
            let metadata = await MetadataService.shared.fetch(from: currentURL, fetchImage: false)
            if Task.isCancelled { return }
            var imageData: Data?
            if let imageURL = metadata.imageURL, !imageURL.isEmpty {
                imageData = await MetadataService.shared.fetchImageData(from: imageURL)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                if Task.isCancelled || bookmark.url != currentURL { return }
                if let data = imageData { bookmark.coverData = data }
                bookmark.coverURL = metadata.imageURL
                bookmark.updatedAt = Date()
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
