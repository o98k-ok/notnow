import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct AddBookmarkSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @AppStorage("ai.enabled") private var aiEnabled = false

    @State private var url = ""
    @State private var title = ""
    @State private var desc = ""
    @State private var tagsText = ""
    @State private var notes = ""
    @State private var coverData: Data?
    @State private var coverURL: String?
    @State private var isFetching = false
    @State private var selectedCategoryID: UUID?
    @State private var metadataTask: Task<Void, Never>?
    @State private var coverTask: Task<Void, Never>?
    @State private var manualCoverOverride = false
    @State private var aiRefined = false
    @State private var kind: BookmarkKind = .link
    @State private var snippetContent = ""
    @State private var taskPriority: TaskPriority = .none
    @State private var taskDueDate: Date?
    @State private var showDueDatePicker = false
    @State private var apiMethod: HTTPMethod = .GET
    private struct APIKeyValueRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }
    @State private var apiHeaderRows: [APIKeyValueRow] = [APIKeyValueRow(key: "", value: "")]
    @State private var apiParamRows: [APIKeyValueRow] = [APIKeyValueRow(key: "", value: "")]
    @State private var apiBody = ""
    @State private var apiBodyType = "json"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sheetHeader(title: "添加书签", icon: "plus.circle.fill") {
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("类型")
                        Picker("", selection: $kind) {
                            Text("链接").tag(BookmarkKind.link)
                            Text("片段").tag(BookmarkKind.snippet)
                            Text("任务").tag(BookmarkKind.task)
                            Text("API").tag(BookmarkKind.api)
                        }
                        .pickerStyle(.segmented)
                    }

                    // URL Input (link always, task optional)
                    if kind == .link {
                        VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("链接")
                        HStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textTertiary)
                                TextField("https://...", text: $url)
                                    .textFieldStyle(.plain)
                                    .font(.subheadline)
                                    .onSubmit { fetchMetadata() }
                            }
                            .darkTextField()

                            Button { fetchMetadata() } label: {
                                Group {
                                    if isFetching {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.down.circle.fill")
                                    }
                                }
                                .frame(width: 36, height: 36)
                                .background(AppTheme.accent.opacity(0.15))
                                .foregroundStyle(AppTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(url.isEmpty || isFetching)
                        }
                    }
                    }

                    // Cover Section
                    if kind == .link {
                        coverSection
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            fieldLabel(kind == .task ? "任务标题" : "标题")
                            if aiEnabled && kind != .task {
                                if aiRefined {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("AI")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .foregroundStyle(AppTheme.accent)
                                    .background(AppTheme.accent.opacity(0.16))
                                    .clipShape(Capsule())
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10))
                                        .foregroundStyle(AppTheme.textTertiary)
                                }
                            }
                        }
                        TextField(kind == .task ? "输入任务标题" : "输入标题", text: $title)
                            .darkTextField()
                            .font(.subheadline)
                    }

                    // Task-specific fields
                    if kind == .task {
                        // Task description + AI 打标
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                fieldLabel("任务描述")
                                Spacer()
                                if aiEnabled {
                                    Button {
                                        refineTaskMetadata()
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isFetching {
                                                ProgressView()
                                                    .controlSize(.mini)
                                            } else {
                                                Image(systemName: "sparkles")
                                                    .font(.system(size: 11, weight: .medium))
                                            }
                                            Text("AI 打标")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(AppTheme.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
                                    .opacity(desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                                }
                            }
                            TextEditor(text: $desc)
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

                        // Priority
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("优先级")
                            Picker("", selection: $taskPriority) {
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
                                if let due = taskDueDate {
                                    DatePicker("", selection: Binding(
                                        get: { due },
                                        set: { taskDueDate = $0 }
                                    ), displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()

                                    Button {
                                        taskDueDate = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button {
                                        taskDueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
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

                        // Optional link
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("关联链接（可选）")
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textTertiary)
                                TextField("https://...", text: $url)
                                    .textFieldStyle(.plain)
                                    .font(.subheadline)
                            }
                            .darkTextField()
                        }
                    }

                    // Description (link & snippet only)
                    if kind != .task {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("描述")
                            TextField("输入描述", text: $desc)
                                .darkTextField()
                                .font(.subheadline)
                        }
                    }

                    if kind == .snippet {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                fieldLabel("内容")
                                Spacer()
                                if aiEnabled {
                                    Button {
                                        refineSnippetMetadata()
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isFetching {
                                                ProgressView()
                                                    .controlSize(.mini)
                                            } else {
                                                Image(systemName: "sparkles")
                                                    .font(.system(size: 11, weight: .medium))
                                            }
                                            Text("AI 打标")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(AppTheme.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(snippetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
                                    .opacity(snippetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                                }
                            }
                            TextEditor(text: $snippetContent)
                                .font(.system(.subheadline, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(10)
                                .frame(minHeight: 140)
                                .background(AppTheme.bgInput)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                                )
                        }


                    }

                    if kind == .api {
                        // URL
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("请求地址")
                            HStack(spacing: 8) {
                                Picker("", selection: $apiMethod) {
                                    ForEach(HTTPMethod.allCases, id: \.self) { m in
                                        Text(m.rawValue).tag(m)
                                    }
                                }
                                .frame(width: 90)

                                TextField("https://api.example.com/v1/users", text: $url)
                                    .textFieldStyle(.plain)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .darkTextField()
                            }
                        }

                        // Query Params
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("Query 参数")
                            ForEach(apiParamRows) { row in
                                HStack(spacing: 6) {
                                    TextField("Key", text: addBindingParamKey(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    TextField("Value", text: addBindingParamValue(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    Button {
                                        apiParamRows.removeAll { $0.id == row.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.accentPink)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Button {
                                apiParamRows.append(APIKeyValueRow(key: "", value: ""))
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("添加 Query 参数")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(AppTheme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }

                        // Headers
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("Headers")
                            ForEach(apiHeaderRows) { row in
                                HStack(spacing: 6) {
                                    TextField("Key", text: addBindingHeaderKey(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    TextField("Value", text: addBindingHeaderValue(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    Button {
                                        apiHeaderRows.removeAll { $0.id == row.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.accentPink)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Button {
                                apiHeaderRows.append(APIKeyValueRow(key: "", value: ""))
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("添加 Header")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(AppTheme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }

                        // Body
                        if apiMethod != .GET {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    fieldLabel("Body")
                                    Spacer()
                                    Picker("", selection: $apiBodyType) {
                                        Text("JSON").tag("json")
                                        Text("Form").tag("form")
                                        Text("Text").tag("text")
                                        Text("None").tag("none")
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 240)
                                    if apiBodyType == "json" {
                                        Button {
                                            formatAPIBodyAdd()
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: "arrow.triangle.2.circlepath")
                                                Text("Format JSON")
                                                    .font(.subheadline.weight(.medium))
                                            }
                                            .foregroundStyle(AppTheme.accent)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(AppTheme.accent.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                if apiBodyType != "none" {
                                    PlainTextEditor(
                                        text: $apiBody,
                                        minHeight: 100,
                                        font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                                    )
                                    .padding(10)
                                    .frame(minHeight: 100)
                                    .background(AppTheme.bgInput)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(AppTheme.borderSubtle, lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }

                    // API 类型：AI 打标
                    if kind == .api && aiEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                fieldLabel("AI")
                                Spacer()
                                Button {
                                    refineAPIMetadata()
                                } label: {
                                    HStack(spacing: 4) {
                                        if isFetching {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        Text("AI 打标")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(AppTheme.accent)
                                }
                                .buttonStyle(.plain)
                                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
                            }
                        }
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("分类")
                        Picker("", selection: $selectedCategoryID) {
                            Text("无分类").tag(nil as UUID?)
                            ForEach(categories) { cat in
                                Label(cat.name, systemImage: cat.icon).tag(cat.id as UUID?)
                            }
                        }
                        .labelsHidden()
                    }

                    // Tags
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("标签")
                        HStack(spacing: 8) {
                            Image(systemName: "tag")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textTertiary)
                            TextField("逗号分隔, 例如: swift, ios, 教程", text: $tagsText)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                        }
                        .darkTextField()
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("备注")
                        TextEditor(text: $notes)
                            .font(.subheadline)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 60)
                            .background(AppTheme.bgInput)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
                            )
                    }
                }
                .padding(24)
            }

            // Bottom actions
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .ghostButtonStyle()
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .accentButtonStyle()
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveButtonDisabled)
                    .opacity(saveButtonDisabled ? 0.5 : 1)
            }
            .padding(20)
            .background(AppTheme.bgSecondary.opacity(0.5))
        }
        .frame(minWidth: 540, minHeight: 520)
        .background(AppTheme.bgPrimary)
        .onAppear { pasteFromClipboard() }
        .onDisappear {
            metadataTask?.cancel()
            coverTask?.cancel()
        }
    }

    // MARK: - Cover Section

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel("封面")
                Spacer()
                if coverData != nil {
                    Button { removeCoverManually() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                            Text("移除")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.accentPink)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let coverData, let image = NSImage(data: coverData) {
                // Cover preview
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppTheme.borderSubtle, lineWidth: 1)
                        )

                    Button { pickImage() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            } else {
                // Upload area
                Button { pickImage() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3)
                            .foregroundStyle(AppTheme.textTertiary)
                        Text("点击选择封面图片")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textTertiary)
                        Text("自动获取链接时会尝试抓取 OG 封面")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textTertiary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
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

    // MARK: - Actions

    private func fetchMetadata() {
        guard kind == .link else { return }
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.hasPrefix("http://"), !normalized.hasPrefix("https://") {
            normalized = "https://\(normalized)"
            url = normalized
        }
        metadataTask?.cancel()
        coverTask?.cancel()
        manualCoverOverride = false
        aiRefined = false
        NSLog("[Add] fetchMetadata: %@", normalized)
        isFetching = true
        metadataTask = Task {
            let metadata = await MetadataService.shared.fetch(from: normalized, fetchImage: false)
            if Task.isCancelled { return }
            NSLog("[Add] metadata result: title=%@, image=%d bytes",
                  metadata.title ?? "nil", metadata.imageData?.count ?? 0)
            await MainActor.run {
                if Task.isCancelled { return }
                if title.isEmpty, let t = metadata.title { title = t }
                if desc.isEmpty, let d = metadata.description { desc = d }
                coverURL = metadata.imageURL
                isFetching = false
            }
            // AI refinement (optional)
            if aiEnabled {
                let original: (String, String) = await MainActor.run { (title, desc) }
                if let ai = await AIService.shared.refineTitleAndDescription(
                    for: normalized,
                    originalTitle: original.0,
                    originalDesc: original.1
                ) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        if Task.isCancelled { return }
                        var didChange = false
                        if let t = ai.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            title = t
                            didChange = true
                        }
                        if let d = ai.desc, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            desc = d
                            didChange = true
                        }
                        if let tagList = ai.tags, !tagList.isEmpty {
                            let normalizedTags = tagList
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            if !normalizedTags.isEmpty {
                                let existing =
                                    tagsText.split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                                var seen = Set<String>()
                                let combined = (existing + normalizedTags).filter { tag in
                                    let lower = tag.lowercased()
                                    if seen.contains(lower) { return false }
                                    seen.insert(lower)
                                    return true
                                }
                                tagsText = combined.joined(separator: ", ")
                            }
                        }
                        if didChange {
                            aiRefined = true
                        }
                    }
                }
            }
            if let imgURL = metadata.imageURL, !imgURL.isEmpty {
                coverTask = Task {
                    let imgData = await MetadataService.shared.fetchImageData(from: imgURL)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        if Task.isCancelled { return }
                        if !manualCoverOverride, url == normalized, coverData == nil, let imgData {
                            coverData = imgData
                        }
                    }
                }
            }
        }
    }

    private func refineSnippetMetadata() {
        let content = snippetContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        metadataTask?.cancel()
        aiRefined = false
        isFetching = true
        metadataTask = Task {
            let ai = await AIService.shared.refineSnippet(
                content: content,
                originalTitle: title, originalDesc: desc
            )
            if Task.isCancelled { return }
            await MainActor.run {
                if Task.isCancelled { return }
                isFetching = false
                guard let ai else { return }
                var didChange = false
                if let t = ai.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = t; didChange = true
                }
                if let d = ai.desc, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    desc = d; didChange = true
                }
                if let tagList = ai.tags, !tagList.isEmpty {
                    let normalizedTags = tagList
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !normalizedTags.isEmpty {
                        let existing = tagsText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        var seen = Set<String>()
                        let combined = (existing + normalizedTags).filter { tag in
                            let lower = tag.lowercased()
                            if seen.contains(lower) { return false }
                            seen.insert(lower)
                            return true
                        }
                        tagsText = combined.joined(separator: ", ")
                    }
                }
                if didChange { aiRefined = true }
            }
        }
    }

    private func refineTaskMetadata() {
        let content = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        metadataTask?.cancel()
        aiRefined = false
        isFetching = true
        metadataTask = Task {
            let ai = await AIService.shared.refineSnippet(
                content: content,
                originalTitle: title, originalDesc: desc
            )
            if Task.isCancelled { return }
            await MainActor.run {
                if Task.isCancelled { return }
                isFetching = false
                guard let ai else { return }
                var didChange = false
                if let t = ai.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = t; didChange = true
                }
                if let d = ai.desc, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    desc = d; didChange = true
                }
                if let tagList = ai.tags, !tagList.isEmpty {
                    let normalizedTags = tagList
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !normalizedTags.isEmpty {
                        let existing = tagsText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        var seen = Set<String>()
                        let combined = (existing + normalizedTags).filter { tag in
                            let lower = tag.lowercased()
                            if seen.contains(lower) { return false }
                            seen.insert(lower)
                            return true
                        }
                        tagsText = combined.joined(separator: ", ")
                    }
                }
                if didChange { aiRefined = true }
            }
        }
    }

    private func refineAPIMetadata() {
        guard kind == .api else { return }
        let urlToUse = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlToUse.isEmpty else { return }
        metadataTask?.cancel()
        aiRefined = false
        isFetching = true
        metadataTask = Task {
            let ai = await AIService.shared.refineAPI(
                url: urlToUse,
                method: apiMethod.rawValue,
                bodySnippet: apiBody.isEmpty ? nil : apiBody,
                originalTitle: title,
                originalDesc: desc
            )
            if Task.isCancelled { return }
            await MainActor.run {
                if Task.isCancelled { return }
                isFetching = false
                guard let ai else { return }
                var didChange = false
                if let t = ai.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = t
                    didChange = true
                }
                if let d = ai.desc, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    desc = d
                    didChange = true
                }
                if let tagList = ai.tags, !tagList.isEmpty {
                    let newTags = tagList
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !newTags.isEmpty {
                        let existing = tagsText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        var seen = Set<String>()
                        let combined = (existing + newTags).filter { tag in
                            let lower = tag.lowercased()
                            if seen.contains(lower) { return false }
                            seen.insert(lower)
                            return true
                        }
                        tagsText = combined.joined(separator: ", ")
                        didChange = true
                    }
                }
                if didChange { aiRefined = true }
            }
        }
    }

    private func addBindingHeaderKey(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiHeaderRows.first(where: { $0.id == row.id })?.key ?? "" },
            set: { newValue in
                if let i = apiHeaderRows.firstIndex(where: { $0.id == row.id }) {
                    apiHeaderRows[i].key = newValue
                }
            }
        )
    }

    private func addBindingHeaderValue(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiHeaderRows.first(where: { $0.id == row.id })?.value ?? "" },
            set: { newValue in
                if let i = apiHeaderRows.firstIndex(where: { $0.id == row.id }) {
                    apiHeaderRows[i].value = newValue
                }
            }
        )
    }

    private func addBindingParamKey(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiParamRows.first(where: { $0.id == row.id })?.key ?? "" },
            set: { newValue in
                if let i = apiParamRows.firstIndex(where: { $0.id == row.id }) {
                    apiParamRows[i].key = newValue
                }
            }
        )
    }

    private func addBindingParamValue(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiParamRows.first(where: { $0.id == row.id })?.value ?? "" },
            set: { newValue in
                if let i = apiParamRows.firstIndex(where: { $0.id == row.id }) {
                    apiParamRows[i].value = newValue
                }
            }
        )
    }

    /// 格式化 Body：空则写入空 JSON 模板，否则按 JSON 美化
    private func formatAPIBodyAdd() {
        let trimmed = apiBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apiBody = "{\n  \n}"
        } else if let formatted = APIService.formatJSON(apiBody) {
            apiBody = formatted
        }
    }

    private var saveButtonDisabled: Bool {
        switch kind {
        case .link:
            return url.isEmpty
        case .snippet:
            return snippetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .task:
            return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .api:
            return url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() {
        let tags =
            tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let finalURL: String = {
            if kind == .snippet {
                return "snippet://\(UUID().uuidString)"
            }
            if kind == .task {
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "task://\(UUID().uuidString)" : trimmed
            }
            return url
        }()
        let bookmark = Bookmark(
            url: finalURL, title: title, desc: desc,
            coverURL: coverURL, coverData: coverData,
            tags: tags, notes: notes
        )
        bookmark.bookmarkKind = kind
        if kind == .snippet {
            bookmark.snippetContent = snippetContent
        }
        if kind == .task {
            bookmark.resolvedTaskPriority = taskPriority
            bookmark.dueDate = taskDueDate
        }
        if kind == .api {
            bookmark.apiMethod = apiMethod.rawValue
            bookmark.apiBodyType = apiBodyType
            bookmark.apiBody = apiBody
            let headers = apiHeaderRows.filter { !$0.key.isEmpty }
            if !headers.isEmpty {
                let arr = headers.map { ["key": $0.key, "value": $0.value, "enabled": true] as [String: Any] }
                if let data = try? JSONSerialization.data(withJSONObject: arr),
                   let str = String(data: data, encoding: .utf8) {
                    bookmark.apiHeaders = str
                }
            }
            let params = apiParamRows.filter { !$0.key.isEmpty }
            if !params.isEmpty {
                let arr = params.map { ["key": $0.key, "value": $0.value, "enabled": true] as [String: Any] }
                if let data = try? JSONSerialization.data(withJSONObject: arr),
                   let str = String(data: data, encoding: .utf8) {
                    bookmark.apiQueryParams = str
                }
            }
        }
        bookmark.category = categories.first { $0.id == selectedCategoryID }
        modelContext.insert(bookmark)
        try? modelContext.save()
        NotificationCenter.default.post(name: .modelDataDidChange, object: nil)
        dismiss()
    }

    private func pasteFromClipboard() {
        guard kind == .link else { return }
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: content),
            parsed.scheme == "http" || parsed.scheme == "https"
        else { return }
        url = content
        fetchMetadata()
    }

    private func pickImage() {
        coverTask?.cancel()
        manualCoverOverride = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let fileURL = panel.url {
            coverData = try? Data(contentsOf: fileURL)
            coverURL = nil
        }
    }

    private func removeCoverManually() {
        coverTask?.cancel()
        manualCoverOverride = true
        coverData = nil
        coverURL = nil
    }
}

// MARK: - Shared Components

func sheetHeader(title: String, icon: String, onCancel: @escaping () -> Void) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon)
            .font(.title3)
            .foregroundStyle(AppTheme.accentGradient)
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(AppTheme.textPrimary)
        Spacer()
        Button { onCancel() } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 28, height: 28)
                .background(AppTheme.bgElevated)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
    .padding(20)
    .background(AppTheme.bgSecondary.opacity(0.5))
}

func fieldLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppTheme.textSecondary)
        .textCase(.uppercase)
}
