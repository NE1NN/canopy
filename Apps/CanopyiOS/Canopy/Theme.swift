import CanopyPhone
import CanopyWire
import SwiftUI
import UIKit

/// The mockup's colors, light and dark.
enum Theme {
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let green = Color(light: 0x34C759, dark: 0x30D158)
    static let ring = Color(light: 0x1FA544, dark: 0x30D158)
    static let yellow = Color(light: 0xD49A00, dark: 0xFFD60A)
    static let red = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let purple = Color(light: 0x8E3FB5, dark: 0xC895EA)
    static let tiles = [Color(light: 0x5257D6, dark: 0x8B8FF8), Color(light: 0x0E8A7B, dark: 0x40C8B4)]
    static let chip = Color(light: 0x007AFF, dark: 0x0A84FF, lightAlpha: 0.1, darkAlpha: 0.18)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let separator = Color(uiColor: .separator)
    static let terminal = Color(light: 0xFFFFFF, dark: 0x121214)
    static let terminalText = Color(light: 0x1D1D1F, dark: 0xE6E6E6)

    /// A repo's tile color, the same for the same repo everywhere.
    static func tile(for repo: String) -> Color {
        tiles[Int(repo.unicodeScalars.reduce(0) { ($0 &* 31 &+ $1.value) % 1_000 }) % tiles.count]
    }

    /// The Mac terminal's 16 ANSI colors.
    static let darkPalette: [UInt32] = [
        0x3A3A40, 0xF2736B, 0x7CCD80, 0xE3C46D, 0x72AAF6, 0xC895EA, 0x6DD0D9, 0xC9C9CE,
        0x6A6A72, 0xFF8C85, 0x97DE99, 0xF0D48B, 0x8FBDFF, 0xD8AAF5, 0x90E1E8, 0xF3F3F6,
    ]
    static let lightPalette: [UInt32] = [
        0x1F1F24, 0xC4332C, 0x2B8A3E, 0x9A6A00, 0x1F5FD1, 0x8E3FB5, 0x0F7F8C, 0x8A8A92,
        0x5E5E66, 0xE0453D, 0x37A34E, 0xB98200, 0x3B7BEF, 0xA955D6, 0x1597A6, 0xB8B8BE,
    ]
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
            })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension AgentState {
    /// What the conversation's title says under the row's name.
    var phrase: String {
        switch self {
        case .none: "idle"
        case .working: "working"
        case .waiting: "waiting for you"
        case .done: "done"
        case .background: "running in the background"
        }
    }
}
