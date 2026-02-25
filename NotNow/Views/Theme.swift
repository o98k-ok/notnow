import SwiftUI

// MARK: - Accent Theme (user-selectable)

enum AccentTheme: String, CaseIterable, Identifiable {
    case purple, cyan, pink, green, orange, blue, red, yellow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .purple: "极光紫"
        case .cyan: "科技蓝"
        case .pink: "霓虹粉"
        case .green: "赛博绿"
        case .orange: "烈焰橙"
        case .blue: "深海蓝"
        case .red: "烈焰红"
        case .yellow: "琥珀黄"
        }
    }

    var color: Color {
        switch self {
        case .purple: Color(hex: 0x6C5CE7)
        case .cyan: Color(hex: 0x00D2FF)
        case .pink: Color(hex: 0xF472B6)
        case .green: Color(hex: 0x34D399)
        case .orange: Color(hex: 0xF97316)
        case .blue: Color(hex: 0x3B82F6)
        case .red: Color(hex: 0xEF4444)
        case .yellow: Color(hex: 0xFBBF24)
        }
    }

    var secondary: Color {
        switch self {
        case .purple: Color(hex: 0x00D2FF)
        case .cyan: Color(hex: 0x6C5CE7)
        case .pink: Color(hex: 0x6C5CE7)
        case .green: Color(hex: 0x00D2FF)
        case .orange: Color(hex: 0xFBBF24)
        case .blue: Color(hex: 0x00D2FF)
        case .red: Color(hex: 0xF97316)
        case .yellow: Color(hex: 0xF97316)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [color, secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Theme-tinted background (primary)
    var bgPrimary: Color {
        switch self {
        case .purple: Color(hex: 0x11142A)
        case .cyan: Color(hex: 0x0A1C2A)
        case .pink: Color(hex: 0x231426)
        case .green: Color(hex: 0x0D211A)
        case .orange: Color(hex: 0x2A1A10)
        case .blue: Color(hex: 0x0E1A34)
        case .red: Color(hex: 0x261416)
        case .yellow: Color(hex: 0x26200F)
        }
    }

    /// Theme-tinted background (secondary / sidebar)
    var bgSecondary: Color {
        switch self {
        case .purple: Color(hex: 0x171C36)
        case .cyan: Color(hex: 0x102636)
        case .pink: Color(hex: 0x2A1B2E)
        case .green: Color(hex: 0x143027)
        case .orange: Color(hex: 0x352415)
        case .blue: Color(hex: 0x162447)
        case .red: Color(hex: 0x301B1D)
        case .yellow: Color(hex: 0x322813)
        }
    }

    /// Theme-tinted card background
    var bgCard: Color {
        switch self {
        case .purple: Color(hex: 0x1E2240)
        case .cyan: Color(hex: 0x193040)
        case .pink: Color(hex: 0x342239)
        case .green: Color(hex: 0x1A3329)
        case .orange: Color(hex: 0x3A2918)
        case .blue: Color(hex: 0x1B2B4D)
        case .red: Color(hex: 0x352224)
        case .yellow: Color(hex: 0x372D17)
        }
    }

    static var current: AccentTheme {
        AccentTheme(rawValue: UserDefaults.standard.string(forKey: "accentTheme") ?? "") ?? .purple
    }
}

// MARK: - App Theme

enum AppTheme {
    // Dynamic accent (reads user preference)
    static var accent: Color { AccentTheme.current.color }
    static var accentGradient: LinearGradient { AccentTheme.current.gradient }
    static var glowAccent: Color { AccentTheme.current.color.opacity(0.4) }

    // Dynamic backgrounds (tinted by theme)
    static var bgPrimary: Color { AccentTheme.current.bgPrimary }
    static var bgSecondary: Color { AccentTheme.current.bgSecondary }
    static var bgCard: Color { AccentTheme.current.bgCard }
    static var bgElevated: Color { AccentTheme.current.bgCard.opacity(0.9) }
    static var bgInput: Color { AccentTheme.current.bgPrimary }
    static var backgroundGradient: LinearGradient {
        let t = AccentTheme.current
        return LinearGradient(
            colors: [
                t.color.opacity(0.22),
                t.secondary.opacity(0.15),
                t.bgPrimary
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // Fixed accent colors (non-theme)
    static let accentCyan = Color(hex: 0x00D2FF)
    static let accentPink = Color(hex: 0xF472B6)
    static let accentGreen = Color(hex: 0x34D399)

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary = Color.white.opacity(0.35)

    // Borders
    static let borderSubtle = Color.white.opacity(0.06)
    static let borderHover = Color.white.opacity(0.12)

    static var coverOverlay: LinearGradient {
        LinearGradient(
            colors: [Color.clear, AccentTheme.current.bgPrimary.opacity(0.9)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - View Modifiers

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppTheme.bgCard.opacity(0.85))
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.ultraThinMaterial)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isHovered ? AppTheme.borderHover : AppTheme.borderSubtle,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? AppTheme.glowAccent.opacity(0.3) : .clear,
                radius: 12
            )
    }
}

struct DarkTextField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(10)
            .background(AppTheme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            )
    }
}

struct AccentButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(AppTheme.accentGradient)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct GhostButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(AppTheme.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.borderSubtle, lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14, isHovered: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, isHovered: isHovered))
    }
    func darkTextField() -> some View { modifier(DarkTextField()) }
    func accentButtonStyle() -> some View { modifier(AccentButton()) }
    func ghostButtonStyle() -> some View { modifier(GhostButton()) }
}

// MARK: - Tag Colors

enum TagColor {
    static let palette: [Color] = [
        Color(hex: 0x6C5CE7), Color(hex: 0x00D2FF), Color(hex: 0xF472B6),
        Color(hex: 0x34D399), Color(hex: 0xFBBF24), Color(hex: 0xF97316),
        Color(hex: 0xA78BFA), Color(hex: 0x22D3EE),
    ]
    static func color(for tag: String) -> Color {
        palette[abs(tag.hashValue) % palette.count]
    }
}
