import CanopyCore
import Foundation

extension TicketsPlugin {
    public func handle(_ call: PluginCall, context: PluginContext) async throws -> JSONValue {
        try await converting {
            switch call.method {
            case TicketMethod.connect:
                return try .from(try await connect(call.decodeParams(TicketConnectParams.self), context: context))
            case TicketMethod.disconnect:
                return try await disconnect(call.decodeParams(TicketDisconnectParams.self), context: context)
            case TicketMethod.list:
                return try .from(try await list(call.decodeParams(TicketListParams.self), context: context))
            case TicketMethod.new:
                return try .from(try await new(call.decodeParams(TicketNewParams.self), context: context))
            case TicketMethod.show:
                return try .from(
                    try await show(call.decodeParams(TicketShowParams.self), in: call.row, context: context))
            case TicketMethod.select:
                let params = try call.decodeParams(TicketRefParams.self)
                let row = try await row(for: params.reference, in: call.row, context: context)
                await context.select(row)
                return try .from(row)
            case TicketMethod.remove:
                let params = try call.decodeParams(TicketRemoveParams.self)
                let row = try await row(for: params.reference, in: call.row, context: context)
                return try .from(try await context.removeRow(row, force: params.force))
            default:
                throw ControlError(code: "unknown_method", message: "Unknown method \(call.method)")
            }
        }
    }

    /// Checks the token against `/api/v1/me`, saves it, and turns the plugin on with the URL. A token ticket-manager
    /// rejects saves nothing.
    func connect(_ params: TicketConnectParams, context: PluginContext) async throws -> TicketConnectResult {
        let url = try TicketSettings.url(params.url)
        var web: String?
        if let text = params.web, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            web = try TicketSettings.web(text)
        }
        let token = params.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ControlError(
                code: "bad_params",
                message: "Pass a token. `canopy ticket connect` reads it from the terminal, or from stdin.")
        }
        let address = url.absoluteString
        let email: String
        do {
            email = try await TicketAPI(base: url, token: token, transport: transport).me()
        } catch {
            throw TicketError.from(error, url: address)
        }
        let previous: String?
        do {
            previous = try context.secrets.read(Self.tokenName)
            try context.secrets.write(token, for: Self.tokenName)
        } catch {
            throw TicketError.keychain(Self.describe(error))
        }
        var fields: [String: JSONValue] = ["url": .string(address)]
        if let web { fields["web"] = .string(web) }
        do {
            try await context.turnOn(with: fields)
        } catch {
            if let previous {
                try? context.secrets.write(previous, for: Self.tokenName)
            } else {
                try? context.secrets.delete(Self.tokenName)
            }
            throw error
        }
        guard var current = connection else {
            throw startError ?? TicketError.notStarted("Run `canopy ticket connect \(address)` again.")
        }
        // A plugin whose section did not change keeps running, so the new token takes over here.
        current.token = token
        connection = current
        me = email
        await store.setMe(email)
        await succeeded()
        // Requests still out on the old token record nothing, and everything is asked for again at once rather than
        // after the waits earlier failures left.
        generation += 1
        for task in tasks { task.cancel() }
        tasks = []
        sleeper?.cancel()
        startRefreshing(context)
        return TicketConnectResult(url: address, email: email, web: current.settings.web)
    }

    /// Turns the plugin off, then deletes the token. Its rows stay for when it is connected again.
    func disconnect(_ params: TicketDisconnectParams, context: PluginContext) async throws -> JSONValue {
        if await context.state.isOn {
            try await context.turnOff(force: params.force)
        }
        do {
            try context.secrets.delete(Self.tokenName)
        } catch {
            throw TicketError.keychain(Self.describe(error))
        }
        return .object(["disconnected": true])
    }

    /// Tickets sorted as the picker sorts them, each with its row, always fetched afresh.
    func list(_ params: TicketListParams, context: PluginContext) async throws -> [TicketListEntry] {
        _ = try await requireConnection(context)
        let tickets = try await fetchList(closed: params.closed)
        if params.owner == .mine, me == nil {
            try await refreshMe()
        }
        let query = TicketListQuery(owner: params.owner, waitingOnly: params.waiting, text: params.query ?? "")
        let rows = await context.state.rows
        return TicketListing.list(tickets, query, me: me).map { ticket in
            TicketListEntry(ticket: ticket, row: rows.first { $0.item == ticket.id })
        }
    }
}

extension TicketsPlugin {
    /// Opens a row for the ticket, or fails with `ticket_has_row` naming the row it has.
    func new(_ params: TicketNewParams, context: PluginContext) async throws -> PluginRowCreated {
        let id = try await resolveID(params.reference, context: context)
        let title = known[id].map { TicketName.rowTitle(for: $0.name) } ?? params.reference
        if let row = await context.state.rows.first(where: { $0.item == id }) {
            throw TicketError.hasRow(row.title, path: row.path)
        }
        do {
            return try await context.createRow(for: id, run: params.run, select: params.select)
        } catch WorkspaceError.itemHasRow(let path) {
            throw TicketError.hasRow(title, path: path)
        }
    }

    /// The ticket, from a copy under 30 seconds old unless `refresh`. When ticket-manager cannot be reached, the copy
    /// Canopy has, saying how old it is.
    func show(_ params: TicketShowParams, in callRow: PluginRow?, context: PluginContext) async throws
        -> TicketShowResult
    {
        _ = try await requireConnection(context)
        let id: String
        if let reference = params.reference {
            id = try await resolveID(reference, context: context)
        } else if let callRow {
            id = callRow.item
        } else {
            throw ControlError(code: "bad_params", message: "Pass a ticket, such as 853, or run this in a ticket row.")
        }
        var copy = cached[id]
        var stale: String?
        let isFresh = copy.map { clock.date.timeIntervalSince($0.fetchedAt) < Self.freshFor } ?? false
        if params.refresh || !isFresh {
            do {
                copy = try await fetchTicket(id)
            } catch let error as TicketError {
                guard let old = copy, error.isUnreachable else { throw error }
                stale = "\(error.message) This copy is from \(TicketAge.ago(old.fetchedAt, now: clock.date))."
            }
        }
        guard let copy else { throw TicketError.notFound(params.reference ?? id) }
        let row = await context.state.rows.first { $0.item == id }
        return TicketShowResult(
            ticket: copy.detail, fetchedAt: Int64(copy.fetchedAt.timeIntervalSince1970 * 1000), stale: stale, row: row)
    }

    /// How long a copy counts as current: the selected ticket's refresh interval.
    static let freshFor: TimeInterval = 30
}

extension TicketError {
    /// ticket-manager did not answer, or not as itself, so a cached copy is the best there is.
    var isUnreachable: Bool {
        switch self {
        case .unreachable, .badResponse: true
        default: false
        }
    }
}
