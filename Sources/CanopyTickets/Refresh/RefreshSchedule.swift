import Foundation

/// When the plugin asks ticket-manager for what. Canopy asks only while its window can be seen: the rows' tickets every
/// minute, the selected ticket every half minute and when it is picked, and a row's ticket once when ticket-manager says
/// it changed. Each job waits twice as long after each failure, up to five minutes.
public struct RefreshSchedule: Sendable, Equatable {
    public enum Job: Sendable, Hashable {
        /// Every row's ticket, through `tickets?ids=`.
        case rows
        /// One ticket's detail, through `tickets/<id>`.
        case ticket(String)
    }

    /// What the plugin watches.
    public struct Watch: Sendable, Equatable {
        public var isVisible: Bool
        public var hasRows: Bool
        /// The selected row's ticket.
        public var selected: String?

        public init(isVisible: Bool, hasRows: Bool, selected: String?) {
            self.isVisible = isVisible
            self.hasRows = hasRows
            self.selected = selected
        }
    }

    public static let rowsEvery: Duration = .seconds(60)
    public static let selectedEvery: Duration = .seconds(30)
    public static let nudgeGap: Duration = .seconds(15)
    public static let longestWait: Duration = .seconds(300)

    private var lastTry: [Job: ContinuousClock.Instant] = [:]
    private var failures: [Job: Int] = [:]
    private var inFlight: Set<Job> = []
    /// Tickets to fetch once, as soon as 15 seconds have passed since their last try.
    private var pending: Set<String> = []
    /// Tickets ticket-manager no longer has, asked for again only every five minutes.
    private var gone: Set<String> = []
    /// Tickets ticket-manager calls malformed, never asked for.
    private var excluded: Set<String> = []

    public init() {}

    /// The jobs due now, rows first.
    public func due(at now: ContinuousClock.Instant, _ watch: Watch) -> [Job] {
        candidates(watch).filter { $0.at.map { $0 <= now } ?? true }.map(\.job)
    }

    /// When the next job falls due, which may be now, or nil while the window cannot be seen or nothing is scheduled.
    public func nextDue(after now: ContinuousClock.Instant, _ watch: Watch) -> ContinuousClock.Instant? {
        candidates(watch).map { $0.at.map { max($0, now) } ?? now }.min()
    }

    /// The ticket was just selected, or the window came to the front with it selected: due at once, unless it was tried
    /// in the last 15 seconds.
    public mutating func nudge(_ ticket: String) {
        guard !excluded.contains(ticket) else { return }
        pending.insert(ticket)
    }

    /// A row's ticket changed on ticket-manager: fetch it once at the next chance.
    public mutating func queue(_ ticket: String) {
        guard !excluded.contains(ticket) else { return }
        pending.insert(ticket)
    }

    public mutating func started(_ job: Job, at now: ContinuousClock.Instant) {
        inFlight.insert(job)
        lastTry[job] = now
        if case .ticket(let ticket) = job { pending.remove(ticket) }
    }

    /// A failure doubles the job's wait, up to five minutes. A success means ticket-manager answers again, so every job
    /// returns to the usual pace.
    public mutating func finished(_ job: Job, at now: ContinuousClock.Instant, succeeded: Bool) {
        inFlight.remove(job)
        if succeeded {
            failures = [:]
        } else {
            failures[job, default: 0] += 1
        }
    }

    /// A ticket ticket-manager no longer has waits five minutes between tries, whatever else succeeds, until it is
    /// found again.
    public mutating func markGone(_ ticket: String, _ isGone: Bool) {
        if isGone { gone.insert(ticket) } else { gone.remove(ticket) }
    }

    /// A ticket ticket-manager calls malformed is never asked for again, selected or not.
    public mutating func exclude(_ ticket: String) {
        excluded.insert(ticket)
        pending.remove(ticket)
    }

    /// Forgets a ticket that no longer has a row and is not selected.
    public mutating func forget(_ ticket: String) {
        let job = Job.ticket(ticket)
        lastTry[job] = nil
        failures[job] = nil
        pending.remove(ticket)
        gone.remove(ticket)
    }

    /// Each job that can run, and when it falls due: nil for at once.
    private func candidates(_ watch: Watch) -> [(job: Job, at: ContinuousClock.Instant?)] {
        guard watch.isVisible else { return [] }
        var found: [(job: Job, at: ContinuousClock.Instant?)] = []
        if watch.hasRows, !inFlight.contains(.rows) {
            found.append((.rows, periodic(.rows, every: Self.rowsEvery)))
        }
        var tickets: [String: ContinuousClock.Instant?] = [:]
        if let selected = watch.selected, !inFlight.contains(.ticket(selected)), !excluded.contains(selected) {
            tickets[selected] = periodic(.ticket(selected), every: Self.selectedEvery)
        }
        for ticket in pending where !inFlight.contains(.ticket(ticket)) {
            let at = lastTry[.ticket(ticket)].map { $0 + Self.nudgeGap }
            tickets[ticket] = Self.earlier(tickets[ticket] ?? at, at)
        }
        found += tickets.sorted { $0.key < $1.key }.map { (Job.ticket($0.key), $0.value) }
        return found
    }

    /// When a job that repeats is next due: its interval after its last try, doubled for each failure since the last
    /// success up to five minutes, or nil for at once when it was never tried.
    private func periodic(_ job: Job, every interval: Duration) -> ContinuousClock.Instant? {
        guard let last = lastTry[job] else { return nil }
        if case .ticket(let ticket) = job, gone.contains(ticket) { return last + Self.longestWait }
        let doubled = interval * (1 << min(failures[job] ?? 0, 8))
        return last + min(doubled, Self.longestWait)
    }

    private static func earlier(_ a: ContinuousClock.Instant?, _ b: ContinuousClock.Instant?) -> ContinuousClock
        .Instant?
    {
        guard let a, let b else { return nil }
        return min(a, b)
    }
}
