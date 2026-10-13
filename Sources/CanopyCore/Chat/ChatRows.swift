import Foundation

/// One row of a chat's conversation as it is drawn: the items, then what is still on its way, then how the turn is
/// going.
public enum ChatRow: Identifiable, Equatable, Sendable {
    /// A chat with nothing in it yet.
    case empty
    /// Claude Code does not trust the folder yet.
    case trust
    case item(ChatItem, expanded: Bool = false)
    /// A published artifact's card, with its snapshot once there is one.
    case artifact(ChatItem, ChatArtifact, thumbnail: URL?)
    /// A block of the text Claude is writing. Settled blocks keep their key, so only the growing one redraws.
    case streaming(index: Int, block: ChatBlock, growth: Int)
    case queued(QueuedPrompt)
    /// An open prompt, with how far its questions are answered, so moving on changes its key.
    case permission(ChatPermission, step: Int = 0, ticked: Int = 0)
    case failure(ChatFailure)
    /// A command still running, with the last lines it printed.
    case running(callID: String, command: String, lines: [String], started: Date, printed: Int)
    /// Working, waiting, or done, with times and tokens.
    case status

    public var id: String {
        switch self {
        case .empty: "empty"
        case .trust: "trust"
        case .item(let item, _), .artifact(let item, _, _): item.id
        case .streaming(let index, _, _): "streaming-\(index)"
        case .queued(let prompt): "queued-" + prompt.id
        case .permission(let permission, _, _): "permission-" + permission.id
        case .failure: "failure"
        case .running(let callID, _, _, _, _): "running-" + callID
        case .status: "status"
        }
    }

    /// The block Claude is still writing, when a plain text view can draw it, which costs far less to redraw than
    /// SwiftUI laying it out again.
    public var growingText: ChatBlock? {
        guard case .streaming(_, let block, let growth) = self, growth > 0, ChatTextLines.draws(block) else {
            return nil
        }
        return block
    }

    /// Changes whenever what the row shows does, cheaply: an item's revision rather than its content.
    public var key: String {
        switch self {
        case .item(let item, let expanded):
            if case .shell(let shell) = item.content, item.revision == 0 {
                // A command still being run here grows without a revision.
                "\(item.id)#\(shell.output.utf8.count)#\(shell.exitCode.map(String.init) ?? "running")#\(expanded)"
            } else {
                "\(item.id)#\(item.revision)#\(expanded)"
            }
        case .artifact(let item, _, let thumbnail): "\(item.id)#\(item.revision)#\(thumbnail != nil)"
        case .streaming(_, _, let growth): "\(id)#\(growth)"
        case .queued(let prompt): "\(id)#\(prompt.waitsForStep)"
        case .failure(let failure): "failure#\(failure)"
        case .permission(_, let step, let ticked): "\(id)#\(step)#\(ticked)"
        case .running(_, _, _, _, let printed): "\(id)#\(printed)"
        default: id
        }
    }
}

public enum ChatRows {
    @MainActor
    public static func rows(for chat: ChatSession) -> [ChatRow] {
        joined(conversation(for: chat), pending(for: chat))
    }

    /// A chat's rows from its two halves, which a long chat's view follows apart so that text streaming into the
    /// pending half does not rebuild the conversation's rows each time.
    public static func joined(_ conversation: [ChatRow], _ pending: [ChatRow]) -> [ChatRow] {
        let rows = conversation + pending
        return rows.isEmpty ? [.empty] : rows
    }

    /// The conversation so far: its items, with what running commands print under them.
    @MainActor
    public static func conversation(for chat: ChatSession) -> [ChatRow] {
        // A question or plan waiting on the author shows as its card, not also as a line above it.
        let waiting = Set(chat.pendingPermissions.compactMap { $0.kind == .permission ? nil : $0.toolUse })
        var rows: [ChatRow] = []
        _ = chat.thumbnailsSaved
        // Read once, not per item: each read of an observed property is tracked, which adds up over a long chat.
        let expanded = chat.expanded
        let running = chat.runningCommands
        for item in chat.items where !waiting.contains(item.id) {
            if case .artifact(let artifact) = item.content {
                rows.append(.artifact(item, artifact, thumbnail: chat.thumbnail(for: artifact)))
                continue
            }
            rows.append(.item(item, expanded: expanded.contains(item.id)))
            // A running command shows what it prints, under its line.
            guard case .tools(let group) = item.content, !running.isEmpty else { continue }
            for call in group.calls where running.contains(call.id) {
                rows.append(
                    .running(
                        callID: call.id, command: call.input["command"]?.text ?? call.name,
                        lines: chat.tails[call.id] ?? [], started: chat.taskStarts[call.id] ?? Date(),
                        printed: chat.tailCounts[call.id] ?? 0))
            }
        }
        return rows
    }

    /// What comes after the conversation: the text Claude is writing, queued messages, an open prompt, and how the
    /// turn is going.
    @MainActor
    public static func pending(for chat: ChatSession) -> [ChatRow] {
        // A saved conversation stays readable above the question.
        if chat.needsTrust { return [.trust] }
        let expanded = chat.expanded
        func shellRow(_ run: ChatShellRun) -> ChatRow {
            let id = "shell-" + run.id
            return .item(ChatItem(id: id, content: .shell(run.shell), at: 0), expanded: expanded.contains(id))
        }
        var rows = chat.shellRuns.map(shellRow)
        if let streaming = chat.streaming {
            for (index, block) in streaming.blocks.enumerated() {
                let growth = index < streaming.settledCount ? 0 : streaming.text.utf8.count
                rows.append(.streaming(index: index, block: block, growth: growth))
            }
        }
        // Until Claude takes a message, the `!` commands that go with it show above it.
        rows += chat.queued.flatMap { $0.shellRuns.map(shellRow) + [.queued($0)] }
        if let permission = chat.permission {
            rows.append(.permission(permission, step: chat.questionStep, ticked: chat.questionSelection.count))
        }
        if let failure = chat.failure {
            rows.append(.failure(failure))
        } else if chat.isWorking || chat.lastTurn != nil {
            rows.append(.status)
        }
        return rows
    }
}
