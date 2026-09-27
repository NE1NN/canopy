import AppKit
import CanopyCore
import SwiftUI

@main
struct CanopyApp: App {
    @State private var model = AppModel(
        home: CanopyHome.resolve(
            bundleHome: Bundle.main.object(forInfoDictionaryKey: CanopyHome.infoPlistKey) as? String
        )
    )

    var body: some Scene {
        Window("Canopy", id: "main") {
            RootView()
                .environment(model)
        }
        .commands {
            RowCommands(model: model)
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
