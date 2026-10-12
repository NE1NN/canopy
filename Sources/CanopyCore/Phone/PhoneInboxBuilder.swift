import Foundation

/// What the phone sees of the workspace: its rows in sidebar order, each with the agents in its panes.
@MainActor
public enum PhoneInboxBuilder {
    public static func inbox(_ snapshot: WorkspaceSnapshot, terminals: TerminalStore) -> PhoneInbox {
        PhoneInbox(
            rows: sections(snapshot, terminals: terminals).flatMap(\.rows).map { row in
                var row = row
                row.pr = nil
                return row
            })
    }

    public static func rows(_ snapshot: WorkspaceSnapshot, terminals: TerminalStore) -> PhoneRowsResult {
        PhoneRowsResult(sections: sections(snapshot, terminals: terminals))
    }

    private static func sections(_ snapshot: WorkspaceSnapshot, terminals: TerminalStore) -> [PhoneRowsResult.Section] {
        let repos = snapshot.repos.map { repo in
            PhoneRowsResult.Section(
                name: repo.name, isPlugin: false,
                rows: repo.allRows.map { row in
                    PhoneRow(
                        path: row.path, name: row.displayName, repo: repo.name, isMain: row.rowClass == .main,
                        pr: row.pullRequest.map {
                            PhonePR(number: $0.number, state: $0.state, title: $0.title, url: $0.url)
                        },
                        agents: agents(inRow: row.path, terminals: terminals))
                })
        }
        let plugins = snapshot.activePlugins.map { section in
            PhoneRowsResult.Section(
                name: section.info.name, isPlugin: true,
                rows: section.rows.map { row in
                    PhoneRow(
                        path: row.path, name: row.displayName, plugin: section.info.itemName ?? section.info.name,
                        agents: agents(inRow: row.path, terminals: terminals))
                })
        }
        return repos + plugins
    }

    private static func agents(inRow path: String, terminals: TerminalStore) -> [PhoneAgent] {
        terminals.tabs(inRow: path).flatMap(\.paneList).compactMap { pane in
            let agent = pane.agent
            guard agent.state != .none else { return nil }
            return PhoneAgent(
                pane: pane.id.description, state: agent.state, unseen: agent.unseen,
                since: agent.since.timeIntervalSince1970,
                backgroundTasks: agent.backgroundTasks.isEmpty ? nil : agent.backgroundTasks)
        }
    }
}
