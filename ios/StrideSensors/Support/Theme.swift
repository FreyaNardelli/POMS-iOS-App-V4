import SwiftUI

/// Palette lifted from the Stride "Live sensors" design.
enum Theme {
    static let bg          = Color(hex: 0x12181D)
    static let bgElevated  = Color(hex: 0x0C1114)
    static let panel       = Color(hex: 0x1A222A)
    static let panelBorder = Color(hex: 0x26323C)
    static let track       = Color(hex: 0x26323C)
    static let tick        = Color(hex: 0x3A4855)

    static let orange = Color(hex: 0xFF7A2B)
    static let coral  = Color(hex: 0xFF8A62)
    static let purple = Color(hex: 0x8B6FC7)
    static let green  = Color(hex: 0x3E9E66)
    static let mint   = Color(hex: 0x7FE6A6)

    static let textPrimary = Color(hex: 0xEAF1F5)
    static let textDim     = Color(hex: 0x8AA0AD)
    static let textFaint   = Color(hex: 0x5E7280)

    /// Rounded system font stands in for Fredoka.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    // MARK: Kid-facing (Home / Rewards) warm palette — from the HTML demo
    static let cream       = Color(hex: 0xFFF0E4)
    static let card        = Color(hex: 0xFFFFFF)
    static let ink         = Color(hex: 0x2E1F19)
    static let inkSoft     = Color(hex: 0x3A2A22)
    static let brown       = Color(hex: 0x9A8072)
    static let brownDim    = Color(hex: 0xB0998B)
    static let coralRed    = Color(hex: 0xFF5A2B)
    static let amber       = Color(hex: 0xFFB13E)
    static let cardShadow  = Color(hex: 0x3A2A22, alpha: 0.06)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
