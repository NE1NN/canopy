import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

@MainActor
struct TicketsRefreshTests {
    func connectedWithRows(_ dir: TempDir, _ references: [String]) async throws -> (TicketsHarness, [PluginRow]) {
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await harness.connect(token: "t")
        var rows: [PluginRow] = []
        for reference in references { rows.append(try await harness.newRow(reference)) }
        await harness.settle()
        await harness.transport.clearRequests()
        return (harness, rows)
    }

    func requests(_ harness: TicketsHarness) async -> [String] {
        await harness.transport.requests.map { $0.path + ($0.query.map { "?" + $0 } ?? "") }
    }

    func count(_ harness: TicketsHarness, _ request: String) async -> Int {
        await requests(harness).filter { $0 == request }.count
    }

    @Test func rowsEveryMinuteAndTheSelectedTicketEveryHalfMinute() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853", "849"])
        harness.setViewing(visible: true, frontmost: false)
        await harness.select(rows[0].path)

        #expect(await eventually { await requests(harness).count == 2 })
        #expect(
            Set(await requests(harness)) == [
                "/api/v1/tickets?ids=\(rows[0].item),\(rows[1].item)", "/api/v1/tickets/\(rows[0].item)",
            ])
        await harness.settle()
        #expect(await requests(harness).count == 2)
        harness.clock.advance(by: .seconds(30))
        #expect(await eventually { await requests(harness).count == 3 })
        #expect(await requests(harness).last == "/api/v1/tickets/\(rows[0].item)")
        await harness.settle()
        harness.clock.advance(by: .seconds(30))
        #expect(await eventually { await requests(harness).count == 5 })
    }

    @Test func nothingIsFetchedWhileTheWindowIsHiddenAndOnceWhenItShows() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853"])
        await harness.select(rows[0].path)
        harness.setViewing(visible: false, frontmost: false)
        await harness.settle()
        harness.clock.advance(by: .seconds(3600))
        await harness.settle()
        #expect(await requests(harness).isEmpty)

        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await requests(harness).count == 2 })
        await harness.settle()
        #expect(await requests(harness).count == 2)
    }

    @Test func selectingOrComingToTheFrontFetchesAtMostEveryFifteenSeconds() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853", "849"])
        let first = "/api/v1/tickets/\(rows[0].item)"
        harness.setViewing(visible: true, frontmost: true)
        await harness.select(rows[0].path)
        #expect(await eventually { await requests(harness).count == 2 })
        await harness.settle()

        await harness.select(rows[1].path)
        #expect(await eventually { await requests(harness).last == "/api/v1/tickets/\(rows[1].item)" })
        await harness.select(rows[0].path)
        await harness.settle()
        #expect(await count(harness, first) == 1)
        harness.clock.advance(by: .seconds(15))
        #expect(await eventually { await count(harness, first) == 2 })

        await harness.settle()
        harness.setViewing(visible: true, frontmost: false)
        await harness.settle()
        harness.clock.advance(by: .seconds(15))
        harness.setViewing(visible: true, frontmost: true)
        #expect(await eventually { await count(harness, first) == 3 })
    }

    @Test func failuresBackOffAndASuccessRestoresThePace() async throws {
        let dir = try TempDir()
        let (harness, _) = try await connectedWithRows(dir, ["853"])
        await harness.transport.failEverything(URLError(.cannotConnectToHost))
        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await requests(harness).count == 1 })
        for (wait, total) in [(120, 2), (240, 3), (300, 4), (300, 5)] {
            await harness.settle()
            harness.clock.advance(by: .seconds(wait - 1))
            await harness.settle()
            #expect(await requests(harness).count == total - 1)
            harness.clock.advance(by: .seconds(1))
            #expect(await eventually { await requests(harness).count == total })
        }
        await harness.transport.failEverything(nil)
        await harness.settle()
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { await requests(harness).count == 6 })
        await harness.settle()
        harness.clock.advance(by: .seconds(60))
        #expect(await eventually { await requests(harness).count == 7 })
    }

    @Test func aMalformedIdShowsItsRowMissingAndTheOthersStillRefresh() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853", "849"])
        let stray = try await harness.addRowByHand(item: "from-another-deployment", title: "0700-stray")
        await harness.transport.markMalformed("from-another-deployment")
        #expect(await eventually { harness.host.context("tickets")?.state.rows.count == 3 })
        harness.setViewing(visible: true, frontmost: false)

        #expect(await eventually { await harness.section()?.rows.first { $0.path == stray.path }?.isMissing == true })
        let section = await harness.section()
        #expect(section?.rows.filter(\.isMissing).map(\.path) == [stray.path])
        #expect(section?.rows.first { $0.path == rows[0].path }?.look.accessories.first?.kind == .dot)

        await harness.settle()
        await harness.transport.clearRequests()
        harness.clock.advance(by: .seconds(60))
        #expect(await eventually { await requests(harness).count == 1 })
        await harness.settle()
        #expect(await requests(harness) == ["/api/v1/tickets?ids=\(rows[0].item),\(rows[1].item)"])
    }

    @Test func aTicketGoneFromTicketManagerShowsItsRowMissing() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853", "849"])
        await harness.transport.remove(rows[1].item)
        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await harness.section()?.rows.last?.isMissing == true })
        #expect(await harness.section()?.rows.first?.isMissing == false)
    }

    @Test func aTicketThatChangedOnTicketManagerIsFetchedForItsFiles() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853"])
        await harness.transport.bumpActivity(of: rows[0].item, to: 1_790_050_000_000)
        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await requests(harness).contains("/api/v1/tickets/\(rows[0].item)") })
        #expect(
            await eventually { TicketFiles.read(from: rows[0].path)?.detail.ticket.lastActivityAt == 1_790_050_000_000 }
        )
    }

    @Test func aRelaunchShowsCachedTicketsBeforeAnyFetch() async throws {
        let dir = try TempDir()
        let (harness, rows) = try await connectedWithRows(dir, ["853"])
        await harness.transport.failEverything(URLError(.cannotConnectToHost))
        let again = try await harness.restart()
        #expect(await eventually { again.store.ticket(rows[0].item).detail?.ticket.number == "0853" })
        #expect(await again.section()?.rows.first?.look.accessories.first?.kind == .dot)
        #expect(await harness.transport.requests.isEmpty)
    }

    @Test func stoppingEndsTheLoop() async throws {
        let dir = try TempDir()
        let (harness, _) = try await connectedWithRows(dir, ["853"])
        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await requests(harness).count == 1 })
        _ = try await harness.host.disable("tickets", force: true)
        await harness.transport.clearRequests()
        harness.clock.advance(by: .seconds(600))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await requests(harness).isEmpty)
        #expect(harness.clock.sleepers == 0)
    }
}
