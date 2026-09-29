import AppKit
import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var detailFrame = CGRect.zero
    @State private var isFullScreen = false

    var body: some View {
        @Bindable var model = model
        let isSidebarHidden = columns == .detailOnly
        let placement = TopBarPlacement(isSidebarHidden: isSidebarHidden, isFullScreen: isFullScreen)
        NavigationSplitView(columnVisibility: $columns) {
            // The narrowest keeps a name beside the PR number and hover hints on a group's rows, two steps in.
            SidebarView()
                .navigationSplitViewColumnWidth(min: 244, ideal: 270, max: 420)
        } detail: {
            RowDetailView()
                .environment(\.topBarFillsTitleBar, placement.fillsTitleBar)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    detailFrame = $0
                }
        }
        .overlay(alignment: .topLeading) {
            if let row = model.selection, !(row.worktree?.isMissing ?? false) {
                TitleBarRow(
                    row: row, placement: placement, detailWidth: detailFrame.width, isSidebarHidden: isSidebarHidden
                )
                .frame(width: detailFrame.width)
                .offset(x: detailFrame.minX)
                .ignoresSafeArea(.container, edges: placement.fillsTitleBar ? .top : [])
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .environment(\.openURL, OpenURLAction { model.open($0) })
        // Full screen shows the bar at the top, as a window does, with the toolbar only while the pointer is there.
        .windowToolbarFullScreenVisibility(.onHover)
        .background(FullScreenReader(isFullScreen: $isFullScreen))
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .fileImporter(isPresented: $model.isChoosingFolder, allowedContentTypes: [.folder]) { model.folderChosen($0) }
        .sheet(isPresented: $model.isShowingCloneSheet) {
            CloneRepoSheet()
        }
        .sheet(item: $model.setupSheet) { request in
            request.setup.sheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .alert(
            model.pendingClose?.title ?? "",
            isPresented: Binding(get: { model.pendingClose != nil }, set: { if !$0 { model.pendingClose = nil } }),
            presenting: model.pendingClose
        ) { _ in
            Button("Close", role: .destructive, action: model.confirmClose)
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        .alert(
            "Show when Claude Code finishes?",
            isPresented: Binding(get: { model.hooksOffer != nil }, set: { if !$0 { model.hooksOffer = nil } }),
            presenting: model.hooksOffer
        ) { settings in
            Button("Add Hooks") { model.installHooks(into: settings) }
            Button("Not Now", role: .cancel) {}
        } message: { settings in
            Text(
                "Canopy can add hooks to \((settings.url.path as NSString).abbreviatingWithTildeInPath) so it knows when Claude Code in its terminals is working, done, or waiting for you. Your other hooks stay as they are, and `canopy hooks uninstall` takes Canopy's out."
            )
        }
        .alert(
            "Turn off \(model.pendingTurnOff?.section.info.name ?? "")?",
            isPresented: Binding(get: { model.pendingTurnOff != nil }, set: { if !$0 { model.pendingTurnOff = nil } }),
            presenting: model.pendingTurnOff
        ) { pending in
            Button("Turn Off", role: .destructive) { model.confirmTurnOff(pending.section) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                pending.busyTerminals == 1
                    ? "A terminal in its rows is running a program. Turning it off closes its terminals. Its rows come back when it is on again."
                    : "\(pending.busyTerminals) terminals in its rows are running programs. Turning it off closes its terminals. Its rows come back when it is on again."
            )
        }
        .alert(
            model.pendingPluginAction?.action.confirmTitle ?? "",
            isPresented: Binding(
                get: { model.pendingPluginAction != nil }, set: { if !$0 { model.pendingPluginAction = nil } }),
            presenting: model.pendingPluginAction
        ) { pending in
            Button(pending.action.confirmButton, role: .destructive) { model.confirm(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        .alert(
            "Remove \(model.pendingRepoRemoval?.repo.name ?? "") from Canopy?",
            isPresented: Binding(
                get: { model.pendingRepoRemoval != nil }, set: { if !$0 { model.pendingRepoRemoval = nil } }),
            presenting: model.pendingRepoRemoval
        ) { pending in
            Button("Remove Repo", role: .destructive) { model.confirmRepoRemoval(pending.repo) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                pending.busyTerminals == 1
                    ? "A terminal in it is running a program. Removing the repo closes its terminals. Files stay."
                    : "\(pending.busyTerminals) terminals in it are running programs. Removing the repo closes its terminals. Files stay."
            )
        }
    }
}

/// What sits in the title bar's row over the detail area: the top bar, after a plugin row's panel strip. A plugin row's
/// panel comes first, with the window controls over its strip rather than over the bar.
struct TitleBarRow: View {
    @Environment(AppModel.self) private var model
    let row: SidebarRow
    let placement: TopBarPlacement
    let detailWidth: Double
    let isSidebarHidden: Bool

    var body: some View {
        HStack(spacing: 0) {
            if let pluginRow = row.pluginRow {
                PanelTitleStrip(row: pluginRow, windowControlsOverStrip: placement.windowControlsOverBar)
                    .frame(width: model.panelWidth(for: pluginRow.plugin, detailWidth: detailWidth))
                Rectangle().fill(.separator).frame(width: PluginDetailView.dividerWidth, height: Style.topBarHeight)
            }
            TopBarView(
                row: row, isSidebarHidden: isSidebarHidden,
                windowControlsOverBar: placement.windowControlsOverBar && row.pluginRow == nil)
        }
    }
}

struct RowDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let row = model.selection {
            // The title bar is hidden, but the title still names the window in the Window menu and Mission Control.
            Group {
                switch row {
                case .worktree(let row): RowTerminalsView(row: row)
                case .plugin(let row): PluginDetailView(row: row)
                }
            }
            .navigationTitle(row.displayName)
        } else {
            ContentUnavailableView {
                Label("No Row Selected", systemImage: "sidebar.left")
            } description: {
                Text("Pick a row in the sidebar, or add a repo to get started.")
            } actions: {
                if model.snapshot.repos.isEmpty {
                    Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
                }
            }
        }
    }
}

/// Every toast reports something that went wrong, such as git's message for a failed command.
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 560)
        // A pill for one line, a rounded box once a long message wraps.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}
