import CanopyCore
import CanopyFixturePlugin
import CanopyTickets
import SwiftUI

/// A built-in plugin, the panel it draws beside a row's terminals, how the window turns it on, and what it adds to its
/// section's `…` menu.
@MainActor
struct BuiltInPlugin {
    let plugin: any CanopyPlugin
    let panel: (PluginRow) -> AnyView
    /// Offered in the sidebar's `+` menu and the File menu while the plugin is off, such as "Connect Tickets…". A plugin
    /// without one is turned on with `canopy plugin enable`.
    var setup: PluginSetup?
    var menuActions: [PluginMenuAction] = []
}

/// A sheet that turns a plugin on, such as one asking for a token.
struct PluginSetup {
    let title: String
    let sheet: @MainActor () -> AnyView
}

/// An item in a plugin section's `…` menu that asks first, such as Disconnect.
struct PluginMenuAction: Identifiable {
    let id: String
    let title: String
    let confirmTitle: String
    let confirmMessage: String
    let confirmButton: String
    let run: @MainActor (AppModel) async throws -> Void
}

/// The app's one list of built-in plugins, in the order their sections show. Nothing else imports a plugin's module.
enum BuiltInPlugins {
    @MainActor
    static func make(environment: [String: String]) -> [BuiltInPlugin] {
        var plugins = [tickets()]
        #if DEBUG
            // Only a dev build launched for the end-to-end tests or UI checks has it.
            if environment["CANOPY_FIXTURE_PLUGIN"] == "1" {
                let fixture = FixturePlugin()
                plugins.append(BuiltInPlugin(plugin: fixture) { AnyView(FixturePanel(row: $0)) })
            }
        #endif
        return plugins
    }

    @MainActor
    private static func tickets() -> BuiltInPlugin {
        let tickets = TicketsPlugin()
        return BuiltInPlugin(
            plugin: tickets, panel: { AnyView(TicketPanel(row: $0, tickets: tickets)) },
            setup: PluginSetup(title: "Connect Tickets…") { AnyView(ConnectTicketsSheet(info: tickets.info)) },
            menuActions: [
                PluginMenuAction(
                    id: "disconnect", title: "Disconnect", confirmTitle: "Disconnect Tickets?",
                    confirmMessage:
                        "Canopy turns Tickets off and deletes its token from the Keychain. Your ticket rows stay for when you connect again.",
                    confirmButton: "Disconnect"
                ) { model in
                    _ = try await model.plugins.call(
                        TicketMethod.disconnect, params: try .from(TicketDisconnectParams(force: true)),
                        target: TargetHint(), row: nil)
                }
            ])
    }

    /// Where removed plugin rows' folders go: the Trash, or in a dev build launched with CANOPY_TRASH_FOLDER, that
    /// folder, so end-to-end runs and UI checks on a throwaway home leave nothing in the author's Trash.
    static func trash(environment: [String: String]) -> any FolderTrash {
        #if DEBUG
            if let folder = environment["CANOPY_TRASH_FOLDER"], !folder.isEmpty {
                return FolderMovingTrash(into: folder)
            }
        #endif
        return SystemTrash()
    }
}

extension PluginColor {
    var color: Color {
        switch self {
        case .gray: Color(nsColor: .systemGray)
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .yellow: Style.agentWaiting
        case .green: Color(nsColor: .systemGreen)
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .accent: .accentColor
        }
    }
}

/// A plugin's dot, tag, or initials, drawn the same in the sidebar and the picker.
struct PluginAccessoryView: View {
    let accessory: PluginAccessory

    var body: some View {
        Group {
            switch accessory.kind {
            case .dot:
                Circle()
                    .fill(accessory.color.color)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(accessory.color.color.opacity(0.22)).padding(-2))
            case .tag:
                TagView(text: accessory.text ?? "")
            case .initials:
                Text(verbatim: accessory.text ?? "")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(accessory.color.color))
            }
        }
        .help(accessory.help)
        .accessibilityElement()
        .accessibilityLabel(accessory.help)
    }
}

/// A plugin's symbol on a tile of its own hue, as a repo's letter sits on its tile.
struct PluginTile: View {
    let info: PluginInfo
    var size = 16.0

    var body: some View {
        let hue = Style.tileHues[RepoMark(name: info.name, path: "plugins/" + info.id).hue % Style.tileHues.count]
        Image(systemName: info.symbol)
            .font(.system(size: size * 0.56, weight: .semibold))
            .foregroundStyle(hue)
            .frame(width: size, height: size)
            .background(hue.opacity(0.2), in: RoundedRectangle(cornerRadius: Style.tagRadius))
            .overlay(RoundedRectangle(cornerRadius: Style.tagRadius).strokeBorder(hue.opacity(0.35), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
