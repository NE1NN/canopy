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
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Canopy?"
        alert.informativeText = BusyTerminals.quitWarning(busy)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
