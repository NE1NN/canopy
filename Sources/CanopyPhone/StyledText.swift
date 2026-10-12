import Foundation

public enum TerminalColor: Equatable, Hashable, Sendable {
    /// One of the 256 palette colors; 0 to 15 are the ANSI colors the app's palette draws.
    case ansi(Int)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TerminalStyle: Equatable, Hashable, Sendable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var crossedOut = false

    public init(
        foreground: TerminalColor? = nil, background: TerminalColor? = nil, bold: Bool = false, dim: Bool = false,
        italic: Bool = false, underline: Bool = false, inverse: Bool = false, crossedOut: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
        self.crossedOut = crossedOut
    }
}

public struct StyledRun: Equatable, Hashable, Sendable {
    public var text: String
    public var style: TerminalStyle

    public init(text: String, style: TerminalStyle) {
        self.text = text
        self.style = style
    }
}

/// A screen line from the Mac, with its SGR escape sequences, as runs of one style each.
public enum StyledText {
    public static func runs(_ line: String) -> [StyledRun] {
        var runs: [StyledRun] = []
        var style = TerminalStyle()
        var text = ""
        var scalars = line.unicodeScalars[...]

        func flush() {
            guard !text.isEmpty else { return }
            if runs.last?.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append(StyledRun(text: text, style: style))
            }
            text = ""
        }

        while let scalar = scalars.popFirst() {
            guard scalar == "\u{1b}" else {
                text.unicodeScalars.append(scalar)
                continue
            }
            // Only CSI sequences are kept; a sequence cut off at the end goes with nothing after it.
            guard scalars.first == "[" else {
                _ = scalars.popFirst()
                continue
            }
            scalars.removeFirst()
            var parameters = ""
            var final: Unicode.Scalar?
            while let next = scalars.popFirst() {
                if (0x40...0x7E).contains(next.value) {
                    final = next
                    break
                }
                parameters.unicodeScalars.append(next)
            }
            guard final == "m" else { continue }
            flush()
            apply(parameters, to: &style)
        }
        flush()
        return runs
    }

    private static func apply(_ parameters: String, to style: inout TerminalStyle) {
        var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }[...]
        if codes.isEmpty { codes = [0] }
        while let code = codes.popFirst() {
            switch code {
            case 0: style = TerminalStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.crossedOut = true
            case 22:
                style.bold = false
                style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.crossedOut = false
            case 30...37: style.foreground = .ansi(code - 30)
            case 38: style.foreground = extended(&codes)
            case 39: style.foreground = nil
            case 40...47: style.background = .ansi(code - 40)
            case 48: style.background = extended(&codes)
            case 49: style.background = nil
            case 90...97: style.foreground = .ansi(code - 90 + 8)
            case 100...107: style.background = .ansi(code - 100 + 8)
            default: break
            }
        }
    }

    /// `5;n` for a palette color, `2;r;g;b` for a true color.
    private static func extended(_ codes: inout ArraySlice<Int>) -> TerminalColor? {
        switch codes.popFirst() {
        case 5:
            guard let index = codes.popFirst(), (0...255).contains(index) else { return nil }
            return .ansi(index)
        case 2:
            guard codes.count >= 3 else {
                codes = []
                return nil
            }
            let parts = (0..<3).map { _ in UInt8(clamping: codes.popFirst() ?? 0) }
            return .rgb(parts[0], parts[1], parts[2])
        default:
            return nil
        }
    }
}
