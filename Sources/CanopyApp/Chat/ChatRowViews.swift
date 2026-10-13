import CanopyCore
import SwiftUI

/// What the rows' buttons do, supplied by the chat view.
struct ChatActions {
    var trust: () -> Void
    var declineTrust: () -> Void
    /// Opens a published artifact in the row: beside the chat, or in a tab.
    var openArtifact: (ChatArtifact, WebPlacement) -> Void
    var openInBrowser: (URL) -> Void
}

/// One row of the conversation, laid out in the chat's centered column.
struct ChatRowView: View {
    let row: ChatRow
    let chat: ChatSession
    let actions: ChatActions

    var body: some View {
        content
            .frame(maxWidth: ChatStyle.columnWidth, alignment: .leading)
            .padding(.horizontal, ChatStyle.sidePadding)
            .padding(.bottom, ChatStyle.rowSpacing)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch row {
        case .empty:
            EmptyChatView()
        case .trust:
            TrustCard(onTrust: actions.trust, onDecline: actions.declineTrust)
        case .item(let item, let expanded):
            ChatItemView(item: item, expanded: expanded) { chat.toggle(item.id) }
        case .artifact(_, let artifact, let thumbnail):
            ArtifactCard(artifact: artifact, thumbnail: thumbnail, actions: actions)
        case .streaming(_, let block, _):
            MarkdownView(blocks: [block])
        case .queued(let queued):
            PromptBubble(prompt: queued.prompt, waitsForStep: queued.waitsForStep)
        case .permission(let permission, _, _):
            switch permission.kind {
            case .permission: PermissionCard(permission: permission, chat: chat)
            case .question(let questions): QuestionCard(questions: questions, chat: chat)
            case .plan(let plan): PlanCard(plan: plan, chat: chat)
            }
        case .failure(let failure):
            FailureCard(failure: failure, chat: chat)
        case .status:
            ChatStatusLine(chat: chat)
        case .running(_, let command, let lines, let started, _):
            RunningCard(command: command, lines: lines, started: started)
        }
    }
}

private struct ChatItemView: View {
    let item: ChatItem
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        switch item.content {
        case .prompt(let prompt):
            PromptBubble(prompt: prompt)
        case .text(let text):
            MarkdownView(blocks: text.blocks)
        case .tools(let group):
            ToolLine(group: group, expanded: expanded, toggle: toggle)
        case .edit(let call):
            EditCard(call: call, isOpen: expanded, toggle: toggle)
        case .question(let question):
            HistoryLine(
                symbol: "questionmark.bubble",
                text: "Asked: " + (question.questions.first?.question ?? "a question"),
                answer: question.answer)
        case .plan(let plan):
            HistoryLine(symbol: "list.bullet.clipboard", text: "Proposed a plan", answer: plan.answer)
                .help(plan.markdown)
        case .notice(let notice):
            NoticeLine(text: notice)
        case .shell(let shell):
            ShellBlock(shell: shell, expanded: expanded, toggle: toggle)
        case .artifact:
            // Drawn as a row of its own, with its snapshot.
            EmptyView()
        }
    }
}

