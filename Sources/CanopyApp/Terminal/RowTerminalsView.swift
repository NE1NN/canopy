import CanopyCore
import SwiftUI

/// The detail area for a row: the top bar with its tabs, and the selected tab's terminals.
struct RowTerminalsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.topBarFillsTitleBar) private var topBarFillsTitleBar
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
            // In a window the top bar takes the title bar's row. The title bar is hidden, so clicks reach it.
            .ignoresSafeArea(.container, edges: topBarFillsTitleBar ? .top : [])
        }
    }
}

private struct TopBarFillsTitleBarKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the top bar takes the title bar's row, so the detail leaves that row to it.
    var topBarFillsTitleBar: Bool {
        get { self[TopBarFillsTitleBarKey.self] }
        set { self[TopBarFillsTitleBarKey.self] = newValue }
    }
}
