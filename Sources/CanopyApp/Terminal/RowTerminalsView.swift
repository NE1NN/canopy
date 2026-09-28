import CanopyCore
import SwiftUI

/// The detail area for a row: the top bar with its tabs, and the selected tab's terminals.
struct RowTerminalsView: View {
    @Environment(AppModel.self) private var model
    let row: Row
    let isSidebarHidden: Bool

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
        } else {
            VStack(spacing: 0) {
                // RootView draws the top bar over this space.
                Color.clear.frame(height: Style.topBarHeight)
                if let tab = model.terminals.selectedTab(inRow: row.path) {
                    GridView(tab: tab)
                        .id(tab.id)
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
            // The top bar takes the title bar's row. The window's title bar is hidden, so clicks reach it.
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}