/// The author's message, on the right.
struct PromptBubble: View {
    let prompt: ChatPrompt
    var waitsForStep = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if prompt.images > 0 {
                    Label(
                        prompt.images == 1 ? "1 image" : "\(prompt.images) images", systemImage: "photo"
                    )
                    .font(ChatStyle.meta)
                    .foregroundStyle(ChatStyle.secondaryText)
                }
                if !prompt.text.isEmpty {
                    Text(prompt.text)
                        .font(ChatStyle.text)
                        .lineSpacing(ChatStyle.bubbleLineSpacing)
                        .foregroundStyle(ChatStyle.strongText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(ChatStyle.bubble, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 520, alignment: .trailing)
            .opacity(waitsForStep ? 0.55 : 1)
            if waitsForStep {
                Text("Claude reads this when the current step ends")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatStyle.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A run of tool calls folded to one line: "Read TopBarView.swift and 3 more".
private struct ToolLine: View {
    let group: ChatToolGroup
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    DisclosureChevron(isExpanded: expanded)
                    Image(systemName: Self.symbol(group.kind))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ChatStyle.secondaryText)
                        .frame(width: 18, height: 18)
                        .background(ChatStyle.toolIcon, in: RoundedRectangle(cornerRadius: 5))
                    Text(group.summary + Self.innerCount(group))
                        .font(ChatStyle.toolLine)
                        .foregroundStyle(group.failed ? ChatStyle.removed : ChatStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if group.calls.contains(where: { $0.result == nil }) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.calls, id: \.id) { call in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.input(call))
                                .font(ChatStyle.monoSmall)
                                .foregroundStyle(ChatStyle.primaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let result = call.result, !result.isEmpty {
                                Text(Self.excerpt(result))
                                    .font(ChatStyle.monoSmall)
                                    .foregroundStyle(call.isError ? ChatStyle.removed : ChatStyle.tertiaryText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatStyle.cardFill, in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 26)
            }
        }
    }

    /// "· 4 tool calls" for subagents that made some.
    static func innerCount(_ group: ChatToolGroup) -> String {
        let count = group.calls.reduce(0) { $0 + $1.innerCalls }
        return count == 0 ? "" : " · \(count) tool call" + (count == 1 ? "" : "s")
    }

    /// What a call was asked to do: its command, file, pattern, or address, else its name.
    static func input(_ call: ChatToolCall) -> String {
        let keys = ["command", "file_path", "pattern", "url", "query", "description", "prompt"]
        let value = keys.lazy.compactMap { key -> String? in
            if case .string(let text)? = call.input[key] { text } else { nil }
        }.first
        return value.map { "\(call.name): \($0)" } ?? call.name
    }

    /// An output's first 12 lines, so a long one stays readable.
    static func excerpt(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.prefix(12).joined(separator: "\n")
        return lines.count > 12 ? kept + "\n… \(lines.count - 12) more lines" : kept
    }

    static func symbol(_ kind: TranscriptParser.ToolKind) -> String {
        switch kind {
        case .run: "terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .search: "magnifyingglass"
        case .fetch: "globe"
        case .webSearch: "magnifyingglass.circle"
        case .agent: "person.2"
        case .todo: "checklist"
        case .other: "wrench.and.screwdriver"
        }
    }
}

private struct HistoryLine: View {
    let symbol: String
    let text: String
    let answer: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 18, height: 18)
                .background(ChatStyle.toolIcon, in: RoundedRectangle(cornerRadius: 5))
            Text(text).lineLimit(1)
            if let answer {
                Text("· " + answer).foregroundStyle(ChatStyle.tertiaryText).lineLimit(1)
            }
        }
        .font(ChatStyle.toolLine)
        .foregroundStyle(ChatStyle.secondaryText)
        .frame(minHeight: 22)
    }
}

/// Something that happened around the conversation, such as an interrupt or compacting.
private struct NoticeLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(ChatStyle.cardBorder).frame(height: 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(ChatStyle.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Rectangle().fill(ChatStyle.cardBorder).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 26, weight: .light))
            Text("Ask Claude anything about this row.")
                .font(ChatStyle.text)
        }
        .foregroundStyle(ChatStyle.tertiaryText)
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// Working, waiting, or done, with how long and how many tokens.
struct ChatStatusLine: View {
    let chat: ChatSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                indicator
                Text(label).foregroundStyle(color)
                Text(details(at: context.date))
            }
            .font(ChatStyle.meta)
            .foregroundStyle(ChatStyle.secondaryText)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }

    private var isWaiting: Bool { chat.permission != nil }

    @ViewBuilder private var indicator: some View {
        if chat.isWorking && !isWaiting {
            PulsingSymbol(name: "asterisk", color: NSColor(ChatStyle.working))
                .frame(width: 13, height: 13)
        } else {
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }

    private var label: String {
        if isWaiting { return "Needs you" }
        if chat.rateLimitedUntil != nil { return "Rate limited" }
        guard chat.isWorking else { return "Done" }
        switch chat.activity {
        case .thinking: return "Thinking"
        case .compacting: return "Compacting"
        default: return "Working"
        }
    }

    private var color: Color {
        if isWaiting { return Style.agentWaiting }
        if chat.rateLimitedUntil != nil { return ChatStyle.removed }
        return chat.isWorking ? ChatStyle.working : Style.agentDone
    }

    private func details(at now: Date) -> String {
        if let permission = chat.permission {
            return "· waiting " + ChatFormat.clock(now.timeIntervalSince(permission.asked))
        }
        if let until = chat.rateLimitedUntil {
            return "· resets " + until.formatted(date: .omitted, time: .shortened)
        }
        if chat.isWorking, let started = chat.turnStarted {
            var parts = [ChatFormat.duration(now.timeIntervalSince(started))]
            if chat.turnTokens > 0 {
                parts.append("↓ " + ChatFormat.tokens(chat.turnTokens) + (chat.turnTokens == 1 ? " token" : " tokens"))
            }
            return parts.joined(separator: " · ")
        }
        return chat.lastTurn.map { "· " + ChatFormat.duration($0) } ?? ""
    }
}

