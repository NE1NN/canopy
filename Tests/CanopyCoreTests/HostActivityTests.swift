import Foundation
import Testing

@testable import CanopyCore

struct HostActivityTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aBusySessionKeepsTheHostBusy() {
        let summary = HostActivity.summary(
            panes: [
                HostPaneSample(session: "p1", isRunning: true, lastInput: now.addingTimeInterval(-3600)),
                HostPaneSample(session: "p2", isRunning: true, lastInput: now.addingTimeInterval(-7200)),
            ],
            sessions: ["p1": SessionActivity(busy: false), "p2": SessionActivity(busy: true)], now: now)

        #expect(summary == HostActivitySummary(attached: 2, busy: true, quietFor: .seconds(3600)))
    }

    @Test func quietPanesReportHowLongSinceTheLastKey() {
        let summary = HostActivity.summary(
            panes: [HostPaneSample(session: "p1", isRunning: true, lastInput: now.addingTimeInterval(-90))],
            sessions: ["p1": SessionActivity(busy: false)], now: now)

        #expect(summary == HostActivitySummary(attached: 1, busy: false, quietFor: .seconds(90)))
    }

    @Test func exitedPanesAndSessionsTheHostLacksDoNotCount() {
        let summary = HostActivity.summary(
            panes: [
                HostPaneSample(session: "p1", isRunning: false, lastInput: now),
                HostPaneSample(session: "p2", isRunning: true, lastInput: .distantPast),
            ],
            sessions: ["p1": SessionActivity(busy: true)], now: now)

        #expect(summary.attached == 0)
        #expect(!summary.busy)
    }
}

extension HostConnectionTests {
    @Test func probesDoNotCountAsUse() async throws {
        let setup = try Setup()
        try await setup.connection.connect()

        setup.clock.advance(by: .seconds(11 * 60))
        _ = await setup.connection.probe(["true"], timeout: .seconds(5))
        await setup.connection.panesActive(attached: 0, busy: false, quietFor: .seconds(11 * 60))

        #expect(await setup.connection.state == .idle)
    }

    @Test func aProbeOfAHostThatIsNotConnectedRunsNothing() async throws {
        let setup = try Setup()

        #expect(await setup.connection.probe(["true"], timeout: .seconds(5)) == nil)
        #expect(setup.launcher.masters.isEmpty)
    }
}
