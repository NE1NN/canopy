import CanopyCore
import SwiftUI

/// What the rows' buttons do, supplied by the chat view.
struct ChatActions {
    var trust: () -> Void
    var declineTrust: () -> Void
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
        case .item(let item):
            ChatItemView(item: item)
        case .streaming(_, let block, _):
            MarkdownView(blocks: [block])
        case .queued(let queued):
            PromptBubble(prompt: queued.prompt, waitsForStep: queued.waitsForStep)
        case .permission(let permission):
            PermissionCard(permission: permission, chat: chat)
        case .failure(let failure):
            FailureCard(failure: failure, chat: chat)
        case .status:
            ChatStatusLine(chat: chat)
        }
    }
}

private struct ChatItemView: View {
    let item: ChatItem

    var body: some View {
        switch item.content {
        case .prompt(let prompt):
            PromptBubble(prompt: prompt)
        case .text(let text):
            MarkdownView(blocks: text.blocks)
        case .tools(let group):
            ToolLine(group: group)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(group.kind))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ChatStyle.secondaryText)
                .frame(width: 18, height: 18)
                .background(ChatStyle.toolIcon, in: RoundedRectangle(cornerRadius: 5))
            Text(group.summary)
                .font(ChatStyle.toolLine)
                .foregroundStyle(group.failed ? ChatStyle.removed : ChatStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if group.calls.contains(where: { $0.result == nil }) {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(minHeight: 22)
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
            Image(systemName: "asterisk")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ChatStyle.working)
                .symbolEffect(.pulse, options: .repeating)
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
        }
    }

    private var detail: String {
        switch failure {
        case .exited: "Start it again to go on where it left off."
        case .couldNotStart(let reason): reason
        case .tooOld: "Update it with `claude update`, then send your message again."
        case .transcriptMissing: "Claude Code no longer has its transcript, so it cannot be resumed."
        }
    }

    private var button: (title: String, action: () -> Void)? {
        switch failure {
        case .exited, .couldNotStart, .tooOld: ("Start again", chat.dismissFailure)
        case .transcriptMissing: ("Start a new chat", chat.startFresh)
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
