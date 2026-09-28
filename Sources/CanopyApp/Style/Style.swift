import AppKit
import CanopyCore
import SwiftUI

/// Canopy's one scale for type, sizes, and fills. Views take their numbers from here rather than picking their own.
enum Style {
    /// Uppercase section labels, such as Repos and Ports.
    static let label = Font.system(size: 10.5, weight: .semibold)
    static let labelTracking = 0.6
    /// PR numbers, ports, pane titles, shortcut hints, and tags.
    static let meta = Font.system(size: 11)
    /// Tabs, repo names, port groups, and other worktrees.
    static let body = Font.system(size: 12)
    /// Branch names.
    static let row = Font.system(size: 13)

    static let rowHeight = 26.0
    /// How far a group's rows sit in, so their marks line up under the group's name.
    static let groupIndent = 24.0
    static let headerHeight = 28.0
    /// The window toolbar's height, so the tabs line up with the traffic lights.
    static let topBarHeight = 52.0
    static let tabHeight = 26.0
    static let paneHeaderHeight = 26.0

    static let cornerRadius = 6.0
    static let badgeRadius = 5.0
    static let tagRadius = 4.0

    static let hoverFill = Color.adaptive(
        light: .black.withAlphaComponent(0.045), dark: .white.withAlphaComponent(0.055))
    static let selectionFill = Color.adaptive(
        light: .black.withAlphaComponent(0.075), dark: .white.withAlphaComponent(0.1))
    /// The selection while its list has the keyboard, like Finder's, but tinted so PR colors stay readable.
    static let focusedSelectionFill = Color(
        nsColor: NSColor(name: nil) { appearance in
            NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.3 : 0.17)
        })
    /// The top bar, pane headers, and exit strips: a step off the terminal's white in light, the window's own gray
    /// in dark, where the terminal is the darker one.
    static let chrome = Color(
        nsColor: NSColor(name: nil) { $0.isDark ? .windowBackgroundColor : NSColor(hex: 0xF5F5F7) })
    static let badgeFill = Color.adaptive(
        light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.075))

    /// The hues a repo's tile can take, indexed by `RepoMark.hue`.
    static let tileHues: [Color] = [
        .adaptive(light: 0x5257D6, dark: 0x8B8FF8),
        .adaptive(light: 0x0E8A7B, dark: 0x40C8B4),
        .adaptive(light: 0xA86D00, dark: 0xE8B04A),
        .adaptive(light: 0xC43A62, dark: 0xF07A9A),
        .adaptive(light: 0x1F78C2, dark: 0x5CB3F0),
        .adaptive(light: 0x4D8A16, dark: 0x9CCC5A),
        .adaptive(light: 0x8A44C9, dark: 0xC38AF0),
        .adaptive(light: 0xC2512A, dark: 0xF08A60),
    ]
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        adaptive(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// An uppercase section label with its actions at the trailing end.
struct SectionLabel<Actions: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Style.label)
                .tracking(Style.labelTracking)
                .textCase(.uppercase)
            if let count {
                Text(verbatim: "\(count)")
                    .font(Style.label.weight(.medium))
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            actions
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: Style.headerHeight)
    }
}

/// A borderless icon button that shows a fill on hover.
struct IconButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    var size = 22.0
    var imageSize = 12.0
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: imageSize, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: size > 22 ? 6 : 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}

/// A borderless icon that opens a menu, drawn like `IconButton`.
struct IconMenu<Items: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var items: Items
    @State private var isHovering = false

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(isHovering ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The accent dot that marks a program running in a row, tab, or pane.
struct RunningDot: View {
    var size = 6.0

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor.opacity(0.22)).padding(-2.5))
            .accessibilityLabel("A program is running")
    }
}

/// A small outlined label, such as "missing" or the tool that made a worktree.
struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Style.badgeFill, in: RoundedRectangle(cornerRadius: Style.tagRadius))
            .overlay(RoundedRectangle(cornerRadius: Style.tagRadius).strokeBorder(.separator))
    }
}

/// A repo's letter on a tile of its hue.
struct RepoTile: View {
    let mark: RepoMark
    var isDimmed = false

    var body: some View {
        let hue = Style.tileHues[mark.hue % Style.tileHues.count]
        Text(verbatim: mark.letter)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(hue)
            .frame(width: 16, height: 16)
            .background(hue.opacity(0.2), in: RoundedRectangle(cornerRadius: Style.tagRadius))
            .overlay(RoundedRectangle(cornerRadius: Style.tagRadius).strokeBorder(hue.opacity(0.35), lineWidth: 0.5))
            .opacity(isDimmed ? 0.5 : 1)
            .accessibilityHidden(true)
    }
}
