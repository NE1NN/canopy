import AppKit
import CanopyCore
import SwiftTerm

/// SwiftTerm behind Canopy's emulator interface. Nothing else in Canopy imports SwiftTerm.
@MainActor
final class SwiftTermEmulator: NSObject, TerminalEmulator, @preconcurrency TerminalViewDelegate {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let scrollback = 10_000

    /// The size of one character cell in the terminal font.
    static let cellSize: CGSize = {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: width, height: ceil(font.ascender - font.descender + font.leading))
    }()

    /// The 16 ANSI colors, softened for a dark background.
    private static let darkPalette = colors([
        0x3A3A40, 0xF2736B, 0x7CCD80, 0xE3C46D, 0x72AAF6, 0xC895EA, 0x6DD0D9, 0xC9C9CE,
        0x6A6A72, 0xFF8C85, 0x97DE99, 0xF0D48B, 0x8FBDFF, 0xD8AAF5, 0x90E1E8, 0xF3F3F6,
    ])

    /// The 16 ANSI colors, deepened so each still reads on white.
    private static let lightPalette = colors([
        0x1F1F24, 0xC4332C, 0x2B8A3E, 0x9A6A00, 0x1F5FD1, 0x8E3FB5, 0x0F7F8C, 0x8A8A92,
        0x5E5E66, 0xE0453D, 0x37A34E, 0xB98200, 0x3B7BEF, 0xA955D6, 0x1597A6, 0xB8B8BE,
    ])

    private static func colors(_ hexes: [UInt32]) -> [SwiftTerm.Color] {
        hexes.map { Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) }
    }

    /// The width SwiftTerm keeps free for its scroller at the right edge.
    static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)

    let view: NSView
    private let terminalView: TerminalView
    private(set) var background = NSColor.textBackgroundColor
    var onInput: ((Data) -> Void)?
    var onResize: ((TerminalSize) -> Void)?
    var onTitle: ((String) -> Void)?
    var onOpenLink: ((String) -> Void)?

    init(size: TerminalSize) {
        terminalView = TerminalView(
            frame: .zero, font: Self.font,
            options: TerminalOptions(cols: size.columns, rows: size.rows, scrollback: Self.scrollback))
        view = terminalView
        super.init()
        terminalView.terminalDelegate = self
        // Panes read the zsh shim's command reports from the output before it gets here.
        terminalView.getTerminal().registerOscHandler(code: ZshIntegration.reportCode) { _ in }
        scroller?.alphaValue = 0
        applyAppearance(NSApp.effectiveAppearance)
    }

    var size: TerminalSize {
        let terminal = terminalView.getTerminal()
        return TerminalSize(columns: terminal.cols, rows: terminal.rows)
    }

    /// The live screen, whatever the user has scrolled to.
    func screenText() -> String {
        TerminalText.trimmingTrailingBlankLines(lastLines(terminalView.getTerminal().rows)).joined(separator: "\n")
    }

    func recentText(lines count: Int) -> String {
        TerminalText.trimmingTrailingBlankLines(lastLines(max(count, 0))).joined(separator: "\n")
    }

    /// The last `count` lines of the buffer, scrollback included. Only those lines are turned into text.
    private func lastLines(_ count: Int) -> [String] {
        let terminal = terminalView.getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        var end = first
        while terminal.getScrollInvariantLine(row: end) != nil {
            end += 1
        }
        return (max(first, end - count)..<end).map { row in
            // Map cells through the terminal so wide and combined characters survive and empty cells read as spaces.
            terminal.getScrollInvariantLine(row: row)?.translateToString(
                trimRight: true, skipNullCellsFollowingWide: true
            ) { cell in
                let character = terminal.getCharacter(for: cell)
                return character == "\0" ? " " : character
            } ?? ""
        }
    }

    /// Gives the terminal the keyboard, if it is on screen.
    func focus() {
        view.window?.makeFirstResponder(view)
    }

    func feed(_ data: Data) {
        terminalView.feed(byteArray: [UInt8](data)[...])
    }

    /// Colors follow the system's light or dark appearance. In dark, the terminal sits a step below the window's
    /// chrome, so panes have an edge.
    func applyAppearance(_ appearance: NSAppearance) {
        let isDark = appearance.isDark
        background = NSColor(hex: isDark ? 0x161618 : 0xFFFFFF)
        terminalView.nativeForegroundColor = NSColor(hex: isDark ? 0xDCDCE1 : 0x1F1F24)
        terminalView.nativeBackgroundColor = background
        terminalView.installColors(isDark ? Self.darkPalette : Self.lightPalette)
    }

    /// SwiftTerm keeps its scroller private, so it is found among the view's subviews.
    private var scroller: NSScroller? {
        terminalView.subviews.lazy.compactMap { $0 as? NSScroller }.first
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(TerminalSize(columns: newCols, rows: newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    /// The scroller shows only while the view is scrolled back from the bottom, into the scrollback.
    func scrolled(source: TerminalView, position: Double) {
        // Full-screen programs such as less and vim cannot scroll back, and report position 0 there.
        let isScrolledBack = position < 1 && terminalView.canScroll
        guard let scroller, (scroller.alphaValue > 0) != isScrolledBack else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isScrolledBack ? 0.1 : 0.4
            scroller.animator().alphaValue = isScrolledBack ? 1 : 0
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// A file path ⌘-clicked in a terminal opens with its app, as SwiftTerm opens it.
    static func openPath(_ path: String) {
        TerminalView.openDefaultLink(path)
    }

    /// ⌘-click. The pane's row decides where the link goes.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        onOpenLink?(link)
    }

    /// OSC 52, which editors and tmux use to copy.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SwiftTermEngine: TerminalEngine {
    func makeEmulator(size: TerminalSize) -> any TerminalEmulator {
        SwiftTermEmulator(size: size)
    }
}
