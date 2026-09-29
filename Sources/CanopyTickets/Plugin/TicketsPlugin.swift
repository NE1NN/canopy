import CanopyCore
import Foundation

/// Discord support tickets from ticket-manager, as rows the author picks. It asks ticket-manager for anything only
/// while Canopy's window can be seen, or when a command asks, and writes each row's `ticket.md` and `ticket.json`.
///
/// Its section of config.json holds `url`, ticket-manager's address, `run`, the command new ticket rows start with,
/// and `web`, ticket-manager's page for a ticket. The token lives only in the Keychain.
public actor TicketsPlugin: CanopyPlugin {
    public nonisolated let info = PluginInfo(
        id: TicketMethod.plugin, name: "Tickets", symbol: "ticket", itemName: "Ticket")
    public nonisolated let filters = TicketListing.filters
    public nonisolated let methods = TicketMethod.all
    public nonisolated let readOnlyMethods = TicketMethod.readOnly
    /// What the panels show.
    public nonisolated let store = TicketStore()

    static let tokenName = "token"

    struct Connection: Sendable {
        var settings: TicketSettings
        var token: String
    }

    let transport: any TicketTransport
    let clock: any TicketClock

    var connection: Connection?
    var context: PluginContext?
    /// A new number at each start and stop, so what an earlier start fetched never lands after it.
    var generation = 0
    /// Why the last start failed, while the plugin is on without running.
    var startError: TicketError?
    /// The connected engineer's email, which Mine compares owners with.
    var me: String?
    var lastSuccess: Date?
    /// The last failure, until a request succeeds.
    var lastFailure: TicketError?
    /// Whether the section shows a warning this plugin set, which the next success clears.
    var warningShown = false
    var requestsInFlight = 0
    /// The lists as last fetched, for the picker to narrow without asking again.
    var openTickets: [TicketSummary]?
    var closedTickets: [TicketSummary]?
    /// Every ticket seen, by id.
    var known: [String: TicketSummary] = [:]
    /// Tickets ticket-manager no longer has, or finds malformed, whose rows show as missing.
    var missing: Set<String> = []
    /// Ids ticket-manager answers 400 for, left out of the rows' refresh.
    var malformed: Set<String> = []
    /// Each ticket's last detail, from ticket-manager or a row's ticket.json.
    var cached: [String: CachedTicket] = [:]
    var tasks: [Task<Void, Never>] = []
    var isLoopAsleep = true
    var schedule = RefreshSchedule()
    var watch = RefreshSchedule.Watch(isVisible: false, hasRows: false, selected: nil)
    var wasFrontmost = false
    /// The host's state the plugin last took in, so tests know when it has caught up.
    var handledState: PluginState?
    /// The rows' tickets as last seen, so the schedule forgets those whose rows went.
    var watchedRows: Set<String> = []
    /// The loop's sleep, which a change in what the plugin watches cancels.
    var sleeper: Task<Void, Never>?

    public init(
        transport: any TicketTransport = URLSessionTicketTransport(), clock: any TicketClock = SystemTicketClock()
    ) {
        self.transport = transport
        self.clock = clock
    }

    /// Nothing in flight and the refresh loop asleep, for tests that move the clock.
    var isIdle: Bool { requestsInFlight == 0 && isLoopAsleep }

    /// Idle, having taken in the state the host shows now, for tests that move the clock.
    func hasSettled(on expected: PluginState) -> Bool {
        isIdle && (connection == nil || handledState == expected)
    }

    // MARK: Turning on and off

    public func start(_ context: PluginContext) async throws {
        generation += 1
        self.context = context
        do {
            let settings = try TicketSettings(await context.config)
            let token: String?
            do {
                token = try context.secrets.read(Self.tokenName)
            } catch {
                throw TicketError.keychain(Self.describe(error))
            }
            guard let token, !token.isEmpty else {
                throw TicketError.notStarted(
                    "No token is saved. Run `canopy ticket connect \(settings.url.absoluteString)`.")
            }
            connection = Connection(settings: settings, token: token)
            startError = nil
            await store.connected(url: settings.url, web: settings.web)
            startRefreshing(context)
        } catch let error as TicketError {
            startError = error
            // The rows still show, so their panels show the copies they saved.
            await loadSavedTickets(context)
            let reason = if case .notStarted(let reason) = error { reason } else { error.message }
            throw ControlError(code: error.code, message: reason)
        }
    }

    public func stop(_ context: PluginContext) async {
        generation += 1
        for task in tasks { task.cancel() }
        tasks = []
        sleeper?.cancel()
        sleeper = nil
        watchedRows = []
        handledState = nil
        connection = nil
        me = nil
        lastSuccess = nil
        lastFailure = nil
        warningShown = false
        openTickets = nil
        closedTickets = nil
        known = [:]
        cached = [:]
        missing = []
        malformed = []
        isLoopAsleep = true
        await store.clear()
    }

    public func status(_ context: PluginContext) async -> String? {
        guard let connection else { return nil }
        let url = connection.settings.url.absoluteString
        let updated = lastSuccess.map { TicketAge.ago($0, now: clock.date) }
        if let lastFailure {
            return "\(lastFailure.message) Last updated \(updated ?? "never")."
        }
        guard let updated else { return "connected to \(url), not fetched yet" }
        let who = me.map { " as \($0)" } ?? ""
        return "connected\(who) to \(url), updated \(updated)"
    }

    public nonisolated func turnOnCommand(config: JSONValue) -> String {
        "canopy ticket connect \(Self.configuredURL(config) ?? "<url>")"
    }

    /// `canopy ticket new 0853-sameergoyal --select`, or `canopy ticket select 0853-sameergoyal` for a ticket with a
    /// row.
    public nonisolated func pickerCommand(for action: PluginPickerAction) -> String? {
        switch action {
        case .create(let item): "canopy ticket new \(Self.reference(title: item.title, id: item.id)) --select"
        case .select(let row): "canopy ticket select \(Self.reference(title: row.title, id: row.item))"
        }
    }

    /// The row title when it names the ticket by number, as it always does for ticket-manager's names, and the id
    /// otherwise, quoted for a shell.
    static func reference(title: String, id: String) -> String {
        NewRowAction.quoted(TicketName(title).number == nil ? id : title)
    }

    // MARK: Items and rows

    /// Open tickets, or closed and archived ones with the Closed toggle, fetched afresh when the picker opens or a
    /// toggle changes, and narrowed from what was fetched otherwise.
    public func items(matching query: PluginQuery, context: PluginContext) async throws -> [PluginItem] {
        try await converting {
            _ = try await requireConnection(context)
            let closed = query.toggles.contains("closed")
            let fetched = closed ? closedTickets : openTickets
            let tickets = query.fresh || fetched == nil ? try await fetchList(closed: closed) : fetched ?? []
            let owner = TicketOwnerFilter(rawValue: query.choice ?? "") ?? .anyone
            if owner == .mine, me == nil {
                try await refreshMe()
            }
            let now = clock.date
            return TicketListing.list(tickets, TicketListQuery(owner: owner, text: query.text), me: me).map {
                TicketListing.item($0, now: now)
            }
        }
    }

    public func resolve(_ reference: String, context: PluginContext) async throws -> String {
        try await converting { try await resolveID(reference, context: context) }
    }

    /// The row's title and folder name are the ticket's name without `ticket-` or `closed-`, and new rows run config's
    /// `run`.
    public func seed(for item: String, context: PluginContext) async throws -> PluginRowSeed {
        try await converting {
            let connection = try await requireConnection(context)
            var summary = known[item]
            if summary == nil {
                summary = try await fetchSummaries(ids: [item]).first { $0.id == item }
            }
            guard let summary else { throw TicketError.notFound(item) }
            let title = TicketName.rowTitle(for: summary.name)
            return PluginRowSeed(title: title, folderName: title, run: connection.settings.run)
        }
    }

    /// Writes `ticket.md` and `ticket.json`: from ticket-manager, or from the copy the plugin has when it cannot be
    /// reached.
    public func fill(_ row: PluginRow, context: PluginContext) async throws {
        try await converting {
            do {
                let copy = try await fetchTicket(row.item)
                try TicketFiles.write(detail: copy.detail, data: copy.data, fetchedAt: copy.fetchedAt, into: row.path)
            } catch let error as TicketError {
                guard let copy = cached[row.item] else { throw error }
                try TicketFiles.write(detail: copy.detail, data: copy.data, fetchedAt: copy.fetchedAt, into: row.path)
            }
        }
    }

    // MARK: Helpers

    /// The plugin's connection, or why there is none: off, or on without having started.
    func requireConnection(_ context: PluginContext) async throws -> Connection {
        guard await context.state.isOn else { throw TicketError.off(url: Self.configuredURL(await context.config)) }
        guard let connection else {
            throw startError ?? TicketError.notStarted("Run `canopy ticket connect <url>`.")
        }
        return connection
    }

    static func configuredURL(_ config: JSONValue) -> String? {
        guard case .object(let fields) = config, case .string(let url)? = fields["url"], !url.isEmpty else {
            return nil
        }
        return url
    }

    static func describe(_ error: any Error) -> String {
        (error as? SecretStoreError)?.description ?? "\(error)"
    }

    /// Runs `body`, turning a `TicketError` into the `ControlError` the control API and the host show.
    func converting<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as TicketError {
            throw error.controlError
        }
    }
}
