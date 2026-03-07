import SwiftData
import SwiftUI

struct CategorySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var editingCategory: Category?

    @State private var name = ""
    @State private var icon = "folder.fill"
    @State private var colorHex: Int = 0x6C5CE7

    private let icons = [
        "folder.fill", "bookmark.fill", "star.fill", "heart.fill",
        "doc.fill", "book.fill", "newspaper.fill", "link",
        "globe", "desktopcomputer", "laptopcomputer", "iphone",
        "gamecontroller.fill", "music.note", "film", "photo.fill",
        "paintbrush.fill", "hammer.fill", "wrench.fill", "gearshape.fill",
        "cpu", "memorychip", "network", "antenna.radiowaves.left.and.right",
        "cloud.fill", "bolt.fill", "flame.fill", "leaf.fill",
        "cart.fill", "creditcard.fill", "briefcase.fill", "building.2.fill",
    ]

    private let presetColors: [Int] = [
        0x6C5CE7, 0x3B82F6, 0x00D2FF, 0x34D399,
        0xFBBF24, 0xF97316, 0xF472B6, 0xEF4444,
    ]

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: editingCategory == nil ? "新建分类" : "编辑分类",
                icon: "folder.badge.plus"
            ) { dismiss() }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Preview
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(Color(hex: UInt(colorHex)))
                            .frame(width: 44, height: 44)
                            .background(Color(hex: UInt(colorHex)).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(name.isEmpty ? "分类名称" : name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(name.isEmpty ? AppTheme.textTertiary : AppTheme.textPrimary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Name
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("名称")
                        TextField("分类名称", text: $name)
                            .darkTextField()
                            .font(.subheadline)
                    }

                    // Icon picker
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("图标")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8),
                            spacing: 6
                        ) {
                            ForEach(icons, id: \.self) { ic in
                                Button { icon = ic } label: {
                                    Image(systemName: ic)
                                        .font(.body)
                                        .frame(width: 36, height: 36)
                                        .background(
                                            icon == ic
                                                ? Color(hex: UInt(colorHex)).opacity(0.2)
                                                : AppTheme.bgInput
                                        )
                                        .foregroundStyle(
                                            icon == ic
                                                ? Color(hex: UInt(colorHex))
                                                : AppTheme.textSecondary
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(
                                                    icon == ic
                                                        ? Color(hex: UInt(colorHex)).opacity(0.5)
                                                        : .clear,
                                                    lineWidth: 1.5
                                                )
                                        )
                                }
                                .buttonStyle(.notNowPlainInteractive)
                            }
                        }
                    }

                    // Color picker
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("颜色")
                        HStack(spacing: 10) {
                            ForEach(presetColors, id: \.self) { hex in
                                Button { colorHex = hex } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: UInt(hex)))
                                            .frame(width: 30, height: 30)
                                        if colorHex == hex {
                                            Circle()
                                                .stroke(.white, lineWidth: 2)
                                                .frame(width: 24, height: 24)
                                        }
                                    }
                                    .shadow(
                                        color: Color(hex: UInt(hex)).opacity(
                                            colorHex == hex ? 0.5 : 0),
                                        radius: 4
                                    )
                                }
                                .buttonStyle(.notNowPlainInteractive)
                            }
                        }
                    }
                }
                .padding(24)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .ghostButtonStyle()
                    .buttonStyle(.notNowPlainInteractive)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .accentButtonStyle()
                    .buttonStyle(.notNowPlainInteractive)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
                    .opacity(name.isEmpty ? 0.5 : 1)
            }
            .padding(20)
            .background(AppTheme.bgSecondary.opacity(0.5))
        }
        .frame(minWidth: 440, minHeight: 460)
        .background(AppTheme.bgPrimary)
        .onAppear {
            if let cat = editingCategory {
                name = cat.name
                icon = cat.icon
                colorHex = cat.colorHex
            }
        }
    }

    private func save() {
        if let cat = editingCategory {
            cat.name = name
            cat.icon = icon
            cat.colorHex = colorHex
        } else {
            let cat = Category(name: name, icon: icon, colorHex: colorHex)
            modelContext.insert(cat)
        }
        try? modelContext.save()
        NotificationCenter.default.postModelDataDidChange(kind: .categoryChanged)
        dismiss()
    }
}
