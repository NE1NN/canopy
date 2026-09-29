import CanopyCore
import Foundation

/// Discord support tickets from ticket-manager, as rows the author picks. It asks ticket-manager for anything only
/// while Canopy's window can be seen, or when a command asks, and writes each row's `ticket.md` and `ticket.json`.
///
/// Its section of config.json holds `url`, ticket-manager's address, `run`, the command new ticket rows start with,
/// and `web`, ticket-manager's page for a ticket. The token lives only in the Keychain.
public actor TicketsPlugin: CanopyPlugin {
    public nonisolated let info = PluginInfo(id: TicketMethod.plugin, name: "Tickets", symbol: "ticket")
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
    var startFailure: String?
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
    /// Each ticket's last detail, from ticket-manager or a row's ticket.json.
    var cached: [String: CachedTicket] = [:]
    var tasks: [Task<Void, Never>] = []
    var isLoopAsleep = true

    public init(
        transport: any TicketTransport = URLSessionTicketTransport(), clock: any TicketClock = SystemTicketClock()
    ) {
        self.transport = transport
        self.clock = clock
    }

    /// Nothing in flight and the refresh loop asleep, for tests that move the clock.
    var isIdle: Bool { requestsInFlight == 0 && isLoopAsleep }

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
                throw TicketError.notStarted("The Keychain refused to read the token: \(Self.describe(error))")
            }
            guard let token, !token.isEmpty else {
                throw TicketError.notStarted(
                    "No token is saved. Run `canopy ticket connect \(settings.url.absoluteString)`.")
            }
            connection = Connection(settings: settings, token: token)
            startFailure = nil
            await store.connected(url: settings.url, web: settings.web)
            startRefreshing(context)
        } catch let error as TicketError {
            let reason = if case .notStarted(let reason) = error { reason } else { error.message }
            startFailure = reason
            throw ControlError(code: "plugin_not_started", message: reason)
        }
    }

    public func stop(_ context: PluginContext) async {
        generation += 1
        for task in tasks { task.cancel() }
        tasks = []
        connection = nil
        me = nil
        lastSuccess = nil
        lastFailure = nil
        warningShown = false
        openTickets = nil
        closedTickets = nil
        known = [:]
        cached = [:]
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

    public nonisolated func pickerCommand(for item: PluginItem) -> String? {
        "canopy ticket new \(item.title) --select"
    }

    // MARK: Items and rows

    public func items(matching query: PluginQuery, context: PluginContext) async throws -> [PluginItem] {
        throw TicketError.notFound(query.text).controlError
    }

    public func resolve(_ reference: String, context: PluginContext) async throws -> String {
        throw TicketError.notFound(reference).controlError
    }

    public func seed(for item: String, context: PluginContext) async throws -> PluginRowSeed {
        throw TicketError.notFound(item).controlError
    }

    public func fill(_ row: PluginRow, context: PluginContext) async throws {}

    // MARK: Helpers

    /// The plugin's connection, or why there is none: off, or on without having started.
    func requireConnection(_ context: PluginContext) async throws -> Connection {
        guard await context.state.isOn else { throw TicketError.off(url: Self.configuredURL(await context.config)) }
        guard let connection else {
            throw TicketError.notStarted(startFailure ?? "Run `canopy ticket connect <url>`.")
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
