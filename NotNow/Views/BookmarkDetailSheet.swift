import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct BookmarkDetailSheet: View {
    @Bindable var bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) var categories: [Category]

    @State private var tagsText = ""
    @State private var showOpenWith = false
    @State private var isFetchingCover = false
    @State private var coverFetchTask: Task<Void, Never>?
    /// 使用 Identifiable 行以便新增 header/param 时 SwiftUI 正确刷新
    private struct APIKeyValueRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }
    @State private var apiHeaderRows: [APIKeyValueRow] = []
    @State private var apiParamRows: [APIKeyValueRow] = []
    @State private var apiResponse: APIResponse?
    @State private var isExecutingAPI = false
    @State private var apiRequestTask: Task<Void, Never>?
    @AppStorage("ai.enabled") private var aiEnabled = false
    @State private var isRefiningAPI = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "编辑书签", icon: "pencil.circle.fill") {
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Cover management
                    if !bookmark.isSnippet && !bookmark.isTask && !bookmark.isAPI {
                        coverManagement
                    }

                    // URL
                    if !bookmark.isSnippet && !bookmark.isTask && !bookmark.isAPI {
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

                    if bookmark.isAPI {
                        // Method + URL
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("请求")
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(
                                    get: { bookmark.resolvedAPIMethod },
                                    set: { bookmark.resolvedAPIMethod = $0; bookmark.updatedAt = Date() }
                                )) {
                                    ForEach(HTTPMethod.allCases, id: \.self) { m in
                                        Text(m.rawValue).tag(m)
                                    }
                                }
                                .frame(width: 90)

                                TextField("https://...", text: $bookmark.url)
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
                                    TextField("Key", text: bindingParamKey(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    TextField("Value", text: bindingParamValue(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    Button {
                                        apiParamRows.removeAll { $0.id == row.id }
                                        syncParamsToBookmark()
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
                                syncParamsToBookmark()
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
                                    TextField("Key", text: bindingHeaderKey(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    TextField("Value", text: bindingHeaderValue(row))
                                        .textFieldStyle(.plain)
                                        .font(.system(.caption, design: .monospaced))
                                        .darkTextField()

                                    Button {
                                        apiHeaderRows.removeAll { $0.id == row.id }
                                        syncHeadersToBookmark()
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
                                syncHeadersToBookmark()
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
                        if bookmark.resolvedAPIMethod != .GET {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    fieldLabel("Body")
                                    Spacer()
                                    Picker("", selection: Binding(
                                        get: { bookmark.apiBodyType ?? "json" },
                                        set: { bookmark.apiBodyType = $0; bookmark.updatedAt = Date() }
                                    )) {
                                        Text("JSON").tag("json")
                                        Text("Form").tag("form")
                                        Text("Text").tag("text")
                                        Text("None").tag("none")
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 240)
                                    if (bookmark.apiBodyType ?? "json") == "json" {
                                        Button {
                                            formatAPIBodyDetail()
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
                                if (bookmark.apiBodyType ?? "json") != "none" {
                                    PlainTextEditor(
                                        text: Binding(
                                            get: { bookmark.apiBody ?? "" },
                                            set: { bookmark.apiBody = $0; bookmark.updatedAt = Date() }
                                        ),
                                        minHeight: 120,
                                        font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                                    )
                                    .padding(10)
                                    .frame(minHeight: 120)
                                    .background(AppTheme.bgInput)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(AppTheme.borderSubtle, lineWidth: 1)
                                    )
                                }
                            }
                        }

                        // Send button
                        HStack(spacing: 12) {
                            Button {
                                executeAPIRequest()
                            } label: {
                                HStack(spacing: 6) {
                                    if isExecutingAPI {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                    }
                                    Text("Send")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(AppTheme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(isExecutingAPI || bookmark.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button {
                                let curl = APIService.generateCURL(
                                    url: bookmark.url,
                                    method: bookmark.apiMethod ?? "GET",
                                    headers: bookmark.apiHeaders,
                                    queryParams: bookmark.apiQueryParams,
                                    body: bookmark.apiBody,
                                    bodyType: bookmark.apiBodyType
                                )
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(curl, forType: .string)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                    Text("复制 cURL")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(AppTheme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }

                        // Response area（固定高度，内部滚动，不把弹窗顶高）
                        if let resp = apiResponse {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    let statusColor: Color = resp.statusCode >= 200 && resp.statusCode < 300 ? .green :
                                        resp.statusCode >= 400 ? .red : .orange
                                    Text("\(resp.statusCode)")
                                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                        .foregroundStyle(statusColor)
                                    Text("·")
                                        .foregroundStyle(AppTheme.textTertiary)
                                    Text(String(format: "%.0fms", resp.duration * 1000))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(resp.body, forType: .string)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "doc.on.doc")
                                            Text("复制")
                                        }
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                ScrollView {
                                    Text(resp.body)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .textSelection(.enabled)
                                }
                                .frame(height: 240)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .background(AppTheme.bgInput)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.borderSubtle, lineWidth: 1)
                                )
                            }
                            .padding(14)
                            .background(AppTheme.bgInput.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
                            )
                        }
                    }

                    // API 类型：AI 打标
                    if bookmark.isAPI && aiEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                fieldLabel("AI")
                                Spacer()
                                Button {
                                    refineAPIMetadata()
                                } label: {
                                    HStack(spacing: 4) {
                                        if isRefiningAPI {
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
                                .disabled(isRefiningAPI || bookmark.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        .onAppear {
            tagsText = bookmark.tags.joined(separator: ", ")
            if bookmark.isAPI {
                let headerTuples = APIService.parseKeyValues(bookmark.apiHeaders)
                apiHeaderRows = headerTuples.map { APIKeyValueRow(key: $0.key, value: $0.value) }
                if apiHeaderRows.isEmpty { apiHeaderRows = [APIKeyValueRow(key: "", value: "")] }
                let paramTuples = APIService.parseKeyValues(bookmark.apiQueryParams)
                apiParamRows = paramTuples.map { APIKeyValueRow(key: $0.key, value: $0.value) }
                if apiParamRows.isEmpty { apiParamRows = [APIKeyValueRow(key: "", value: "")] }
            }
        }
        .onChange(of: bookmark.title) { bookmark.updatedAt = Date() }
        .onChange(of: bookmark.desc) { bookmark.updatedAt = Date() }
        .onChange(of: bookmark.snippetText) { bookmark.updatedAt = Date() }
        .onChange(of: bookmark.notes) { bookmark.updatedAt = Date() }
        .onDisappear {
            apiRequestTask?.cancel()
            coverFetchTask?.cancel()
            NotificationCenter.default.post(name: .modelDataDidChange, object: nil)
        }
        .sheet(isPresented: $showOpenWith) {
            OpenWithSheet(bookmark: bookmark)
                .preferredColorScheme(AppTheme.colorScheme)
        }
    }

    // MARK: - API Helpers

    private func executeAPIRequest() {
        apiRequestTask?.cancel()
        isExecutingAPI = true
        apiResponse = nil
        apiRequestTask = Task {
            let resp = await APIService.execute(
                url: bookmark.url,
                method: bookmark.apiMethod ?? "GET",
                headers: bookmark.apiHeaders,
                queryParams: bookmark.apiQueryParams,
                body: bookmark.apiBody,
                bodyType: bookmark.apiBodyType
            )
            if Task.isCancelled { return }
            await MainActor.run {
                apiResponse = resp
                isExecutingAPI = false
            }
        }
    }

    private func syncHeadersToBookmark() {
        let rows = apiHeaderRows.filter { !$0.key.isEmpty }
        if rows.isEmpty {
            bookmark.apiHeaders = nil
        } else {
            let arr = rows.map { ["key": $0.key, "value": $0.value, "enabled": true] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: arr),
               let str = String(data: data, encoding: .utf8) {
                bookmark.apiHeaders = str
            }
        }
        bookmark.updatedAt = Date()
    }

    private func syncParamsToBookmark() {
        let rows = apiParamRows.filter { !$0.key.isEmpty }
        if rows.isEmpty {
            bookmark.apiQueryParams = nil
        } else {
            let arr = rows.map { ["key": $0.key, "value": $0.value, "enabled": true] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: arr),
               let str = String(data: data, encoding: .utf8) {
                bookmark.apiQueryParams = str
            }
        }
        bookmark.updatedAt = Date()
    }

    /// 格式化 Body：空则写入空 JSON 模板，否则按 JSON 美化
    private func formatAPIBodyDetail() {
        let raw = bookmark.apiBody ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            bookmark.apiBody = "{\n  \n}"
        } else if let formatted = APIService.formatJSON(raw) {
            bookmark.apiBody = formatted
        }
        bookmark.updatedAt = Date()
    }

    private func bindingHeaderKey(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiHeaderRows.first(where: { $0.id == row.id })?.key ?? "" },
            set: { newValue in
                if let i = apiHeaderRows.firstIndex(where: { $0.id == row.id }) {
                    apiHeaderRows[i].key = newValue
                    syncHeadersToBookmark()
                }
            }
        )
    }

    private func bindingHeaderValue(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiHeaderRows.first(where: { $0.id == row.id })?.value ?? "" },
            set: { newValue in
                if let i = apiHeaderRows.firstIndex(where: { $0.id == row.id }) {
                    apiHeaderRows[i].value = newValue
                    syncHeadersToBookmark()
                }
            }
        )
    }

    private func bindingParamKey(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiParamRows.first(where: { $0.id == row.id })?.key ?? "" },
            set: { newValue in
                if let i = apiParamRows.firstIndex(where: { $0.id == row.id }) {
                    apiParamRows[i].key = newValue
                    syncParamsToBookmark()
                }
            }
        )
    }

    private func bindingParamValue(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiParamRows.first(where: { $0.id == row.id })?.value ?? "" },
            set: { newValue in
                if let i = apiParamRows.firstIndex(where: { $0.id == row.id }) {
                    apiParamRows[i].value = newValue
                    syncParamsToBookmark()
                }
            }
        )
    }

    private func refineAPIMetadata() {
        guard bookmark.isAPI else { return }
        isRefiningAPI = true
        let url = bookmark.url
        let method = bookmark.apiMethod ?? "GET"
        let bodySnippet = bookmark.apiBody
        let origTitle = bookmark.title
        let origDesc = bookmark.desc
        Task {
            let ai = await AIService.shared.refineAPI(
                url: url,
                method: method,
                bodySnippet: bodySnippet,
                originalTitle: origTitle,
                originalDesc: origDesc
            )
            await MainActor.run {
                isRefiningAPI = false
                guard let ai else { return }
                if let t = ai.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bookmark.title = t
                }
                if let d = ai.desc, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bookmark.desc = d
                }
                if let tagList = ai.tags, !tagList.isEmpty {
                    let newTags = tagList
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !newTags.isEmpty {
                        var seen = Set<String>()
                        let combined = (bookmark.tags + newTags).filter { tag in
                            let lower = tag.lowercased()
                            if seen.contains(lower) { return false }
                            seen.insert(lower)
                            return true
                        }
                        bookmark.tags = combined
                        tagsText = combined.joined(separator: ", ")
                    }
                }
                bookmark.updatedAt = Date()
            }
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
