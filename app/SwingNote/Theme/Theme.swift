import SwiftUI

/// Penpot の画面モックから取った配色。通常はダーク、屋外表示（モック08）は明るい配色。
struct Theme {
    var background: Color
    var card: Color
    var raised: Color
    var separator: Color
    var stroke: Color
    var strokeStrong: Color
    var textPrimary: Color
    var textSecondary: Color
    var isOutdoor: Bool

    // 両方の配色で共通の色
    static let accent = Color(hex: 0x8CD35A)
    static let onAccent = Color(hex: 0x0E1110)
    /// A 側（最新球など）。重ね合わせの寒色ティントにも使う
    static let swingA = Color(hex: 0x3FA7FF)
    /// B 側（基準スイングなど）。重ね合わせの暖色ティントにも使う
    static let swingB = Color(hex: 0xFF8A3D)
    /// 写真の上に載せるチップの背景
    static let photoChip = Color.black.opacity(0.6)
    static let photoChipStrong = Color.black.opacity(0.7)

    static let dark = Theme(
        background: Color(hex: 0x0E1110),
        card: Color(hex: 0x181D1A),
        raised: Color(hex: 0x222925),
        separator: Color(hex: 0x2E3732),
        stroke: Color(hex: 0x3A443E),
        strokeStrong: Color(hex: 0x4F5A54),
        textPrimary: Color(hex: 0xF2F5F3),
        textSecondary: Color(hex: 0x9AA59F),
        isOutdoor: false
    )

    /// 屋外表示。直射日光下で読めるよう明るい背景と濃い文字にする
    static let outdoor = Theme(
        background: Color(hex: 0xF4F6F4),
        card: Color(hex: 0xFFFFFF),
        raised: Color(hex: 0xE3E8E4),
        separator: Color(hex: 0xD2D9D4),
        stroke: Color(hex: 0xD2D9D4),
        strokeStrong: Color(hex: 0xB4BEB8),
        textPrimary: Color(hex: 0x0E1110),
        textSecondary: Color(hex: 0x4F5A54),
        isOutdoor: true
    )
}

enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let pill: CGFloat = 28
}

enum Sizes {
    /// 比較する・基準にする・クラブ変更などの主要操作（spec-ui: 56〜60pt）
    static let primaryButtonHeight: CGFloat = 60
    /// スライダーやシークバーの当たり判定の高さ。見た目は細いまま
    static let preciseHitHeight: CGFloat = 60
    static let iconButton: CGFloat = 44
    static let controlButton: CGFloat = 56
}

/// モックは Noto Sans JP（和文）と Inter Tight（数字）。フォントは同梱せずシステムフォントで近い太さ・大きさにする。
enum AppFont {
    static func jp(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func number(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
