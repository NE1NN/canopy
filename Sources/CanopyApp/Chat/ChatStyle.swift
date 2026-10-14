import AppKit
import SwiftUI

/// A chat's sizes and colors, from the approved mockup's boards, with light colors that keep the same steps.
enum ChatStyle {
    /// The conversation's column, centered in the tab.
    static let columnWidth = 720.0
    static let sidePadding = 24.0
    static let rowSpacing = 12.0
    static let topPadding = 22.0

    static let text = Font.system(size: 13.5)
    /// SwiftUI's default line height for 13.5 pt, about 16 pt, plus this makes the mockup's 1.58.
    static let textLineSpacing = 5.0
    static let bubbleLineSpacing = 4.0
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)
    static let toolLine = Font.system(size: 12.5)
    static let meta = Font.system(size: 12)

    /// The terminal's own background, so chat and terminal tabs read as one app.
    static let background = Color.adaptive(light: 0xFFFFFF, dark: 0x161618)
    static let primaryText = Color.adaptive(light: 0x1F1F24, dark: 0xE5E5E7)
    static let strongText = Color.adaptive(light: 0x101014, dark: 0xF2F2F7)
    static let secondaryText = Color.adaptive(light: 0x6E6E73, dark: 0xA1A1A6)
    static let tertiaryText = Color.adaptive(light: 0x8E8E93, dark: 0x6E6E73)

    static let bubble = Color.adaptive(light: 0xEFEFF2, dark: 0x2F2F32)
    static let inlineCode = Color.adaptive(
        light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.08))
    static let toolIcon = Color.adaptive(
        light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.07))
    static let cardFill = Color.adaptive(light: 0xF7F7F9, dark: 0x232326)
    static let cardBorder = Color.adaptive(
        light: NSColor.black.withAlphaComponent(0.1), dark: NSColor.white.withAlphaComponent(0.09))
    static let codeFill = Color.adaptive(light: 0xF5F5F7, dark: 0x1C1C1F)

    static let composerFill = Color.adaptive(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let composerBorder = Color.adaptive(
        light: NSColor.black.withAlphaComponent(0.13), dark: NSColor.white.withAlphaComponent(0.11))
    static let chipFill = Color.adaptive(
        light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.07))
    static let chipText = Color.adaptive(light: 0x3A3A3C, dark: 0xC7C7CC)
    static let buttonFill = Color.adaptive(
        light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.09))
    /// Stop: the strongest button, inverted from the background.
    static let stopFill = Color.adaptive(light: 0x1C1C1F, dark: 0xF2F2F7)
    static let stopText = Color.adaptive(light: 0xFFFFFF, dark: 0x1C1C1F)

    /// Claude's own orange, for Working.
    static let working = Color.adaptive(light: 0xC2603F, dark: 0xD97757)
    static let askBorder = Color.adaptive(
        light: NSColor(hex: 0xD49A00).withAlphaComponent(0.45), dark: NSColor(hex: 0xFFD60A).withAlphaComponent(0.35))
    static let askFill = Color.adaptive(light: 0xFFFBEA, dark: 0x26251F)
    static let added = Color.adaptive(light: 0x1F8A3E, dark: 0x30D158)
    static let removed = Color.adaptive(light: 0xD1342C, dark: 0xFF6961)
    static let failureBorder = Color.adaptive(
        light: NSColor(hex: 0xD1342C).withAlphaComponent(0.4), dark: NSColor(hex: 0xFF6961).withAlphaComponent(0.35))
    static let failureFill = Color.adaptive(light: 0xFFF3F2, dark: 0x2A1E1E)
    /// A published artifact's card, in the system blue.
    static let artifactBorder = Color.adaptive(
        light: NSColor(hex: 0x0A84FF).withAlphaComponent(0.45), dark: NSColor(hex: 0x0A84FF).withAlphaComponent(0.55))
    static let artifactFill = Color.adaptive(
        light: NSColor(hex: 0x0A84FF).withAlphaComponent(0.06), dark: NSColor(hex: 0x0A84FF).withAlphaComponent(0.08))
    static let artifactLink = Color.adaptive(light: 0x0A6CFF, dark: 0x4DA3FF)
    static let replacedFill = Color.adaptive(
        light: NSColor.black.withAlphaComponent(0.025), dark: NSColor.white.withAlphaComponent(0.03))
    static let thumbnailFill = Color.adaptive(light: 0xE9E9EC, dark: 0x2A2A2D)
    static let thumbnailTile = Color.adaptive(light: 0xD6D6DA, dark: 0x3A3A3D)
}

/// A key's name in a small outlined box, as in "Allow ⏎".
struct KeyHint: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10.5))
            .padding(.horizontal, 4)
            .frame(height: 15)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
            .opacity(0.8)
    }
}
