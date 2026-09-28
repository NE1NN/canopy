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

    /// Terminal.app's ANSI colors, which read well on light and dark backgrounds alike.
    private static let palette: [SwiftTerm.Color] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ].map { (rgb: (UInt16, UInt16, UInt16)) in Color(red8: rgb.0, green8: rgb.1, blue8: rgb.2) }

    let view: NSView
    private let terminalView: TerminalView
    private(set) var background = NSColor.textBackgroundColor
    var onInput: ((Data) -> Void)?
    var onResize: ((TerminalSize) -> Void)?
    var onTitle: ((String) -> Void)?

    init(size: TerminalSize) {
        terminalView = TerminalView(
            frame: .zero, font: Self.font,
            options: TerminalOptions(cols: size.columns, rows: size.rows, scrollback: Self.scrollback))
        view = terminalView
        super.init()
        terminalView.terminalDelegate = self
        // Panes read the zsh shim's command reports from the output before it gets here.
        terminalView.getTerminal().registerOscHandler(code: ZshIntegration.reportCode) { _ in }
        terminalView.installColors(Self.palette)
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

    /// Text and background follow the system's light or dark appearance.
    func applyAppearance(_ appearance: NSAppearance) {
        var foreground = NSColor.black
        var background = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            foreground = NSColor.textColor.usingColorSpace(.sRGB) ?? foreground
            background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? background
        }
        self.background = background
        terminalView.nativeForegroundColor = foreground
        terminalView.nativeBackgroundColor = background
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

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

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
