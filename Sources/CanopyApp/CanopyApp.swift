import AppKit
import CanopyCore
import SwiftUI

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Canopy", id: "main") {
            RootView()
                .environment(delegate.model)
        }
        // The top bar draws the title bar's row itself, so its tabs and buttons get clicks.
        .windowStyle(.hiddenTitleBar)
        .commands {
            TerminalCommands(model: delegate.model)
            RowCommands(model: delegate.model)
        }
    }
}

/// Owns the model, so starting and stopping do not depend on the window being open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(
        home: CanopyHome.resolve(
            bundleHome: Bundle.main.object(forInfoDictionaryKey: CanopyHome.infoPlistKey) as? String
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.start() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let workspace = model.workspace
        Task { await workspace.applicationBecameActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing to save, and a reply later could never come: `start()` quits from a main actor job, which keeps the
        // reply's task from running.
        guard model.ownsHome else { return .terminateNow }
        // Quitting only detaches remote panes, whose programs keep running on their hosts.
        let busy = model.terminals.busyPanes.filter { $0.context.remote == nil }.compactMap(\.foreground?.name)
        guard busy.isEmpty || confirmQuit(busy) else { return .terminateCancel }
        // Save layouts with every pane's current folder before the terminals close.
        Task {
            await model.saveTerminals()
            await model.plugins.stop()
            await model.workspace.stopHosts()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuit(_ busy: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit Canopy?"
        alert.informativeText = BusyTerminals.quitWarning(busy)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

struct TerminalCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Clone Repo…", action: model.showCloneSheet)
            ForEach(model.pluginSetups, id: \.id) { plugin in
                Button(plugin.setup.title) { model.showSetup(of: plugin.id) }
            }
            Divider()
            Button("New Tab", action: model.newTab)
                .keyboardShortcut("t")
                .disabled(!model.canOpenTerminal)
            Button("Split Pane", action: model.splitPane)
                .keyboardShortcut("d")
                .disabled(!model.canSplit)
        }
        // Replacing the save group also drops File > Close, so ⌘W closes a terminal rather than the window.
        CommandGroup(replacing: .saveItem) {
            Button(model.closeTitle, action: model.closeFocusedPane)
                .keyboardShortcut("w")
                .disabled(model.selectedTab == nil && model.focusedPanelPage == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.selectedPanel?.isHidden == false ? "Hide Web Panel" : "Show Web Panel") {
                model.toggleWebPanel()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(model.selectedPanel == nil)
        }
        CommandGroup(before: .windowArrangement) {
            // ⌘⇧[ reaches the menu as "{", so the shortcuts are declared by the character the keys type.
            Button("Show Previous Tab") { model.selectTab(offset: -1) }
                .keyboardShortcut("{", modifiers: .command)
            Button("Show Next Tab") { model.selectTab(offset: 1) }
                .keyboardShortcut("}", modifiers: .command)
            Divider()
            Button("Focus Pane on the Left") { model.focusNeighbor(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Pane on the Right") { model.focusNeighbor(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Pane Above") { model.focusNeighbor(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Pane Below") { model.focusNeighbor(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
        }
    }
}

struct RowCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Rows") {
            ForEach(1...9, id: \.self) { number in
                Button(model.menuTitle(forRow: number)) {
                    model.selectRow(number: number)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                .disabled(model.snapshot.visibleRows.count < number)
            }
        }
    }
}
