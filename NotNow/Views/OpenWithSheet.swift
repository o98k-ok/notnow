import SwiftUI

struct OpenWithSheet: View {
    @Bindable var bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss

    @State private var openMethod: OpenMethod = .defaultBrowser
    @State private var selectedBundleID = ""
    @State private var scriptCommand = ""
    @State private var browsers: [(name: String, bundleID: String)] = []

    enum OpenMethod: String, CaseIterable {
        case defaultBrowser = "默认浏览器"
        case app = "指定应用"
        case script = "自定义脚本"
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "打开方式", icon: "arrow.up.forward.app.fill") {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 20) {
                // Method picker
                HStack(spacing: 4) {
                    ForEach(OpenMethod.allCases, id: \.self) { method in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                openMethod = method
                            }
                        } label: {
                            Text(method.rawValue)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(
                                    openMethod == method
                                        ? AppTheme.textPrimary : AppTheme.textTertiary
                                )
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    openMethod == method
                                        ? AppTheme.accent.opacity(0.15) : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(AppTheme.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                switch openMethod {
                case .defaultBrowser:
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.title3)
                            .foregroundStyle(AppTheme.accent)
                        Text("使用系统默认浏览器打开链接")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                case .app:
                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("选择应用")
                        Picker("", selection: $selectedBundleID) {
                            Text("选择...").tag("")
                            ForEach(browsers, id: \.bundleID) { browser in
                                Text(browser.name).tag(browser.bundleID)
                            }
                        }
                        .labelsHidden()

                        fieldLabel("或手动输入 Bundle ID")
                        HStack(spacing: 8) {
                            Image(systemName: "app.badge")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textTertiary)
                            TextField("com.example.app", text: $selectedBundleID)
                                .textFieldStyle(.plain)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        .darkTextField()
                    }

                case .script:
                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("Shell 命令")
                        TextEditor(text: $scriptCommand)
                            .font(.system(.subheadline, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 70)
                            .background(AppTheme.bgInput)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
                            )

                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text("使用 {url} 作为链接占位符, 例如:")
                                .font(.caption)
                        }
                        .foregroundStyle(AppTheme.textTertiary)

                        Text("open -a Safari {url}")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppTheme.accentCyan)
                            .padding(8)
                            .background(AppTheme.bgInput)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                Spacer()
            }
            .padding(24)

            // Actions
            HStack {
                if bookmark.openWithApp != nil || bookmark.openWithScript != nil {
                    Button {
                        bookmark.openWithApp = nil
                        bookmark.openWithScript = nil
                        bookmark.updatedAt = Date()
                        dismiss()
                    } label: {
                        Text("重置为默认")
                            .ghostButtonStyle()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { save() } label: {
                    Text("保存")
                        .accentButtonStyle()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(AppTheme.bgSecondary.opacity(0.5))
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(AppTheme.bgPrimary)
        .onAppear {
            browsers = OpenService.availableBrowsers()
            if let app = bookmark.openWithApp, !app.isEmpty {
                openMethod = .app
                selectedBundleID = app
            } else if let script = bookmark.openWithScript, !script.isEmpty {
                openMethod = .script
                scriptCommand = script
            }
        }
    }

    private func save() {
        switch openMethod {
        case .defaultBrowser:
            bookmark.openWithApp = nil
            bookmark.openWithScript = nil
        case .app:
            bookmark.openWithApp = selectedBundleID.isEmpty ? nil : selectedBundleID
            bookmark.openWithScript = nil
        case .script:
            bookmark.openWithApp = nil
            bookmark.openWithScript = scriptCommand.isEmpty ? nil : scriptCommand
        }
        bookmark.updatedAt = Date()
        dismiss()
    }
}
