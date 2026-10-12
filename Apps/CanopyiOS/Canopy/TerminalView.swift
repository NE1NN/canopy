import CanopyPhone
import SwiftUI
import UIKit

/// The pane's screen at the Mac's width, scrolling sideways and pinching to zoom, with a key bar and the keyboard.
struct TerminalView: View {
    var model: TerminalModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var fontSize: CGFloat = 10.5
    @GestureState private var pinch: CGFloat = 1
    @State private var typing = false

    private var size: CGFloat { min(20, max(6, fontSize * pinch)) }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    Text(attributed(line))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: size * 1.38, alignment: .leading)
                }
            }
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(Theme.terminalText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottomLeading)
        .defaultScrollAnchor(.bottomLeading, for: .sizeChanges)
        .background(Theme.terminal)
        .overlay {
            if let problem = model.problem, !model.hasLoaded {
                ContentUnavailableView(problem.title, systemImage: "terminal", description: Text(problem.detail))
            } else if !model.hasLoaded {
                ProgressView()
            }
        }
        .gesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in fontSize = min(20, max(6, fontSize * value.magnification)) }
        )
        .onTapGesture { typing = true }
        .accessibilityIdentifier("terminal")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let problem = model.problem, model.hasLoaded {
                    Text(problem.title)
                        .font(.footnote)
                        .foregroundStyle(Theme.red)
                        .padding(.vertical, 4)
                }
                KeyBar(model: model, typing: $typing)
            }
            .background(KeyInput(model: model, typing: $typing).frame(width: 1, height: 1).opacity(0.01))
        }
    }

    private func attributed(_ runs: [StyledRun]) -> AttributedString {
        var line = AttributedString()
        for run in runs {
            var part = AttributedString(Self.textPresentation(run.text))
            var foreground = run.style.foreground.map(color)
            var background = run.style.background.map(color)
            if run.style.inverse {
                (foreground, background) = (background ?? Theme.terminal, foreground ?? Theme.terminalText)
            }
            if let foreground { part.foregroundColor = foreground }
            if let background { part.backgroundColor = background }
            if run.style.bold { part.inlinePresentationIntent = .stronglyEmphasized }
            if run.style.italic { part.inlinePresentationIntent = [part.inlinePresentationIntent ?? [], .emphasized] }
            if run.style.underline { part.underlineStyle = .single }
            if run.style.crossedOut { part.strikethroughStyle = .single }
            if run.style.dim { part.foregroundColor = (foreground ?? Theme.terminalText).opacity(0.5) }
            line += part
        }
        return line
    }

    /// Symbols such as Claude Code's ⏺ draw as emoji unless asked for their text form, as a terminal draws them.
    private static func textPresentation(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        var next = iterator.next()
        while let scalar = next {
            next = iterator.next()
            scalars.append(scalar)
            if scalar.properties.isEmoji, scalar.value > 0xFF, next != "\u{FE0F}", next != "\u{FE0E}" {
                scalars.append("\u{FE0E}")
            }
        }
        return String(scalars)
    }

    private func color(_ color: TerminalColor) -> Color {
        switch color {
        case .ansi(let index) where index < 16:
            let palette = colorScheme == .dark ? Theme.darkPalette : Theme.lightPalette
            return Color(uiColor: UIColor(hex: palette[index]))
        case .ansi(let index) where index < 232:
            let cube = index - 16
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return Color(
                red: levels[cube / 36] / 255, green: levels[cube / 6 % 6] / 255, blue: levels[cube % 6] / 255)
        case .ansi(let index):
            let gray = CGFloat(8 + (index - 232) * 10) / 255
            return Color(red: gray, green: gray, blue: gray)
        case .rgb(let red, let green, let blue):
            return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }
    }
}

/// esc, tab, ctrl, the arrows, and Return, which the iPhone keyboard has no keys for.
private struct KeyBar: View {
    var model: TerminalModel
    @Binding var typing: Bool

    var body: some View {
        HStack(spacing: 5) {
            key("esc") { model.press(.escape) }
            key("tab") { model.press(.tab) }
            Button {
                model.ctrl.toggle()
            } label: {
                Text("ctrl").frame(maxWidth: .infinity)
            }
            .buttonStyle(KeyStyle(on: model.ctrl))
            .accessibilityIdentifier("key-ctrl")
            key("↑", label: "Up") { model.press(.up) }
            key("↓", label: "Down") { model.press(.down) }
            key("⏎", label: "Return") { model.press(.enter) }
            Button {
                typing.toggle()
            } label: {
                Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KeyStyle(on: false))
            .accessibilityLabel(typing ? "Hide keyboard" : "Keyboard")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.card, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
    }

    private func key(_ title: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(KeyStyle(on: false))
        .accessibilityLabel(label ?? title)
        .accessibilityIdentifier("key-\(label ?? title)")
    }
}

private struct KeyStyle: ButtonStyle {
    var on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote)
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.vertical, 8)
            .background(
                on ? Theme.accent : configuration.isPressed ? Theme.separator : Theme.fill, in: .rect(cornerRadius: 6))
    }
}

/// A view the keyboard types into, which sends each key to the pane as it is typed.
private struct KeyInput: UIViewRepresentable {
    var model: TerminalModel
    @Binding var typing: Bool

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onText = { text in model.type(text) }
        view.onBackspace = { model.backspace() }
        view.onResign = { Task { @MainActor in typing = false } }
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onText = { text in model.type(text) }
        view.onBackspace = { model.backspace() }
        if typing, !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        } else if !typing, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }
}

final class KeyInputView: UIView, UIKeyInput {
    var onText: (String) -> Void = { _ in }
    var onBackspace: () -> Void = {}
    var onResign: () -> Void = {}

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    // A terminal wants what was typed, not what autocorrect thinks was meant.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        onText(text)
    }

    func deleteBackward() {
        onBackspace()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign() }
        return resigned
    }
}
