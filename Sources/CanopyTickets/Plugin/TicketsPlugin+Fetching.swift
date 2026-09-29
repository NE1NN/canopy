import CanopyCore
import Foundation

extension TicketsPlugin {
    /// Asks ticket-manager, and keeps what the answer says about it: when it last answered, and the section's warning
    /// while it rejects the token. Results from before a restart are not recorded.
    func perform<T: Sendable>(_ request: @Sendable (TicketAPI) async throws -> T) async throws -> T {
        guard let connection else { throw startError ?? TicketError.notStarted("") }
        let generation = self.generation
        let api = TicketAPI(base: connection.settings.url, token: connection.token, transport: transport)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        do {
            let value = try await request(api)
            if generation == self.generation { await succeeded() }
            return value
        } catch {
            let ticketError = TicketError.from(error, url: connection.settings.url.absoluteString)
            // A request the caller gave up on, such as the picker's while the author types, says nothing about
            // ticket-manager.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if generation == self.generation, !cancelled { await failed(ticketError) }
            throw ticketError
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
        let generation = self.generation
        let list: [TicketSummary]
        if closed {
            async let closedList = perform { try await $0.tickets(status: .closed) }
            async let archived = perform { try await $0.tickets(status: .archived) }
            list = try await closedList + archived
        } else {
            list = try await perform { try await $0.tickets(status: .open) }
        }
        guard generation == self.generation else { return list }
        if closed { closedTickets = list } else { openTickets = list }
        remember(list)
        return list
    }

    func remember(_ tickets: [TicketSummary]) {
        for ticket in tickets {
            known[ticket.id] = ticket
        }
    }
}

extension TicketsPlugin {
    /// The tickets with these ids, 50 at a time. A batch ticket-manager answers 400 for holds a malformed id, such as one
    /// from another deployment: it is split until that id is alone, which then joins `malformed` and shows as missing,
    /// so one bad row never stops the others refreshing.
    func fetchSummaries(ids: [String]) async throws -> [TicketSummary] {
        let generation = self.generation
        var found: [TicketSummary] = []
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + TicketAPI.maximumIDs, ids.count)])
            found += try await fetchBatch(batch, generation: generation)
            start += TicketAPI.maximumIDs
        }
        if generation == self.generation { remember(found) }
        return found
    }

    /// A batch split after a restart stops there, so it never asks the new connection about the old one's ids.
    private func fetchBatch(_ ids: [String], generation: Int) async throws -> [TicketSummary] {
        guard !ids.isEmpty, generation == self.generation else { return [] }
        do {
            return try await perform { try await $0.tickets(ids: ids) }
        } catch TicketError.badRequest {
            guard generation == self.generation else { return [] }
            guard ids.count > 1 else {
                malformed.insert(ids[0])
                return []
            }
            let half = ids.count / 2
            return try await fetchBatch(Array(ids[..<half]), generation: generation)
                + fetchBatch(Array(ids[half...]), generation: generation)
        }
    }

    /// Fetches the ticket's detail and puts it everywhere it shows: the store, its rows' files, and its rows' looks.
    /// A ticket ticket-manager no longer has marks its rows missing.
    @discardableResult
    func fetchTicket(_ id: String) async throws -> CachedTicket {
        let generation = self.generation
        await store.setFetching(id, true)
        do {
            let (detail, data) = try await perform { try await $0.ticket(id: id) }
            let copy = CachedTicket(detail: detail, data: data, fetchedAt: clock.date)
            guard generation == self.generation else { return copy }
            cached[id] = copy
            remember([detail.ticket])
            await setMissing(id, false)
            await store.setDetail(detail, fetchedAt: copy.fetchedAt)
            await store.setFetching(id, false)
            await writeFiles(copy)
            await showLooks()
            return copy
        } catch let error as TicketError {
            if generation == self.generation {
                await store.setFetching(id, false)
                switch error {
                case .notFound, .badRequest:
                    await setMissing(id, true)
                    await showLooks()
                default:
                    await store.setFailure(id, TicketFailure(code: error.code, message: error.message, at: clock.date))
                }
            }
            if case .badRequest = error { throw TicketError.notFound(id) }
            throw error
        }
    }

    /// Whether ticket-manager no longer has the ticket, for its row's look, its panel, and how often it is asked for.
    func setMissing(_ id: String, _ isMissing: Bool) async {
        schedule.markGone(id, isMissing)
        guard isMissing != missing.contains(id) else { return }
        if isMissing { missing.insert(id) } else { missing.remove(id) }
        await store.setMissing(id, isMissing)
    }

    /// Writes the copy into each of its ticket's rows' folders.
    func writeFiles(_ copy: CachedTicket) async {
        guard let context else { return }
        for row in await context.state.rows where row.item == copy.detail.ticket.id {
            _ = try? TicketFiles.write(detail: copy.detail, data: copy.data, fetchedAt: copy.fetchedAt, into: row.path)
        }
    }

    /// Sets each row's look from what the plugin knows about its ticket.
    func showLooks() async {
        guard let context else { return }
        var looks: [String: PluginRowLook] = [:]
        for row in await context.state.rows {
            let summary = known[row.item] ?? cached[row.item]?.detail.ticket
            let look = TicketLook.look(
                title: row.title, summary: summary,
                isMissing: missing.contains(row.item) || malformed.contains(row.item))
            if row.look != look { looks[row.path] = look }
        }
        if !looks.isEmpty {
            await context.setLooks(looks)
        }
    }
}

extension TicketsPlugin {
    /// Fetches the ticket now, as the panel's refresh button does. A failure shows in the store, where the panel's
    /// banner reads it.
    public func refresh(_ ticket: String) async {
        guard connection != nil else { return }
        _ = try? await fetchTicket(ticket)
    }
}
