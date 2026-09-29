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
            throw TicketError.notStarted(startFailure ?? "Run `canopy ticket connect \(address)` again.")
        }
        // A plugin whose section did not change keeps running, so the new token takes over here.
        current.token = token
        connection = current
        me = email
        await store.setMe(email)
        await succeeded()
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
