import Foundation
import Testing

@testable import CanopyTickets

struct RefreshScheduleTests {
    let t0 = ContinuousClock.now
    let seen = RefreshSchedule.Watch(isVisible: true, hasRows: true, selected: "a")

    func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    func run(_ schedule: inout RefreshSchedule, _ job: RefreshSchedule.Job, at seconds: Int, succeeded: Bool = true) {
        schedule.started(job, at: at(seconds))
        schedule.finished(job, at: at(seconds), succeeded: succeeded)
    }

    @Test func rowsEveryMinuteAndTheSelectedTicketEveryHalfMinute() {
        var schedule = RefreshSchedule()
        #expect(schedule.due(at: at(0), seen) == [.rows, .ticket("a")])
        schedule.started(.rows, at: at(0))
        schedule.finished(.rows, at: at(1), succeeded: true)
        schedule.started(.ticket("a"), at: at(0))
        schedule.finished(.ticket("a"), at: at(1), succeeded: true)

        #expect(schedule.due(at: at(29), seen).isEmpty)
        #expect(schedule.nextDue(after: at(1), seen) == at(30))
        #expect(schedule.due(at: at(30), seen) == [.ticket("a")])
        #expect(schedule.due(at: at(60), seen) == [.rows, .ticket("a")])
    }

    @Test func nothingWhileTheWindowIsHidden() {
        let schedule = RefreshSchedule()
        let hidden = RefreshSchedule.Watch(isVisible: false, hasRows: true, selected: "a")
        #expect(schedule.due(at: at(0), hidden).isEmpty)
        #expect(schedule.nextDue(after: at(0), hidden) == nil)
    }

    @Test func noRowsNoRowsJob() {
        let schedule = RefreshSchedule()
        let empty = RefreshSchedule.Watch(isVisible: true, hasRows: false, selected: nil)
        #expect(schedule.due(at: at(0), empty).isEmpty)
        #expect(schedule.nextDue(after: at(0), empty) == nil)
    }

    @Test func failuresDoubleTheWaitUpToFiveMinutesAndASuccessResetsIt() {
        var schedule = RefreshSchedule()
        let watch = RefreshSchedule.Watch(isVisible: true, hasRows: true, selected: nil)
        var now = 0
        var waits: [Int] = []
        for _ in 0..<6 {
            run(&schedule, .rows, at: now, succeeded: false)
            let next = schedule.nextDue(after: at(now), watch)!
            waits.append(Int((next - at(now)).components.seconds))
            now += waits.last!
        }
        #expect(waits == [120, 240, 300, 300, 300, 300])
        run(&schedule, .rows, at: now)
        #expect(schedule.nextDue(after: at(now), watch) == at(now + 60))
    }

    @Test func aSuccessAnywhereRestoresEveryJobsPace() {
        var schedule = RefreshSchedule()
        run(&schedule, .rows, at: 0, succeeded: false)
        run(&schedule, .ticket("a"), at: 0)
        #expect(schedule.due(at: at(60), seen).contains(.rows))
    }

    @Test func aNudgeFetchesAtOnceButNotTwiceInFifteenSeconds() {
        var schedule = RefreshSchedule()
        run(&schedule, .ticket("a"), at: 0)
        run(&schedule, .rows, at: 0)
        schedule.nudge("a")
        #expect(schedule.due(at: at(10), seen).isEmpty)
        #expect(schedule.nextDue(after: at(10), seen) == at(15))
        #expect(schedule.due(at: at(15), seen) == [.ticket("a")])
        schedule.started(.ticket("a"), at: at(15))
        #expect(schedule.due(at: at(16), seen).isEmpty)
        schedule.finished(.ticket("a"), at: at(16), succeeded: true)
        #expect(schedule.nextDue(after: at(16), seen) == at(45))
    }

    @Test func aNudgedTicketNeverTriedIsDueAtOnce() {
        var schedule = RefreshSchedule()
        run(&schedule, .rows, at: 0)
        schedule.nudge("b")
        let watch = RefreshSchedule.Watch(isVisible: true, hasRows: true, selected: "b")
        #expect(schedule.due(at: at(1), watch) == [.ticket("b")])
    }

    @Test func aQueuedTicketIsFetchedOnceEvenWhenNotSelected() {
        var schedule = RefreshSchedule()
        let watch = RefreshSchedule.Watch(isVisible: true, hasRows: true, selected: nil)
        run(&schedule, .rows, at: 0)
        schedule.queue("b")
        #expect(schedule.due(at: at(1), watch) == [.ticket("b")])
        run(&schedule, .ticket("b"), at: 1)
        #expect(schedule.due(at: at(59), watch).isEmpty)
        #expect(schedule.nextDue(after: at(59), watch) == at(60))
    }

    @Test func aJobInFlightIsNeverDue() {
        var schedule = RefreshSchedule()
        schedule.started(.rows, at: at(0))
        #expect(!schedule.due(at: at(600), seen).contains(.rows))
    }

    @Test func forgettingATicketDropsItsWaitAndMark() {
        var schedule = RefreshSchedule()
        run(&schedule, .ticket("a"), at: 0, succeeded: false)
        schedule.queue("a")
        schedule.forget("a")
        let watch = RefreshSchedule.Watch(isVisible: true, hasRows: false, selected: nil)
        #expect(schedule.due(at: at(1), watch).isEmpty)
        #expect(
            schedule.due(at: at(1), RefreshSchedule.Watch(isVisible: true, hasRows: false, selected: "a")) == [
                .ticket("a")
            ])
    }
}
