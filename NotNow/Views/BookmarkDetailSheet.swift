import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct BookmarkDetailSheet: View {
    @Bindable var bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) var categories: [Category]

    private enum CoverEditState: Equatable {
        case unchanged
        case removed
        case replaced
    }

    private struct DraftSnapshot: Equatable {
        var url: String
        var title: String
        var desc: String
        var snippetText: String
        var notes: String
        var tags: [String]
        var isFavorite: Bool
        var categoryID: UUID?
        var taskCompleted: Bool
        var completedAt: Date?
        var dueDate: Date?
        var taskPriority: TaskPriority
        var apiMethod: HTTPMethod
        var apiHeaders: String?
        var apiQueryParams: String?
        var apiBody: String
        var apiBodyType: String
        var coverEditState: CoverEditState
        var coverDataSignature: String
        var coverURL: String?
    }

    @State private var draftURL = ""
    @State private var draftTitle = ""
    @State private var draftDesc = ""
    @State private var draftSnippetText = ""
    @State private var draftNotes = ""
    @State private var tagsText = ""
    @State private var draftIsFavorite = false
    @State private var draftCategoryID: UUID?
    @State private var draftTaskCompleted = false
    @State private var draftCompletedAt: Date?
    @State private var draftDueDate: Date?
    @State private var draftTaskPriority: TaskPriority = .none
    @State private var draftAPIMethod: HTTPMethod = .GET
    @State private var draftAPIBody = ""
    @State private var draftAPIBodyType = "json"
    @State private var draftCoverData: Data?
    @State private var draftCoverURL: String?
    @State private var coverEditState: CoverEditState = .unchanged
    @State private var previewCoverImage: NSImage?
    @State private var isLoadingCoverPreview = false
    @State private var initialSnapshot: DraftSnapshot?
    @State private var didInitializeDraft = false
    @State private var coverPreviewTask: Task<Void, Never>?
    @State private var deferredCoverPreviewTask: Task<Void, Never>?
    @State private var showDiscardChangesDialog = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
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
                handleCloseTapped()
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
                                TextField("URL", text: $draftURL)
                                    .textFieldStyle(.plain)
                                    .font(.subheadline)
                            }
                            .darkTextField()

                            Button {
                                if let url = URL(string: draftURL) {
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
                            .buttonStyle(.notNowPlainInteractive)
                        }
                    }
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("标题")
                        TextField("标题", text: $draftTitle)
                            .darkTextField()
                            .font(.subheadline)
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("描述")
                        TextField("描述", text: $draftDesc)
                            .darkTextField()
                            .font(.subheadline)
                    }

                    if bookmark.isSnippet {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("内容")
                            TextEditor(text: Binding(
                                get: { draftSnippetText },
                                set: { draftSnippetText = $0 }
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
                                draftTaskCompleted ? "已完成" : "未完成",
                                icon: draftTaskCompleted ? "checkmark.circle.fill" : "circle",
                                isOn: Binding(
                                    get: { draftTaskCompleted },
                                    set: { newValue in
                                        draftTaskCompleted = newValue
                                        draftCompletedAt = newValue ? (draftCompletedAt ?? Date()) : nil
                                    }
                                ),
                                color: .green
                            )

                            if let completedAt = draftCompletedAt {
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
                                get: { draftTaskPriority },
                                set: { newValue in
                                    draftTaskPriority = newValue
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
                                if let due = draftDueDate {
                                    DatePicker("", selection: Binding(
                                        get: { due },
                                        set: { draftDueDate = $0 }
                                    ), displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()

                                    Button {
                                        draftDueDate = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textTertiary)
                                    }
                                    .buttonStyle(.notNowPlainInteractive)

                                    if !draftTaskCompleted && due < Date() {
                                        Text("已逾期")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.red)
                                    }
                                } else {
                                    Button {
                                        draftDueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
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
                                    .buttonStyle(.notNowPlainInteractive)
                                }
                            }
                        }

                        // Task description
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("任务描述")
                            TextEditor(text: $draftDesc)
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
                                    TextField("https://...", text: $draftURL)
                                        .textFieldStyle(.plain)
                                        .font(.subheadline)
                                }
                                .darkTextField()

                                if !draftURL.hasPrefix("task://") {
                                    Button {
                                        if let url = URL(string: draftURL) {
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
                                    .buttonStyle(.notNowPlainInteractive)
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
                                    get: { draftAPIMethod },
                                    set: { draftAPIMethod = $0 }
                                )) {
                                    ForEach(HTTPMethod.allCases, id: \.self) { m in
                                        Text(m.rawValue).tag(m)
                                    }
                                }
                                .frame(width: 90)

                                TextField("https://...", text: $draftURL)
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
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.accentPink)
                                    }
                                    .buttonStyle(.notNowPlainInteractive)
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
                            .buttonStyle(.notNowPlainInteractive)
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
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.accentPink)
                                    }
                                    .buttonStyle(.notNowPlainInteractive)
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
                            .buttonStyle(.notNowPlainInteractive)
                        }

                        // Body
                        if draftAPIMethod != .GET {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    fieldLabel("Body")
                                    Spacer()
                                    Picker("", selection: Binding(
                                        get: { draftAPIBodyType },
                                        set: { draftAPIBodyType = $0 }
                                    )) {
                                        Text("JSON").tag("json")
                                        Text("Form").tag("form")
                                        Text("Text").tag("text")
                                        Text("None").tag("none")
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 240)
                                    if draftAPIBodyType == "json" {
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
                                        .buttonStyle(.notNowPlainInteractive)
                                    }
                                }
                                if draftAPIBodyType != "none" {
                                    PlainTextEditor(
                                        text: Binding(
                                            get: { draftAPIBody },
                                            set: { draftAPIBody = $0 }
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
                            .buttonStyle(.notNowPlainInteractive)
                            .disabled(isExecutingAPI || draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button {
                                let curl = APIService.generateCURL(
                                    url: draftURL,
                                    method: draftAPIMethod.rawValue,
                                    headers: serializeRows(apiHeaderRows),
                                    queryParams: serializeRows(apiParamRows),
                                    body: draftAPIBody,
                                    bodyType: draftAPIBodyType
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
                            .buttonStyle(.notNowPlainInteractive)

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
                                    .buttonStyle(.notNowPlainInteractive)
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
                                .buttonStyle(.notNowPlainInteractive)
                                .disabled(isRefiningAPI || draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                        }
                        .darkTextField()

                        // Tag preview
                        if !draftTags.isEmpty {
                            FlowLayout(spacing: 4) {
                                ForEach(draftTags, id: \.self) { tag in
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
                        TextEditor(text: $draftNotes)
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
                            get: { draftCategoryID },
                            set: { newID in
                                draftCategoryID = newID
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
                                get: { draftIsFavorite },
                                set: { newValue in
                                    draftIsFavorite = newValue
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
                .buttonStyle(.notNowPlainInteractive)

                Spacer()

                Button("取消") { handleCloseTapped() }
                    .buttonStyle(.notNowPlainInteractive)

                Button("保存") { saveChanges() }
                    .accentButtonStyle()
                    .buttonStyle(.notNowPlainInteractive)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(AppTheme.bgSecondary.opacity(0.5))
        }
        .frame(minWidth: 560, minHeight: 640)
        .background(AppTheme.bgPrimary)
        .onAppear {
            initializeDraftCoreIfNeeded()
            scheduleDeferredInitialCoverPreviewLoad()
        }
        .onDisappear {
            apiRequestTask?.cancel()
            coverFetchTask?.cancel()
            coverPreviewTask?.cancel()
            deferredCoverPreviewTask?.cancel()
        }
        .onChange(of: bookmark.coverData) {
            if coverEditState == .unchanged {
                scheduleCoverPreviewForCurrentState()
            }
        }
        .confirmationDialog("放弃未保存修改？", isPresented: $showDiscardChangesDialog, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("你在编辑页的修改尚未保存。")
        }
        .alert("保存失败", isPresented: $showSaveError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
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
                url: draftURL,
                method: draftAPIMethod.rawValue,
                headers: serializeRows(apiHeaderRows),
                queryParams: serializeRows(apiParamRows),
                body: draftAPIBodyType == "none" ? nil : draftAPIBody,
                bodyType: draftAPIBodyType
            )
            if Task.isCancelled { return }
            await MainActor.run {
                apiResponse = resp
                isExecutingAPI = false
            }
        }
    }

    /// 格式化 Body：空则写入空 JSON 模板，否则按 JSON 美化
    private func formatAPIBodyDetail() {
        let raw = draftAPIBody
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftAPIBody = "{\n  \n}"
        } else if let formatted = APIService.formatJSON(raw) {
            draftAPIBody = formatted
        }
    }

    private func bindingHeaderKey(_ row: APIKeyValueRow) -> Binding<String> {
        Binding(
            get: { apiHeaderRows.first(where: { $0.id == row.id })?.key ?? "" },
            set: { newValue in
                if let i = apiHeaderRows.firstIndex(where: { $0.id == row.id }) {
                    apiHeaderRows[i].key = newValue
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
                }
            }
        )
    }

    private func refineAPIMetadata() {
        guard bookmark.isAPI else { return }
        isRefiningAPI = true
        let url = draftURL
        let method = draftAPIMethod.rawValue
        let bodySnippet = draftAPIBodyType == "none" ? nil : draftAPIBody
        let origTitle = draftTitle
        let origDesc = draftDesc
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
                    draftTitle = t
                }
                if let d = ai.desc, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draftDesc = d
                }
                if let tagList = ai.tags, !tagList.isEmpty {
                    let newTags = tagList
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !newTags.isEmpty {
                        var seen = Set<String>()
                        let combined = (draftTags + newTags).filter { tag in
                            let lower = tag.lowercased()
                            if seen.contains(lower) { return false }
                            seen.insert(lower)
                            return true
                        }
                        tagsText = combined.joined(separator: ", ")
                    }
                }
            }
        }
    }

    // MARK: - Cover Management

    private var hasEditableCover: Bool {
        switch coverEditState {
        case .unchanged:
            return bookmark.coverData != nil
        case .removed:
            return false
        case .replaced:
            return draftCoverData != nil || previewCoverImage != nil
        }
    }

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
                    .buttonStyle(.notNowPlainInteractive)

                    if hasEditableCover {
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
                        .buttonStyle(.notNowPlainInteractive)
                    }
                }
            }

            if let image = previewCoverImage {
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
            } else if isLoadingCoverPreview {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("封面加载中...")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(AppTheme.bgInput)
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
                .buttonStyle(.notNowPlainInteractive)
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
        .buttonStyle(.notNowPlainInteractive)
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
                .buttonStyle(.notNowPlainInteractive)
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
        .buttonStyle(.notNowPlainInteractive)
    }

    private func refetchCover(mode: CoverFetchMode) {
        guard !draftURL.isEmpty else { return }
        coverFetchTask?.cancel()
        isFetchingCover = true
        let currentURL = draftURL
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
                if Task.isCancelled || draftURL != currentURL { return }
                if let data = imageData {
                    draftCoverData = data
                    draftCoverURL = imageURL
                    coverEditState = .replaced
                    scheduleCoverPreviewForCurrentState()
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
            if let data = try? Data(contentsOf: fileURL) {
                draftCoverData = data
                draftCoverURL = nil
                coverEditState = .replaced
                scheduleCoverPreviewForCurrentState()
            }
        }
    }

    private func removeCover() {
        coverFetchTask?.cancel()
        isFetchingCover = false
        coverEditState = .removed
        draftCoverData = nil
        draftCoverURL = nil
        previewCoverImage = nil
        coverPreviewTask?.cancel()
        isLoadingCoverPreview = false
    }

    private func deleteBookmark() {
        guard let modelContext = bookmark.modelContext else {
            dismiss()
            return
        }
        let deletedBookmarkID = bookmark.id
        modelContext.delete(bookmark)
        try? modelContext.save()
        dismiss()
        Task { @MainActor in
            NotificationCenter.default.postModelDataDidChange(
                kind: .bookmarkDeleted,
                bookmarkID: deletedBookmarkID
            )
        }
    }

    private var draftTags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var hasUnsavedChanges: Bool {
        guard let initialSnapshot else { return false }
        return currentSnapshot() != initialSnapshot
    }

    private func initializeDraftCoreIfNeeded() {
        guard !didInitializeDraft else { return }
        didInitializeDraft = true

        draftURL = bookmark.url
        draftTitle = bookmark.title
        draftDesc = bookmark.desc
        draftSnippetText = bookmark.snippetText
        draftNotes = bookmark.notes
        tagsText = bookmark.tags.joined(separator: ", ")
        draftIsFavorite = bookmark.isFavorite
        draftCategoryID = bookmark.category?.id
        draftTaskCompleted = bookmark.taskCompleted
        draftCompletedAt = bookmark.completedAt
        draftDueDate = bookmark.dueDate
        draftTaskPriority = bookmark.resolvedTaskPriority
        draftAPIMethod = bookmark.resolvedAPIMethod
        draftAPIBodyType = bookmark.apiBodyType ?? "json"
        draftAPIBody = bookmark.apiBody ?? ""
        draftCoverData = nil
        draftCoverURL = bookmark.coverURL
        coverEditState = .unchanged
        previewCoverImage = nil
        isLoadingCoverPreview = false

        if bookmark.isAPI {
            let headerTuples = APIService.parseKeyValues(bookmark.apiHeaders)
            apiHeaderRows = headerTuples.map { APIKeyValueRow(key: $0.key, value: $0.value) }
            if apiHeaderRows.isEmpty { apiHeaderRows = [APIKeyValueRow(key: "", value: "")] }

            let paramTuples = APIService.parseKeyValues(bookmark.apiQueryParams)
            apiParamRows = paramTuples.map { APIKeyValueRow(key: $0.key, value: $0.value) }
            if apiParamRows.isEmpty { apiParamRows = [APIKeyValueRow(key: "", value: "")] }
        } else {
            apiHeaderRows = []
            apiParamRows = []
        }

        initialSnapshot = currentSnapshot()
    }

    private func scheduleDeferredInitialCoverPreviewLoad() {
        deferredCoverPreviewTask?.cancel()
        guard !bookmark.isSnippet, !bookmark.isTask, !bookmark.isAPI else { return }

        deferredCoverPreviewTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                scheduleCoverPreviewForCurrentState()
            }
        }
    }

    private func scheduleCoverPreviewForCurrentState() {
        coverPreviewTask?.cancel()
        let dataToPreview: Data?
        switch coverEditState {
        case .unchanged:
            dataToPreview = bookmark.coverData
        case .removed:
            dataToPreview = nil
        case .replaced:
            dataToPreview = draftCoverData
        }

        guard let dataToPreview else {
            previewCoverImage = nil
            isLoadingCoverPreview = false
            return
        }

        if let cached = CoverImageCache.image(for: bookmark.id, data: dataToPreview) {
            previewCoverImage = cached
            isLoadingCoverPreview = false
            return
        }

        isLoadingCoverPreview = true
        let bookmarkID = bookmark.id
        let currentCoverState = coverEditState
        coverPreviewTask = Task {
            await CoverDecodeLimiter.shared.acquire()
            defer { Task { await CoverDecodeLimiter.shared.release() } }
            if Task.isCancelled { return }

            let cgImage = await CoverImageCache.decodeThumbnailCGImage(
                data: dataToPreview,
                maxPixelSize: 1200
            )
            if Task.isCancelled { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard coverEditState == currentCoverState else { return }
                if let cgImage {
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    CoverImageCache.set(image, for: bookmarkID, data: dataToPreview)
                    previewCoverImage = image
                } else {
                    previewCoverImage = nil
                }
                isLoadingCoverPreview = false
            }
        }
    }

    private func currentSnapshot() -> DraftSnapshot {
        DraftSnapshot(
            url: draftURL,
            title: draftTitle,
            desc: draftDesc,
            snippetText: draftSnippetText,
            notes: draftNotes,
            tags: draftTags,
            isFavorite: draftIsFavorite,
            categoryID: draftCategoryID,
            taskCompleted: draftTaskCompleted,
            completedAt: draftCompletedAt,
            dueDate: draftDueDate,
            taskPriority: draftTaskPriority,
            apiMethod: draftAPIMethod,
            apiHeaders: serializeRows(apiHeaderRows),
            apiQueryParams: serializeRows(apiParamRows),
            apiBody: draftAPIBody,
            apiBodyType: draftAPIBodyType,
            coverEditState: coverEditState,
            coverDataSignature: coverSnapshotDataSignature(),
            coverURL: draftCoverURL
        )
    }

    private func coverSnapshotDataSignature() -> String {
        switch coverEditState {
        case .unchanged:
            return "unchanged"
        case .removed:
            return "removed"
        case .replaced:
            return "replaced:\(dataSignature(draftCoverData))"
        }
    }

    private func dataSignature(_ data: Data?) -> String {
        guard let data else { return "nil" }
        var hash: UInt64 = UInt64(data.count)
        let prefixCount = min(24, data.count)
        for byte in data.prefix(prefixCount) {
            hash = (hash &* 16777619) ^ UInt64(byte)
        }
        return "\(data.count)-\(hash)"
    }

    private func serializeRows(_ rows: [APIKeyValueRow]) -> String? {
        let normalizedRows = rows
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                (
                    key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines),
                    value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        if normalizedRows.isEmpty { return nil }
        let arr = normalizedRows.map { ["key": $0.key, "value": $0.value, "enabled": true] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func handleCloseTapped() {
        if hasUnsavedChanges {
            showDiscardChangesDialog = true
        } else {
            dismiss()
        }
    }

    private func saveChanges() {
        guard let modelContext = bookmark.modelContext else {
            dismiss()
            return
        }
        if !hasUnsavedChanges {
            dismiss()
            return
        }

        applyDraftToBookmark(modelContext: modelContext)
        bookmark.updatedAt = Date()

        do {
            try modelContext.save()
            initialSnapshot = currentSnapshot()
            dismiss()
            let bookmarkID = bookmark.id
            Task { @MainActor in
                NotificationCenter.default.postModelDataDidChange(
                    kind: .bookmarkUpserted,
                    bookmarkID: bookmarkID
                )
            }
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveError = true
        }
    }

    private func applyDraftToBookmark(modelContext: ModelContext) {
        bookmark.url = draftURL
        bookmark.title = draftTitle
        bookmark.desc = draftDesc
        bookmark.snippetText = draftSnippetText
        bookmark.notes = draftNotes
        bookmark.tags = draftTags
        bookmark.isFavorite = draftIsFavorite
        bookmark.taskCompleted = draftTaskCompleted
        bookmark.completedAt = draftTaskCompleted ? (draftCompletedAt ?? Date()) : nil
        bookmark.dueDate = draftDueDate
        bookmark.resolvedTaskPriority = draftTaskPriority
        bookmark.resolvedAPIMethod = draftAPIMethod
        bookmark.apiHeaders = serializeRows(apiHeaderRows)
        bookmark.apiQueryParams = serializeRows(apiParamRows)
        bookmark.apiBodyType = draftAPIBodyType
        bookmark.apiBody = draftAPIBodyType == "none" ? nil : draftAPIBody
        switch coverEditState {
        case .unchanged:
            break
        case .removed:
            bookmark.coverData = nil
            bookmark.coverURL = nil
        case .replaced:
            bookmark.coverData = draftCoverData
            bookmark.coverURL = draftCoverURL
        }

        if draftIsFavorite {
            bookmark.category = ensureFavoriteCategory(modelContext: modelContext)
            return
        }

        let selectedCategory = categories.first { $0.id == draftCategoryID }
        if selectedCategory?.name == "收藏" {
            bookmark.category = nil
        } else {
            bookmark.category = selectedCategory
        }
    }

    private func ensureFavoriteCategory(modelContext: ModelContext) -> Category {
        let fetchDescriptor = FetchDescriptor<Category>()
        let allCategories = (try? modelContext.fetch(fetchDescriptor)) ?? []
        if let existing = allCategories.first(where: { $0.name == "收藏" }) {
            return existing
        }
        let favoriteCategory = Category(
            name: "收藏",
            icon: "star.fill",
            colorHex: 0xFFD700,
            sortOrder: -1
        )
        modelContext.insert(favoriteCategory)
        return favoriteCategory
    }
}
