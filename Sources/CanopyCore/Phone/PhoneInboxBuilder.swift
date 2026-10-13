import Foundation

/// What the phone sees of the workspace: its rows in sidebar order, each with the agents in its panes.
@MainActor
public enum PhoneInboxBuilder {
    public static func inbox(
        _ snapshot: WorkspaceSnapshot, terminals: TerminalStore, tails: TranscriptTails? = nil
    ) -> PhoneInbox {
        PhoneInbox(
            rows: sections(snapshot, terminals: terminals, tails: tails).flatMap(\.rows).map { row in
                var row = row
                row.pr = nil
                return row
            })
    }

    public static func rows(
        _ snapshot: WorkspaceSnapshot, terminals: TerminalStore, tails: TranscriptTails? = nil
    ) -> PhoneRowsResult {
        PhoneRowsResult(sections: sections(snapshot, terminals: terminals, tails: tails))
    }

    private static func sections(_ snapshot: WorkspaceSnapshot, terminals: TerminalStore, tails: TranscriptTails?)
        -> [PhoneRowsResult.Section]
    {
        let repos = snapshot.repos.map { repo in
            PhoneRowsResult.Section(
                name: repo.name, isPlugin: false,
                rows: repo.allRows.map { row in
                    PhoneRow(
                        path: row.path, name: row.displayName, repo: repo.name, isMain: row.rowClass == .main,
                        pr: row.pullRequest.map {
                            PhonePR(number: $0.number, state: $0.state, title: $0.title, url: $0.url)
                        },
                        agents: agents(inRow: row.path, terminals: terminals, tails: tails))
                })
        }
        let plugins = snapshot.activePlugins.map { section in
            PhoneRowsResult.Section(
                name: section.info.name, isPlugin: true,
                rows: section.rows.map { row in
                    PhoneRow(
                        path: row.path, name: row.displayName, plugin: section.info.itemName ?? section.info.name,
                        agents: agents(inRow: row.path, terminals: terminals, tails: tails))
                })
        }
        return repos + plugins
    }

    /// Panes with an agent, and panes whose Claude Code is idle but still has a conversation to read.
    private static func agents(inRow path: String, terminals: TerminalStore, tails: TranscriptTails?) -> [PhoneAgent] {
        terminals.tabs(inRow: path).flatMap(\.paneList).compactMap { pane in
            let agent = pane.agent
            let transcript = pane.context.remote == nil ? agent.transcriptPath : nil
            guard agent.state != .none || transcript != nil else { return nil }
            return PhoneAgent(
                pane: pane.id.description, state: agent.state, unseen: agent.unseen,
                since: agent.since.timeIntervalSince1970,
                lastLine: lastLine(agent, tail: transcript.flatMap { tails?.last(in: $0) }),
                backgroundTasks: agent.backgroundTasks.isEmpty ? nil : agent.backgroundTasks, prompt: agent.prompt,
                hasTranscript: transcript != nil, kind: pane.chat == nil ? .terminal : .chat)
        }
    }

    private static func short(_ text: String) -> String {
        TranscriptParser.ToolKind.short(text)
    }

    /// One line on what the agent does or wants: its prompt, what it waits on in the background, or its conversation's
    /// last entry.
    static func lastLine(_ agent: PaneAgent, tail: TranscriptEntry?) -> String? {
        if let prompt = agent.prompt {
            switch prompt.kind {
            case .permission where prompt.tool == "Bash":
                return "Wants to run \(short(prompt.detail ?? "a command"))"
            case .permission:
                return "Wants to use \(prompt.tool ?? "a tool")" + (prompt.detail.map { ": \(short($0))" } ?? "")
            case .question:
                return "Asks: \(short(prompt.questions?.first?.question ?? "a question"))"
            case .plan:
                return "Has a plan ready"
            case .reply:
                return "Asks: \(short(prompt.detail ?? "a question"))"
            }
        }
        if agent.state == .background, !agent.backgroundTasks.isEmpty {
            return "Waiting on \(agent.backgroundTasks.joined(separator: ", ")) in the background"
        }
        guard let tail else { return nil }
        switch tail.kind {
        case .text:
            return tail.text.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
                .map { short(String($0)) }
        case .prompt:
            return "You: " + short(tail.text)
        case .question:
            return "Asked: \(short(tail.text))"
        case .plan:
            return "Made a plan"
        case .tools, .notice:
            return tail.text
        }
    }
}
