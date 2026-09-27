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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = model.terminals.busyPanes.compactMap(\.foreground?.name)
        guard busy.isEmpty || confirmQuit(busy) else { return .terminateCancel }
        // Save layouts with every pane's current folder before the terminals close.
        Task {
            await model.saveTerminals()
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
            Button("New Tab", action: model.newTab)
                .keyboardShortcut("t")
                .disabled(!model.canOpenTerminal)
            Button("Split Pane", action: model.splitPane)
                .keyboardShortcut("d")
                .disabled(!model.canOpenTerminal)
        }
        // Replacing the save group also drops File > Close, so ⌘W closes a terminal rather than the window.
        CommandGroup(replacing: .saveItem) {
            Button("Close Terminal", action: model.closeFocusedPane)
                .keyboardShortcut("w")
                .disabled(model.selectedTab == nil)
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
