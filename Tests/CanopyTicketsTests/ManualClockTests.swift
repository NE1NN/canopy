import Foundation
import Testing

@testable import CanopyTickets

struct ManualClockTests {
    @Test func sleepersWakeWhenTimePassesTheirDeadline() async {
        let clock = ManualClock()
        let deadline = clock.now + .seconds(30)
        let woke = Task { await clock.sleep(until: deadline) }
        #expect(await eventually { clock.sleepers == 1 })
        clock.advance(by: .seconds(29))
        #expect(clock.sleepers == 1)
        clock.advance(by: .seconds(1))
        await woke.value
        #expect(clock.sleepers == 0 && clock.now == deadline)
    }

    @Test func cancellingWakesASleeper() async {
        let clock = ManualClock()
        let sleeping = Task { await clock.sleep(until: clock.now + .seconds(3600)) }
        #expect(await eventually { clock.sleepers == 1 })
        sleeping.cancel()
        await sleeping.value
        #expect(clock.sleepers == 0)
    }

    @Test func theDateMovesWithIt() {
        let clock = ManualClock(date: Date(timeIntervalSince1970: 100))
        clock.advance(by: .seconds(20))
        #expect(clock.date == Date(timeIntervalSince1970: 120))
    }
}
