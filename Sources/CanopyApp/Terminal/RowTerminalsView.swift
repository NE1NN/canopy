import CanopyCore
import SwiftUI

/// The detail area for a row: its tab bar and the selected tab's terminal.
struct RowTerminalsView: View {
    @Environment(AppModel.self) private var model
    let row: Row

    var body: some View {
        if row.isMissing {
            ContentUnavailableView {
                Label("Worktree Missing", systemImage: "folder.badge.questionmark")
            } description: {
                Text("\(row.path) no longer exists.")
            } actions: {
                if let repo = model.snapshot.repo(path: row.repoPath) {
                    Button("Prune Missing Worktrees") { model.prune(repo) }
                }
            }
        } else if let tab = model.terminals.selectedTab(inRow: row.path) {
            VStack(spacing: 0) {
                TabBarView(row: row)
                PaneView(
                    pane: tab.focused,
                    onClose: { model.requestClose(tab.focused) },
                    onSizeChange: { model.terminals.preferredSize = $0 }
                )
                .id(tab.focused.id)
            }
        } else {
            ContentUnavailableView {
                Label("No Terminals", systemImage: "apple.terminal")
            } description: {
                Text("Press ⌘T to open one in \(row.displayName).")
            } actions: {
                Button("New Terminal") { model.newTab() }
            }
        }
    }
}
