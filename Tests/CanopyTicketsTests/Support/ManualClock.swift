import Foundation
import Synchronization

@testable import CanopyTickets

/// Time that moves only when a test says, so a refresh loop's minutes pass at once.
final class ManualClock: TicketClock {
    private struct State {
        var offset: Duration = .zero
        var sleepers: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Never>)] = [:]
    }

    private let start = ContinuousClock.now
    /// Seven hours after the fixture's waiting ticket last heard from its customer.
    private let startDate: Date
    private let state = Mutex(State())

    init(date: Date = Date(timeIntervalSince1970: 1_790_030_000)) {
        startDate = date
    }

    var now: ContinuousClock.Instant { start + state.withLock { $0.offset } }

    var date: Date {
        let offset = state.withLock { $0.offset }
        return startDate.addingTimeInterval(
            Double(offset.components.seconds) + Double(offset.components.attoseconds) / 1e18)
    }

    /// Tasks sleeping on this clock now.
    var sleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let wakeNow = state.withLock { state in
                    if Task.isCancelled || start + state.offset >= deadline { return true }
                    state.sleepers[id] = (deadline, continuation)
                    return false
                }
                if wakeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.offset += duration
            let now = start + state.offset
            let woken = state.sleepers.filter { $0.value.deadline <= now }
            for id in woken.keys { state.sleepers[id] = nil }
            return woken.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}
