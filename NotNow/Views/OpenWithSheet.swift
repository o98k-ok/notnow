import SwiftUI

struct OpenWithSheet: View {
    @Bindable var bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss

    @State private var scriptCommand = ""

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "自定义脚本", icon: "terminal.fill") {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 20) {
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
                        Text("使用 {TEXT} 作为内容占位符（链接为 URL，Snippet 为内容）")
                            .font(.caption)
                    }
                    .foregroundStyle(AppTheme.textTertiary)

                    Text("echo {TEXT} | pbcopy")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.accentCyan)
                        .padding(8)
                        .background(AppTheme.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Text("配置后，点击此卡片将执行脚本，而非走全局设置。清空即恢复为全局行为。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)

                Spacer()
            }
            .padding(24)

            // Actions
            HStack {
                if bookmark.openWithScript != nil {
                    Button {
                        bookmark.openWithScript = nil
                        bookmark.openWithApp = nil
                        bookmark.updatedAt = Date()
                        dismiss()
                    } label: {
                        Text("清除脚本")
                            .ghostButtonStyle()
                    }
                    .buttonStyle(.notNowPlainInteractive)
                }
                Spacer()
                Button { save() } label: {
                    Text("保存")
                        .accentButtonStyle()
                }
                .buttonStyle(.notNowPlainInteractive)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(AppTheme.bgSecondary.opacity(0.5))
        }
        .frame(minWidth: 440, minHeight: 340)
        .background(AppTheme.bgPrimary)
        .onAppear {
            scriptCommand = bookmark.openWithScript ?? ""
        }
    }

    private func save() {
        bookmark.openWithScript = scriptCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : scriptCommand
        bookmark.openWithApp = nil
        bookmark.updatedAt = Date()
        dismiss()
    }
}
