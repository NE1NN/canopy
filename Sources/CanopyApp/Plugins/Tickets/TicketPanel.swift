import CanopyCore
import CanopyTickets
import SwiftUI

/// A ticket row's panel beside its terminals.
struct TicketPanel: View {
    let row: PluginRow
    let tickets: TicketsPlugin

    var body: some View {
        Text(row.displayName)
            .padding(14)
    }
}