/// Claude asks to use a tool: Allow, Always allow, or Deny.
private struct PermissionCard: View {
    let permission: ChatPermission
    let chat: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(Style.agentWaiting)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ChatStyle.strongText)
            Text(permission.subject)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(ChatStyle.strongText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatStyle.codeFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ChatStyle.cardBorder))
            if let description = permission.description {
                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ChatStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ChatButton(title: "Allow", key: "⏎", isPrimary: true, action: chat.allow)
                if let rule = permission.rule {
                    ChatButton(title: "Always allow", detail: Self.ruleLabel(rule), action: chat.alwaysAllow)
                }
                Spacer()
                ChatButton(title: "Deny", key: "esc", action: chat.deny)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ChatStyle.askFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ChatStyle.askBorder))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request")
    }

    private var title: String {
        switch permission.tool {
        case "Bash": "Claude wants to run a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Claude wants to edit a file"
        case "WebFetch": "Claude wants to fetch a page"
        case "WebSearch": "Claude wants to search the web"
        default: "Claude wants to use \(Self.toolName(permission.tool))"
        }
    }

    /// "canopy row new:*" reads as "canopy row new".
    static func ruleLabel(_ rule: String) -> String {
        rule.hasSuffix(":*") ? String(rule.dropLast(2)) : rule
    }

    static func toolName(_ tool: String) -> String {
        tool.hasPrefix("mcp__") ? String(tool.split(separator: "__").last ?? Substring(tool)) : tool
    }
}

/// Claude Code does not trust the folder, and headless Claude Code would not ask.
private struct TrustCard: View {
    let onTrust: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(Style.agentWaiting)
                Text("Do you trust this folder?")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ChatStyle.strongText)
            Text(
                "Claude Code will be able to read, edit, and run files here. Trust it only if it is your own code, "
                    + "a well-known project, or your team's work."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(ChatStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ChatButton(title: "Trust", key: "⏎", isPrimary: true, action: onTrust)
                Spacer()
                ChatButton(title: "Not now", key: "esc", action: onDecline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ChatStyle.askFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ChatStyle.askBorder))
        .padding(.top, 40)
    }
}

/// Why the chat stopped, and the way on.
private struct FailureCard: View {
    let failure: ChatFailure
    let chat: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatStyle.removed)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ChatStyle.strongText)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ChatStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .exited(_, let errors) = failure, !errors.isEmpty {
                Text(errors.suffix(6).joined(separator: "\n"))
                    .font(ChatStyle.monoSmall)
                    .foregroundStyle(ChatStyle.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChatStyle.codeFill, in: RoundedRectangle(cornerRadius: 7))
            }
            if let button {
                HStack {
                    ChatButton(title: button.title, isPrimary: true, action: button.action)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ChatStyle.failureFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ChatStyle.failureBorder))
    }

    private var title: String {
        switch failure {
        case .exited(let code, _): "Claude Code stopped (exit code \(code))"
        case .couldNotStart: "Claude Code could not start"
        case .tooOld(let version):
            "Chats need Claude Code \(ChatSession.minimumVersion) or newer"
                + (version.isEmpty ? "" : ", and this Mac has \(version)")
        case .transcriptMissing: "This conversation's history is gone"
        case .heldElsewhere(let pane): "Open in \(pane)"
        }
    }

    private var detail: String {
        switch failure {
        case .exited: "Start it again to go on where it left off."
        case .couldNotStart(let reason): reason
        case .tooOld: "Update it with `claude update`, then send your message again."
        case .transcriptMissing: "Claude Code no longer has its transcript, so it cannot be resumed."
        case .heldElsewhere: "A terminal runs this conversation. Close Claude Code there to go on here."
        }
    }

    private var button: (title: String, action: () -> Void)? {
        switch failure {
        case .exited, .couldNotStart, .tooOld: ("Start again", chat.dismissFailure)
        case .transcriptMissing: ("Start a new chat", chat.startFresh)
        case .heldElsewhere(let pane): ("Show \(pane)", chat.showHolder)
        }
    }
}

