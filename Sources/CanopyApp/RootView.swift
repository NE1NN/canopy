import AppKit
import CanopyCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            RowDetailView()
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
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.shutdown()
        }
    }
}

struct RowDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let row = model.selectedRow {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(row.displayName)
                } icon: {
                    BranchIcon()
                }
                .font(.title2)
                Text(row.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(row.displayName)
        } else {
            ContentUnavailableView(
                "No Row Selected",
                systemImage: "sidebar.left",
                description: Text("Pick a row in the sidebar, or add a repo to get started.")
            )
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
