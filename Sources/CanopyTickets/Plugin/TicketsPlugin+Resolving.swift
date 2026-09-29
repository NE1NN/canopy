import CanopyCore
import Foundation

extension TicketsPlugin {
    /// The ticket a reference names. A number looks at the rows' tickets and open tickets first, then closed and
    /// archived ones. An id ticket-manager does not know, or finds malformed, is not found.
    func resolveID(_ text: String, context: PluginContext) async throws -> String {
        _ = try await requireConnection(context)
        guard let reference = TicketReference(text) else { throw TicketError.notFound(text) }
        let rows = await context.state.rows.map { TicketResolution.Candidate(id: $0.item, name: $0.title) }
        switch reference {
        case .id(let id):
            if rows.contains(where: { $0.id == id }) || known[id] != nil { return id }
            guard try await fetchSummaries(ids: [id]).contains(where: { $0.id == id }) else {
                throw TicketError.notFound(text)
            }
            return id
        case .number:
            let open: [TicketSummary]
            do {
                open = try await fetchList(closed: false)
            } catch {
                // Without ticket-manager, a row's ticket can still be named.
                if case .found(let id) = try TicketResolution.pick(reference, text: text, among: rows) { return id }
                throw error
            }
            if case .found(let id) = try TicketResolution.pick(
                reference, text: text, among: rows + open.map(Self.candidate))
            {
                return id
            }
            let closed = try await fetchList(closed: true)
            if case .found(let id) = try TicketResolution.pick(reference, text: text, among: closed.map(Self.candidate))
            {
                return id
            }
            throw TicketError.notFound(text)
        }
    }

    /// The row a command about a ticket acts on: the one its reference names among the rows, or without one, the row
    /// the command ran in. Rows alone are enough, so this works while ticket-manager cannot be reached.
    func row(for reference: String?, in callRow: PluginRow?, context: PluginContext) async throws -> PluginRow {
        guard await context.state.isOn else { throw TicketError.off(url: Self.configuredURL(await context.config)) }
        guard let reference else {
            if let callRow { return callRow }
            throw ControlError(code: "bad_params", message: "Pass a ticket, such as 853, or run this in a ticket row.")
        }
        guard let parsed = TicketReference(reference) else { throw TicketError.notFound(reference) }
        let rows = await context.state.rows
        let candidates = rows.map { TicketResolution.Candidate(id: $0.item, name: $0.title) }
        if case .found(let id) = try TicketResolution.pick(parsed, text: reference, among: candidates),
            let row = rows.first(where: { $0.item == id })
        {
            return row
        }
        let id = try await resolveID(reference, context: context)
        if let row = await context.state.rows.first(where: { $0.item == id }) { return row }
        throw TicketError.hasNoRow(known[id].map { TicketName.rowTitle(for: $0.name) } ?? reference)
    }

    static func candidate(_ ticket: TicketSummary) -> TicketResolution.Candidate {
        TicketResolution.Candidate(id: ticket.id, name: ticket.name)
    }
}
