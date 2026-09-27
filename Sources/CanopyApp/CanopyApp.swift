import CanopyCore
import SwiftUI

@main
struct CanopyApp: App {
    var body: some Scene {
        Window("Canopy", id: "main") {
            Text("Canopy \(CanopyVersion.current)")
                .foregroundStyle(.secondary)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