/// The chat's buttons: a primary one filled with the accent, the rest quiet.
struct ChatButton: View {
    let title: String
    var detail: String?
    var key: String?
    var isPrimary = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                if let detail {
                    Text(detail).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                }
                if let key { KeyHint(key: key) }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isPrimary ? Color.white : ChatStyle.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if isPrimary { return Color.accentColor.opacity(isHovering ? 0.85 : 1) }
        return isHovering ? ChatStyle.buttonFill.opacity(1.6) : ChatStyle.buttonFill
    }
}

/// A file change: its name and counts, then its changed lines, six until opened.
struct EditCard: View {
    let call: ChatToolCall
    let isOpen: Bool
    let toggle: () -> Void

    private static let folded = 6

    var body: some View {
        let lines = call.edit?.hunks.flatMap(\.lines) ?? []
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    DisclosureChevron(isExpanded: isOpen)
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                        .background(ChatStyle.toolIcon, in: RoundedRectangle(cornerRadius: 5))
                    Text(call.result == nil ? "Editing" : (call.isError ? "Could not edit" : "Edited"))
                    Text(Self.fileName(call.edit?.file ?? ""))
                        .font(ChatStyle.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let edit = call.edit {
                        Text(verbatim: "+\(edit.added)").foregroundStyle(ChatStyle.added)
                        Text(verbatim: "−\(edit.removed)").foregroundStyle(ChatStyle.removed)
                    }
                }
                .font(ChatStyle.meta)
                .foregroundStyle(ChatStyle.primaryText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !lines.isEmpty {
                Rectangle().fill(ChatStyle.cardBorder).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((isOpen ? lines : Array(lines.prefix(Self.folded))).enumerated()), id: \.offset) {
                        _, line in DiffLine(line: line)
                    }
                    if !isOpen, lines.count > Self.folded {
                        Text("\(lines.count - Self.folded) more lines")
                            .font(.system(size: 11))
                            .foregroundStyle(ChatStyle.tertiaryText)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 7)
            }
        }
        .background(ChatStyle.cardFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ChatStyle.cardBorder))
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

private struct DiffLine: View {
    let line: String

    var body: some View {
        Text(verbatim: line.isEmpty ? " " : line)
            .font(ChatStyle.monoSmall)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
            .background(fill)
    }

    private var color: Color {
        if line.hasPrefix("+") { return ChatStyle.added }
        if line.hasPrefix("-") { return ChatStyle.removed }
        return ChatStyle.secondaryText
    }

    private var fill: Color {
        if line.hasPrefix("+") { return ChatStyle.added.opacity(0.11) }
        if line.hasPrefix("-") { return ChatStyle.removed.opacity(0.1) }
        return .clear
    }
}

/// Claude asks: the current question's options as rows, picked with a click or keys 1 to 9.
private struct QuestionCard: View {
    let questions: [PromptQuestion]
    let chat: ChatSession

    var body: some View {
        let step = min(chat.questionStep, questions.count - 1)
        let question = questions[step]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").foregroundStyle(Style.agentWaiting)
                Text("Claude asks")
                if questions.count > 1 {
                    Text(verbatim: "\(step + 1) of \(questions.count)").foregroundStyle(ChatStyle.tertiaryText)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ChatStyle.strongText)
            Text(question.question)
                .font(ChatStyle.text)
                .foregroundStyle(ChatStyle.strongText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    OptionRow(
                        number: index + 1, option: option, isMulti: question.multiSelect,
                        isTicked: chat.questionSelection.contains(index)
                    ) { chat.pick(index) }
                }
            }
            HStack {
                if question.multiSelect {
                    ChatButton(title: "Submit", key: "⏎", isPrimary: true, action: chat.submitSelection)
                }
                Text("Or type your own answer")
                    .font(.system(size: 12))
                    .foregroundStyle(ChatStyle.tertiaryText)
                Spacer()
                ChatButton(title: "Decline", key: "esc", action: chat.deny)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ChatStyle.askFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ChatStyle.askBorder))
    }
}

