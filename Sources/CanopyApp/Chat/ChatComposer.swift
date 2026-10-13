import AppKit
import CanopyCore
import SwiftUI

/// The box at the bottom of a chat: what the author writes, then Stop or Send.
struct ChatComposer: View {
    let chat: ChatSession
    let composers: ChatComposers
    let paneID: PaneID
    var onTrust: () -> Void = {}
    var onDeclineTrust: () -> Void = {}
    @State private var height = ChatComposer.lineHeight

    static let lineHeight = 21.0
    static let maxHeight = 220.0

    var body: some View {
        @Bindable var chat = chat
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text(placeholder)
                        .font(ChatStyle.text)
                        .foregroundStyle(ChatStyle.tertiaryText)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $chat.draft, height: $height, paneID: paneID, composers: composers,
                    onReturn: submit, onEscape: escape, onDigit: digit
                )
                .frame(height: min(max(height, Self.lineHeight), Self.maxHeight))
            }
            HStack(spacing: 6) {
                Spacer()
                if chat.isWorking && chat.permission == nil {
                    Button(action: chat.interrupt) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 8))
                            Text("Stop")
                            KeyHint(key: "esc")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChatStyle.stopText)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(ChatStyle.stopFill, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop Claude (esc)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(canSend ? Color.white : ChatStyle.tertiaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                canSend ? Color.accentColor : ChatStyle.chipFill, in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (⏎)")
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(ChatStyle.composerFill, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ChatStyle.composerBorder))
        .frame(maxWidth: ChatStyle.columnWidth)
        .padding(.horizontal, ChatStyle.sidePadding)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .opacity(chat.needsTrust ? 0.5 : 1)
    }

    private var placeholder: String {
        if case .question? = chat.permission?.kind { return "Or answer in your own words" }
        if case .plan? = chat.permission?.kind { return "Or tell Claude what to change" }
        if chat.permission != nil { return "Or tell Claude what to do instead" }
        if chat.isWorking { return "Reply to Claude. It reads this when the current step ends." }
        return "Reply to Claude"
    }

    private var canSend: Bool {
        !chat.needsTrust && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = chat.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.draft = ""
        chat.send(text)
    }

    /// Return sends what is written; with nothing written it allows an open prompt.
    private func submit() {
        if chat.needsTrust {
            onTrust()
        } else if canSend {
            send()
        } else if let permission = chat.permission {
            switch permission.kind {
            case .permission: chat.allow()
            case .question: chat.submitSelection()
            case .plan: chat.approvePlan(acceptingEdits: true)
            }
        }
    }

    /// With nothing written, a digit picks an option of an open question.
    private func digit(_ number: Int) -> Bool {
        guard chat.draft.isEmpty, case .question? = chat.permission?.kind else { return false }
        chat.pick(number - 1)
        return true
    }

    /// Esc turns down trust, denies an open prompt, or stops Claude.
    private func escape() {
        if chat.needsTrust {
            onDeclineTrust()
        } else if chat.permission != nil {
            chat.deny()
        } else if chat.isWorking {
            chat.interrupt()
        }
    }
}

/// The text views of open chats, so the app can hand one the keyboard.
@MainActor
final class ChatComposers {
    private var views: [PaneID: WeakTextView] = [:]
    /// Panes asked to take the keyboard before their text view was in a window.
    private var waiting: Set<PaneID> = []

    private struct WeakTextView {
        weak var view: NSTextView?
    }

    func register(_ view: NSTextView, for pane: PaneID) {
        views[pane] = WeakTextView(view: view)
    }

    func focus(_ pane: PaneID) {
        guard let view = views[pane]?.view, let window = view.window else {
            waiting.insert(pane)
            return
        }
        waiting.remove(pane)
        window.makeFirstResponder(view)
    }

    /// A text view joined its window, so a focus asked for earlier happens now.
    func joinedWindow(_ pane: PaneID) {
        if waiting.contains(pane) { focus(pane) }
    }
}

/// The composer's text view, which says when it joins a window so it can take the keyboard then.
final class ComposerNSTextView: NSTextView {
    var onWindow: () -> Void = {}
    /// Takes a digit pressed with no modifiers before it is typed; true when it was used.
    var onDigit: (Int) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let characters = event.charactersIgnoringModifiers, characters.count == 1,
            let number = Int(characters), (1...9).contains(number), onDigit(number)
        {
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow() }
    }
}

/// A plain multi-line text view: Return submits, ⇧Return and ⌥Return add a line, Esc escapes.
private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: Double
    let paneID: PaneID
    let composers: ChatComposers
    let onReturn: () -> Void
    let onEscape: () -> Void
    let onDigit: (Int) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = ComposerNSTextView()
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        let (pane, composers) = (paneID, self.composers)
        view.onWindow = { composers.joinedWindow(pane) }
        view.onDigit = { [weak coordinator = context.coordinator] in coordinator?.parent.onDigit($0) ?? false }
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 13.5)
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.typingAttributes[.paragraphStyle] = paragraph
        view.string = text
        composers.register(view, for: paneID)
        DispatchQueue.main.async { context.coordinator.measure(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        context.coordinator.measure(view)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            measure(view)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onReturn()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }

        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let height = max(ChatComposer.lineHeight, ceil(used))
            if parent.height != height { parent.height = height }
        }
    }
}
