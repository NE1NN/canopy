import CanopyCore
import Foundation

/// How ticket rows and picker items look.
public enum TicketLook {
    /// A row's look: its label, such as `#0853`, an orange dot while the customer waits, a "closed" tag while the ticket
    /// is closed or archived, and missing when ticket-manager no longer has it. Without a summary, the label alone.
    public static func look(title: String, summary: TicketSummary?, isMissing: Bool) -> PluginRowLook {
        var accessories = summary.map { Self.accessories($0, withOwner: false) } ?? []
        // A row's tag says closed for archived tickets too, so the sidebar has one word for "not open any more".
        for index in accessories.indices where accessories[index].kind == .tag {
            accessories[index].text = "closed"
        }
        return PluginRowLook(
            label: TicketName.label(for: title), accessories: accessories, isMissing: isMissing)
    }

    /// The waiting dot, the status tag of a ticket that is closed or archived, and with `withOwner`, the owner's
    /// initials.
    public static func accessories(_ ticket: TicketSummary, withOwner: Bool) -> [PluginAccessory] {
        var accessories: [PluginAccessory] = []
        if ticket.waiting { accessories.append(.dot(.orange, help: "Customer waiting")) }
        switch ticket.status {
        case .closed: accessories.append(.tag("closed", help: "Closed"))
        case .archived: accessories.append(.tag("archived", help: "Archived"))
        case .open, .other: break
        }
        if withOwner, let owner = ticket.owner {
            accessories.append(
                .initials(owner.initials, color: ownerColor(owner.email), help: "Owned by \(owner.email)"))
        }
        return accessories
    }

    /// The same color for an engineer everywhere, from their email. Never orange, which means a customer is waiting.
    public static func ownerColor(_ email: String) -> PluginColor {
        let colors: [PluginColor] = [.blue, .green, .purple, .red]
        var hash: UInt32 = 2_166_136_261
        for byte in email.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return colors[Int(hash % UInt32(colors.count))]
    }
}
