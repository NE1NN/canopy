import Foundation

/// One row of a chat's conversation as it is drawn: the items, then what is still on its way, then how the turn is
/// going.
public enum ChatRow: Identifiable, Equatable, Sendable {
    /// A chat with nothing in it yet.
    case empty
    /// Claude Code does not trust the folder yet.
    case trust
    case item(ChatItem, expanded: Bool = false)
    /// A block of the text Claude is writing. Settled blocks keep their key, so only the growing one redraws.
    case streaming(index: Int, block: ChatBlock, growth: Int)
    case queued(QueuedPrompt)
    case permission(ChatPermission)
    case failure(ChatFailure)
    /// A command still running, with the last lines it printed.
    case running(callID: String, command: String, lines: [String])
    /// Working, waiting, or done, with times and tokens.
    case status

    public var id: String {
        switch self {
        case .empty: "empty"
        case .trust: "trust"
        case .item(let item, _): item.id
        case .streaming(let index, _, _): "streaming-\(index)"
        case .queued(let prompt): "queued-" + prompt.id
        case .permission(let permission): "permission-" + permission.id
        case .failure: "failure"
        case .running(let callID, _, _): "running-" + callID
        case .status: "status"
        }
    }

    /// Changes whenever what the row shows does, cheaply: an item's revision rather than its content.
    public var key: String {
        switch self {
        case .item(let item, let expanded): "\(item.id)#\(item.revision)#\(expanded)"
        case .streaming(_, _, let growth): "\(id)#\(growth)"
        case .queued(let prompt): "\(id)#\(prompt.waitsForStep)"
        case .failure(let failure): "failure#\(failure)"
        case .running(_, _, let lines): "\(id)#\(lines.count)#\(lines.last ?? "")"
        default: id
        }
    }
}

public enum ChatRows {
    @MainActor
    public static func rows(for chat: ChatSession) -> [ChatRow] {
        // A question or plan waiting on the author shows as its card, not also as a line above it.
        let waiting = Set(chat.pendingPermissions.compactMap { $0.kind == .permission ? nil : $0.toolUse })
        var rows: [ChatRow] = []
        for item in chat.items where !waiting.contains(item.id) {
            rows.append(.item(item, expanded: chat.expanded.contains(item.id)))
            // A running command shows what it prints, under its line.
            guard case .tools(let group) = item.content else { continue }
            for call in group.calls where chat.runningCommands.contains(call.id) {
                rows.append(
                    .running(
                        callID: call.id, command: call.input["command"]?.text ?? call.name,
                        lines: chat.tails[call.id] ?? []))
            }
        }
        // A saved conversation stays readable above the question.
        if chat.needsTrust { return rows + [.trust] }
        if let streaming = chat.streaming {
            for (index, block) in streaming.blocks.enumerated() {
                let growth = index < streaming.settledCount ? 0 : streaming.text.utf8.count
                rows.append(.streaming(index: index, block: block, growth: growth))
            }
        }
        rows += chat.queued.map(ChatRow.queued)
        if let permission = chat.permission { rows.append(.permission(permission)) }
        if let failure = chat.failure {
            rows.append(.failure(failure))
        } else if chat.isWorking || chat.lastTurn != nil {
            rows.append(.status)
        }
        return rows.isEmpty ? [.empty] : rows
    }
}
