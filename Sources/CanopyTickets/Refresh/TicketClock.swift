import Foundation

/// Time for the refresh loop. Tests move it by hand.
public protocol TicketClock: Sendable {
    var now: ContinuousClock.Instant { get }
    /// The wall-clock time, for "updated 20 s ago" and ticket.json's date.
    var date: Date { get }
    /// Returns at `deadline`, or at once when the calling task is cancelled.
    func sleep(until deadline: ContinuousClock.Instant) async
}

public struct SystemTicketClock: TicketClock {
    public init() {}

    public var now: ContinuousClock.Instant { .now }
    public var date: Date { Date() }

    public func sleep(until deadline: ContinuousClock.Instant) async {
        try? await Task.sleep(until: deadline, clock: .continuous)
    }
}
