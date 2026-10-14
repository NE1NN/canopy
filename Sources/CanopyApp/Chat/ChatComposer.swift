import AppKit
import CanopyCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The box at the bottom of a chat: what the author writes, then Stop or Send.
struct ChatComposer: View {
    let chat: ChatSession
    let composers: ChatComposers
    let paneID: PaneID
    var onTrust: () -> Void = {}
    var onDeclineTrust: () -> Void = {}
    var onTerminalCommand: (String) -> Void = { _ in }
    var onResume: () -> Void = {}
    @State private var menuSelection = 0
    @State private var height = ChatComposer.lineHeight

    static let lineHeight = 21.0
    static let maxHeight = 220.0

    var body: some View {
        @Bindable var chat = chat
        VStack(alignment: .leading, spacing: 8) {
            if !menuItems.isEmpty {
                CommandMenu(items: menuItems, selection: min(menuSelection, menuItems.count - 1), pick: run)
                    .onChange(of: chat.draft) { menuSelection = 0 }
            }
            if !chat.draftImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chat.draftImages) { image in
                            ImageThumbnail(image: image) { chat.draftImages.removeAll { $0.id == image.id } }
                        }
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text(placeholder)
                        .font(ChatStyle.text)
                        .foregroundStyle(ChatStyle.tertiaryText)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $chat.draft, height: $height, paneID: paneID, composers: composers,
                    onReturn: submit, onEscape: escape, onDigit: digit, onArrow: arrow,
                    onImage: { chat.draftImages.append($0) }
                )
                .frame(height: min(max(height, Self.lineHeight), Self.maxHeight))
            }
            HStack(spacing: 6) {
                if chat.draft.hasPrefix("!") {
                    Text(verbatim: "$ shell command")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ChatStyle.chipText)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(ChatStyle.chipFill, in: RoundedRectangle(cornerRadius: 7))
                }
                ChatChips(chat: chat)
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
        // A message waiting on trust shows at full strength: Return trusts the folder and sends it.
        .opacity(chat.needsTrust && chat.draft.isEmpty && chat.draftImages.isEmpty ? 0.5 : 1)
    }

    private var placeholder: String {
        if chat.isRunningShell { return "Running your command. Esc stops it." }
        if case .question? = chat.permission?.kind { return "Or answer in your own words" }
        if case .plan? = chat.permission?.kind { return "Or tell Claude what to change" }
        if chat.permission != nil { return "Or tell Claude what to do instead" }
        if chat.isWorking { return "Reply to Claude. It reads this when the current step ends." }
        return "Reply to Claude"
    }

    private var hasDraft: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.draftImages.isEmpty
    }

    /// A `!` command typed while another runs stays in the composer until it can run.
    private var canSend: Bool {
        !chat.needsTrust && hasDraft && chat.takes(chat.draft)
    }

    private func send() {
        guard canSend else { return }
        let (text, images) = (chat.draft, chat.draftImages)
        chat.draft = ""
        chat.draftImages = []
        chat.send(text, images: images)
    }

    /// The `/` menu's entries while the draft is a slash and a name, with nothing after it yet.
    private var menuItems: [ChatMenuItem] {
        let draft = chat.draft
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return [] }
        return Array(
            ChatCommandMenu.items(
                commands: chat.commands, terminal: chat.terminalCommands, typed: String(draft.dropFirst())
            )
            .prefix(8))
    }

    private func arrow(_ step: Int) -> Bool {
        guard !menuItems.isEmpty else { return false }
        menuSelection = (min(menuSelection, menuItems.count - 1) + step + menuItems.count) % menuItems.count
        return true
    }

    /// Runs a menu entry: in a terminal when it needs the full screen, the conversation sheet for /resume, or else
    /// into the composer when it takes an argument, or straight to Claude.
    private func run(_ item: ChatMenuItem) {
        menuSelection = 0
        if item.name == "resume" {
            chat.draft = ""
            onResume()
        } else if item.opensInTerminal {
            chat.draft = ""
            onTerminalCommand("/" + item.name)
        } else if !item.argumentHint.isEmpty {
            chat.draft = "/" + item.name + " "
        } else if chat.needsTrust {
            // Trusting sends the draft, so the command waits in it.
            chat.draft = "/" + item.name
            onTrust()
        } else {
            chat.draft = ""
            chat.send("/" + item.name)
        }
    }

    /// Return sends what is written; with nothing written it allows an open prompt.
    private func submit() {
        if !menuItems.isEmpty {
            run(menuItems[min(menuSelection, menuItems.count - 1)])
            return
        }
        if chat.needsTrust {
            onTrust()
        } else if hasDraft {
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
        guard chat.draft.isEmpty, case .question? = chat.permission?.kind, chat.canPick(number - 1) else {
            return false
        }
        chat.pick(number - 1)
        return true
    }

    /// Esc closes the `/` menu, turns down trust, stops a shell command, denies an open prompt, or stops Claude.
    private func escape() {
        if !menuItems.isEmpty {
            chat.draft = ""
        } else if chat.isRunningShell {
            chat.stopShell()
        } else if chat.needsTrust {
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
    /// Takes an image pasted or dropped in, as PNG.
    var onImage: (ChatImage) -> Void = { _ in }

    override func paste(_ sender: Any?) {
        if takeImages(from: .general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if takeImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Image files dropped or pasted, or image data, prepared off the main thread. False when there were none, and
    /// when the pasteboard holds text as well, which an app that copies a picture alongside its text means as text.
    private func takeImages(from pasteboard: NSPasteboard) -> Bool {
        let urls =
            (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
            .filter { ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"].contains($0.pathExtension.lowercased()) }
            ?? []
        var sources = urls.compactMap { try? Data(contentsOf: $0) }
        if sources.isEmpty, pasteboard.string(forType: .string) == nil,
            let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        {
            sources = [data]
        }
        guard !sources.isEmpty else { return false }
        let datas = sources
        Task { [weak self] in
            let images = await Task.detached { datas.compactMap(ChatImagePrep.prepare) }.value
            for image in images { self?.onImage(image) }
        }
        return true
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func keyDown(with event: NSEvent) {
        // An input method choosing a candidate with a digit keeps it.
        if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
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
    let onArrow: (Int) -> Bool
    let onImage: (ChatImage) -> Void

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
        view.onImage = { [weak coordinator = context.coordinator] in coordinator?.parent.onImage($0) }
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
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
            case #selector(NSResponder.moveUp(_:)):
                return parent.onArrow(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onArrow(1)
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

/// The mode and model chips, and how much of the context the conversation uses.
private struct ChatChips: View {
    let chat: ChatSession

    private static let modes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Self.modes, id: \.self) { mode in
                    Button {
                        chat.setMode(mode)
                    } label: {
                        if mode == chat.mode {
                            Label(ChatFormat.modeName(mode), systemImage: "checkmark")
                        } else {
                            Text(ChatFormat.modeName(mode))
                        }
                    }
                }
            } label: {
                chip(ChatFormat.modeName(chat.mode), symbol: Self.symbol(chat.mode), tint: Self.tint(chat.mode))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Permission mode")
            Menu {
                ForEach(chat.models, id: \.value) { model in
                    Button(model.displayName) { chat.setModel(model.value) }
                }
            } label: {
                chip(chat.model.map(ChatFormat.modelName) ?? "Default model", symbol: nil, tint: nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Model")
            if let used = chat.contextTokens, let window = chat.contextWindow {
                Text(ChatFormat.context(used: used, window: window))
                    .font(.system(size: 11.5))
                    .foregroundStyle(ChatStyle.tertiaryText)
                    .padding(.leading, 4)
            }
        }
    }

    private func chip(_ title: String, symbol: String?, tint: Color?) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).foregroundStyle(tint ?? ChatStyle.chipText) }
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(ChatStyle.chipText)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(ChatStyle.chipFill, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private static func symbol(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": "pencil"
        case "plan": "list.bullet.clipboard"
        case "auto": "sparkles"
        case "bypassPermissions": "chevron.forward.2"
        default: "hand.raised"
        }
    }

    private static func tint(_ mode: String) -> Color? {
        mode == "bypassPermissions" ? ChatStyle.removed : nil
    }
}

/// A pasted image waiting to be sent, with a button that takes it out.
private struct ImageThumbnail: View {
    let image: ChatImage
    let remove: () -> Void

    /// Decoded once per image, not on every keystroke's redraw.
    @MainActor private static var pictures: [UUID: NSImage] = [:]

    @MainActor static func picture(_ image: ChatImage) -> NSImage? {
        if let picture = pictures[image.id] { return picture }
        let picture = NSImage(data: image.data)
        if pictures.count > 32 { pictures = [:] }
        pictures[image.id] = picture
        return picture
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let picture = ImageThumbnail.picture(image) {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
            .help("Remove")
        }
    }
}

/// Makes an image fit for Claude: at most 1568 pixels on its long side, as PNG, or JPEG when that is under 5 MB and
/// PNG is not.
enum ChatImagePrep {
    static let longSide = 1568
    static let limit = 5 * 1024 * 1024

    static func prepare(_ data: Data) -> ChatImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: longSide,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { return nil }
        if let png = encode(image, "public.png", quality: nil), png.count < limit {
            return ChatImage(mediaType: "image/png", data: png)
        }
        guard let jpeg = encode(image, "public.jpeg", quality: 0.85), jpeg.count < limit else { return nil }
        return ChatImage(mediaType: "image/jpeg", data: jpeg)
    }

    private static func encode(_ image: CGImage, _ type: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The `/` menu above the composer: commands, then skills, the picked one highlighted.
private struct CommandMenu: View {
    let items: [ChatMenuItem]
    let selection: Int
    let pick: (ChatMenuItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    pick(item)
                } label: {
                    HStack(spacing: 10) {
                        Text("/" + item.name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        Text(item.description).font(.system(size: 12)).foregroundStyle(ChatStyle.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        if item.opensInTerminal {
                            Text("Opens in Terminal").font(.system(size: 11)).foregroundStyle(ChatStyle.tertiaryText)
                        } else if item.isSkill {
                            Text("Skill").font(.system(size: 11)).foregroundStyle(ChatStyle.tertiaryText)
                        }
                    }
                    .foregroundStyle(ChatStyle.primaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        index == selection ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("↑↓ to pick · ⏎ to run · start with ! to run a shell command")
                .font(.system(size: 11))
                .foregroundStyle(ChatStyle.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
        .padding(.bottom, 4)
    }
}
