import CanopyCore
import Foundation

extension TicketsPlugin {
    /// Asks ticket-manager, and keeps what the answer says about it: when it last answered, and the section's warning
    /// while it rejects the token. Results from before a restart are not recorded.
    func perform<T: Sendable>(_ request: @Sendable (TicketAPI) async throws -> T) async throws -> T {
        guard let connection else { throw TicketError.notStarted(startFailure ?? "") }
        let generation = self.generation
        let api = TicketAPI(base: connection.settings.url, token: connection.token, transport: transport)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        do {
            let value = try await request(api)
            if generation == self.generation { await succeeded() }
            return value
        } catch {
            let error = TicketError.from(error, url: connection.settings.url.absoluteString)
            if generation == self.generation { await failed(error) }
            throw error
        }
    }

    func succeeded() async {
        lastSuccess = clock.date
        lastFailure = nil
        if warningShown {
            warningShown = false
            await context?.setWarning(nil)
        }
    }

    /// Only ticket-manager not answering as it should counts: a ticket it does not have is an answer.
    func failed(_ error: TicketError) async {
        guard error.backsOff else { return }
        lastFailure = error
        if let warning = error.warning {
            warningShown = true
            await context?.setWarning(warning)
        }
    }

    /// Asks who the token belongs to, for Mine and the status line.
    @discardableResult
    func refreshMe() async throws -> String {
        let generation = self.generation
        let email = try await perform { try await $0.me() }
        if generation == self.generation {
            me = email
            await store.setMe(email)
        }
        return email
    }

    /// Open tickets, or closed and archived ones together, always fetched afresh.
    func fetchList(closed: Bool) async throws -> [TicketSummary] {
        let list: [TicketSummary]
        if closed {
            async let closedList = perform { try await $0.tickets(status: .closed) }
            async let archived = perform { try await $0.tickets(status: .archived) }
            list = try await closedList + archived
            closedTickets = list
        } else {
            list = try await perform { try await $0.tickets(status: .open) }
            openTickets = list
        }
        remember(list)
        return list
    }

    func remember(_ tickets: [TicketSummary]) {
        for ticket in tickets {
            known[ticket.id] = ticket
        }
    }

    /// Starts what runs while the plugin is on.
    func startRefreshing(_ context: PluginContext) {
        tasks.append(Task { _ = try? await self.refreshMe() })
    }
}