private struct OptionRow: View {
    let number: Int
    let option: PromptQuestion.Option
    let isMulti: Bool
    let isTicked: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var isRecommended: Bool { option.label.hasSuffix("(Recommended)") }
    private var label: String {
        isRecommended
            ? String(option.label.dropLast("(Recommended)".count)).trimmingCharacters(in: .whitespaces)
            : option.label
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: "\(number)")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .frame(width: 20, height: 20)
                    .background(ChatStyle.chipFill, in: RoundedRectangle(cornerRadius: 5))
                if isMulti {
                    Image(systemName: isTicked ? "checkmark.square.fill" : "square").padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label).font(.system(size: 13, weight: .medium))
                        if isRecommended { TagView(text: "Recommended") }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(ChatStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(ChatStyle.strongText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? ChatStyle.buttonFill.opacity(1.6) : ChatStyle.buttonFill,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Claude's plan, to approve with edits accepted or asked about, or to keep planning.
private struct PlanCard: View {
    let plan: String
    let chat: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(Style.agentWaiting)
                Text("Claude has a plan")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ChatStyle.strongText)
            MarkdownView(blocks: ChatMarkdown.parse(plan))
                .padding(12)
                .background(ChatStyle.codeFill, in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 8) {
                ChatButton(title: "Approve and auto-accept edits", key: "⏎", isPrimary: true) {
                    chat.approvePlan(acceptingEdits: true)
                }
                ChatButton(title: "Approve, ask before edits") { chat.approvePlan(acceptingEdits: false) }
                Spacer()
                ChatButton(title: "Keep planning", key: "esc", action: chat.deny)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ChatStyle.askFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ChatStyle.askBorder))
    }
}

/// A command still running: its command, how long it has run, and the last lines it printed.
private struct RunningCard: View {
    let command: String
    let lines: [String]
    let started: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 18, height: 18)
                    .background(ChatStyle.toolIcon, in: RoundedRectangle(cornerRadius: 5))
                Text("Running")
                Text(command).font(ChatStyle.monoSmall).lineLimit(1).truncationMode(.middle)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ChatFormat.clock(context.date.timeIntervalSince(started)))
                        .foregroundStyle(ChatStyle.tertiaryText)
                }
            }
            .font(ChatStyle.meta)
            .foregroundStyle(ChatStyle.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            if !lines.isEmpty {
                Rectangle().fill(ChatStyle.cardBorder).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(ChatStyle.monoSmall)
                            .foregroundStyle(ChatStyle.secondaryText)
                            .lineLimit(1)
                            .frame(minHeight: 17, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background(ChatStyle.cardFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ChatStyle.cardBorder))
    }
}

/// A `!` command the author ran: the command, "you ran this", and the last 30 lines it printed.
struct ShellBlock: View {
    let shell: ChatShell
    let expanded: Bool
    let toggle: () -> Void

    private static let shownLines = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: "$").font(ChatStyle.mono).foregroundStyle(ChatStyle.tertiaryText)
                Text(shell.command).font(ChatStyle.mono).foregroundStyle(ChatStyle.strongText).lineLimit(1)
                Spacer()
                if shell.exitCode == nil {
                    ProgressView().controlSize(.mini)
                } else if let code = shell.exitCode, code != 0 {
                    Text("exit \(code)").foregroundStyle(ChatStyle.removed)
                }
                Text("you ran this").foregroundStyle(ChatStyle.tertiaryText)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12)
            .frame(height: 30)
            if !shell.output.isEmpty {
                let lines = shell.output.split(separator: "\n", omittingEmptySubsequences: false)
                Rectangle().fill(ChatStyle.cardBorder).frame(height: 1)
                if lines.count > Self.shownLines {
                    Button(action: toggle) {
                        Text(
                            expanded
                                ? "Show the last \(Self.shownLines) lines"
                                : "\(lines.count - Self.shownLines) earlier lines"
                        )
                        .font(ChatStyle.meta)
                        .foregroundStyle(ChatStyle.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                Text((expanded ? lines[...] : lines.suffix(Self.shownLines)).joined(separator: "\n"))
                    .font(ChatStyle.monoSmall)
                    .foregroundStyle(ChatStyle.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(ChatStyle.codeFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ChatStyle.cardBorder))
    }
}

/// A symbol that pulses, as Working's asterisk does. Core Animation runs the pulse outside the app, where SwiftUI's
/// symbol effect redrew the row on every frame for as long as Claude worked.
struct PulsingSymbol: NSViewRepresentable {
    let name: String
    let color: NSColor

    func makeNSView(context: Context) -> PulsingImageView {
        let view = PulsingImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        view.contentTintColor = color
        return view
    }

    func updateNSView(_ view: PulsingImageView, context: Context) {
        view.contentTintColor = color
    }
}

final class PulsingImageView: NSImageView {
    /// A layer drops its animations when its view leaves a window, so the pulse starts each time the view joins one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "pulse")
    }
}
