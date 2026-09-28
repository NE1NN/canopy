import AppKit
import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var detailFrame = CGRect.zero

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            RowDetailView(isSidebarHidden: columns == .detailOnly)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    detailFrame = $0
                }
        }
        .overlay(alignment: .topLeading) {
            if let row = model.selectedRow, !row.isMissing {
                TopBarView(row: row, isSidebarHidden: columns == .detailOnly)
                    .frame(width: detailFrame.width)
                    .offset(x: detailFrame.minX)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .fileImporter(isPresented: $model.isChoosingFolder, allowedContentTypes: [.folder]) { model.folderChosen($0) }
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

struct RowDetailView: View {
    @Environment(AppModel.self) private var model
    let isSidebarHidden: Bool

    var body: some View {
        if let row = model.selectedRow {
            // The title bar is hidden, but the title still names the window in the Window menu and Mission Control.
            RowTerminalsView(row: row, isSidebarHidden: isSidebarHidden)
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

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }
}
