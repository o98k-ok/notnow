import SwiftUI

// MARK: - Accent Theme (user-selectable)

enum AccentTheme: String, CaseIterable, Identifiable {
    case dark, light, cli, christmas

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: "深色模式"
        case .light: "浅色模式"
        case .cli: "终端主题"
        case .christmas: "圣诞主题"
        }
    }

    var icon: String {
        switch self {
        case .dark: "moon.fill"
        case .light: "sun.max.fill"
        case .cli: "terminal.fill"
        case .christmas: "gift.fill"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        default: .dark
        }
    }

    // MARK: Accent colors

    var color: Color {
        switch self {
        case .dark: Color(hex: 0x6C5CE7)
        case .light: Color(hex: 0x6C5CE7)
        case .cli: Color(hex: 0x10B981)
        case .christmas: Color(hex: 0xDC2626)
        }
    }

    var secondary: Color {
        switch self {
        case .dark: Color(hex: 0x00D2FF)
        case .light: Color(hex: 0xF472B6)
        case .cli: Color(hex: 0x4AF626)
        case .christmas: Color(hex: 0x16A34A)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [color, secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Backgrounds

    var bgPrimary: Color {
        switch self {
        case .dark: Color(hex: 0x11142A)
        case .light: Color(hex: 0xF8F9FA)
        case .cli: Color(hex: 0x000000)
        case .christmas: Color(hex: 0x0D1B0F)
        }
    }

    var bgSecondary: Color {
        switch self {
        case .dark: Color(hex: 0x171C36)
        case .light: Color(hex: 0xFFFFFF)
        case .cli: Color(hex: 0x0A0A0A)
        case .christmas: Color(hex: 0x142016)
        }
    }

    var bgCard: Color {
        switch self {
        case .dark: Color(hex: 0x1E2240)
        case .light: Color(hex: 0xFFFFFF)
        case .cli: Color(hex: 0x1A1A1A)
        case .christmas: Color(hex: 0x1A2A1E)
        }
    }

    // MARK: Text

    var textPrimary: Color {
        switch self {
        case .dark: .white
        case .light: Color(hex: 0x1A1A1A)
        case .cli: .white
        case .christmas: .white
        }
    }

    var textSecondary: Color {
        switch self {
        case .dark: Color.white.opacity(0.6)
        case .light: Color(hex: 0x71717A)
        case .cli: Color(hex: 0x4AF626)
        case .christmas: Color(hex: 0xE5E7EB)
        }
    }

    var textTertiary: Color {
        switch self {
        case .dark: Color.white.opacity(0.35)
        case .light: Color(hex: 0xA1A1AA)
        case .cli: Color(hex: 0x525252)
        case .christmas: Color.white.opacity(0.35)
        }
    }

    // MARK: Borders

    var borderSubtle: Color {
        switch self {
        case .dark: Color.white.opacity(0.06)
        case .light: Color.black.opacity(0.06)
        case .cli: Color(hex: 0x333333)
        case .christmas: Color(hex: 0xFDE68A).opacity(0.12)
        }
    }

    var borderHover: Color {
        switch self {
        case .dark: Color.white.opacity(0.12)
        case .light: Color.black.opacity(0.12)
        case .cli: Color(hex: 0x4AF626).opacity(0.4)
        case .christmas: Color(hex: 0xFDE68A).opacity(0.2)
        }
    }

    // MARK: Preview color (for theme picker swatch)

    var previewColor: Color {
        switch self {
        case .dark: Color(hex: 0x1E2240)
        case .light: Color(hex: 0xF8F9FA)
        case .cli: Color(hex: 0x000000)
        case .christmas: Color(hex: 0x0D1B0F)
        }
    }

    static var current: AccentTheme {
        AccentTheme(rawValue: UserDefaults.standard.string(forKey: "accentTheme") ?? "") ?? .dark
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
        switch t {
        case .light:
            return LinearGradient(
                colors: [
                    t.color.opacity(0.08),
                    t.secondary.opacity(0.05),
                    t.bgPrimary,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [
                    t.color.opacity(0.22),
                    t.secondary.opacity(0.15),
                    t.bgPrimary,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // Fixed accent colors (non-theme)
    static let accentCyan = Color(hex: 0x00D2FF)
    static let accentPink = Color(hex: 0xF472B6)
    static let accentGreen = Color(hex: 0x34D399)

    // Dynamic text
    static var textPrimary: Color { AccentTheme.current.textPrimary }
    static var textSecondary: Color { AccentTheme.current.textSecondary }
    static var textTertiary: Color { AccentTheme.current.textTertiary }

    // Dynamic borders
    static var borderSubtle: Color { AccentTheme.current.borderSubtle }
    static var borderHover: Color { AccentTheme.current.borderHover }

    // Dynamic color scheme
    static var colorScheme: ColorScheme { AccentTheme.current.colorScheme }

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
