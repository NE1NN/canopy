import CanopyCore
import Foundation
import Testing

@testable import CanopyTickets

@MainActor
struct TicketsConnectTests {
    @Test func connectChecksTheTokenSavesItAndTurnsTheSectionOn() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, config: #"{"minPaneColumns": 90}"#, serverToken: "good")

        let result = try await harness.connect(token: "good", web: "https://tm.example.com/t/{id}")

        #expect(
            result
                == TicketConnectResult(
                    url: harness.url, email: "hindie@example.com", web: "https://tm.example.com/t/{id}"))
        #expect(try harness.secrets.read("token") == "good")
        #expect(
            try PluginConfig.sections(in: harness.home.configFile)["tickets"]
                == .object(["url": .string(harness.url), "web": "https://tm.example.com/t/{id}"]))
        #expect(await harness.host.list().first { $0.id == "tickets" }?.on == true)
        #expect(harness.store.me == "hindie@example.com")
        #expect(harness.store.url?.absoluteString == harness.url)
        #expect(await harness.section()?.warning == nil)
    }

    @Test func aRejectedTokenSavesNothing() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "good")

        await #expect { try await harness.connect(token: "bad") } throws: {
            ($0 as? ControlError)?.code == "token_rejected"
        }
        #expect(try harness.secrets.read("token") == nil)
        #expect(try PluginConfig.sections(in: harness.home.configFile)["tickets"] == nil)
    }

    @Test func aBadURLOrTemplateSavesNothing() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "good")
        for params in [
            TicketConnectParams(url: "http://tm.example.convex.site", token: "good"),
            TicketConnectParams(url: harness.url, token: "good", web: "https://tm.example.com/tickets"),
            TicketConnectParams(url: harness.url, token: "  "),
        ] {
            await #expect { try await harness.call(TicketMethod.connect, params) } throws: {
                ["invalid_url", "bad_params"].contains(($0 as? ControlError)?.code)
            }
        }
        #expect(try harness.secrets.read("token") == nil)
        #expect(await harness.transport.requests.isEmpty)
    }

    @Test func urlsMustBeHTTPSOrThisMac() throws {
        #expect(try TicketSettings.url("https://tm.convex.site/").absoluteString == "https://tm.convex.site")
        #expect(try TicketSettings.url(" https://tm.convex.site/api/v1/ ").absoluteString == "https://tm.convex.site")
        #expect(try TicketSettings.url("http://127.0.0.1:8123").absoluteString == "http://127.0.0.1:8123")
        #expect(try TicketSettings.url("http://localhost:8123/").absoluteString == "http://localhost:8123")
        for bad in ["http://tm.convex.site", "tm.convex.site", "ftp://tm.convex.site", "https://", "https://u:p@tm.x"] {
            #expect(throws: TicketError.self, "\(bad)") { try TicketSettings.url(bad) }
        }
        #expect(throws: TicketError.self) { try TicketSettings.web("https://tm.example.com/tickets") }
        #expect(throws: TicketError.self) { try TicketSettings.web("javascript:{id}") }
        let ticket = try APIFixture.decode(TicketList.self, "tickets-open").tickets[0]
        #expect(
            TicketSettings.webURL("https://tm.example.com/t/{id}", for: ticket)?.absoluteString
                == "https://tm.example.com/t/\(ticket.id)")
    }

    @Test func connectingAgainWithTheSameURLUsesTheNewTokenAtOnce() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "one")
        try await harness.connect(token: "one")
        await harness.transport.setToken("two")
        _ = try? await harness.call(TicketMethod.list, TicketListParams())
        #expect(await harness.section()?.warning?.contains("rejected the token") == true)

        try await harness.connect(token: "two")

        #expect(await harness.section()?.warning == nil)
        let entries = try await harness.call(TicketMethod.list, TicketListParams()).decode([TicketListEntry].self)
        #expect(entries.count == 3)
        #expect(await harness.transport.tokens.last == "two")
        #expect(try harness.secrets.read("token") == "two")
    }

    @Test func aRequestInFlightOnTheOldTokenCannotBringTheWarningBack() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "one")
        try await harness.connect(token: "one")
        let row = try await harness.newRow("853")
        await harness.settle()
        let key = "/api/v1/tickets?ids=\(row.item)"
        await harness.transport.stall(key)
        await harness.transport.setToken("two")
        harness.setViewing(visible: true, frontmost: false)
        #expect(await eventually { await harness.transport.stalledCount == 1 })

        try await harness.connect(token: "two")
        await harness.transport.release(key)
        await harness.settle()

        #expect(await harness.section()?.warning == nil)
        #expect(await harness.host.list().first { $0.id == "tickets" }?.status?.hasPrefix("connected as") == true)
    }

    @Test func aCancelledRequestIsNotAFailure() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await harness.connect(token: "t")
        await harness.transport.fail("/api/v1/tickets?status=open", URLError(.cancelled))
        _ = try? await harness.call(TicketMethod.list, TicketListParams())
        #expect(await harness.host.list().first { $0.id == "tickets" }?.status?.hasPrefix("connected as") == true)
    }

    @Test func offCommandsSayHowToConnect() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        await #expect { try await harness.call(TicketMethod.list, TicketListParams()) } throws: {
            let error = $0 as? ControlError
            return error?.code == "plugin_off" && error?.message.contains("canopy ticket connect <url>") == true
        }
        await #expect {
            try await harness.host.createRow("tickets", reference: "853", run: nil, select: false)
        } throws: {
            PluginHost.message($0).contains("canopy ticket connect <url>")
        }
    }

    @Test func noTokenMeansItCannotStartAndSaysSo() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(
            dir, config: #"{"plugins": {"tickets": {"url": "https://tm.example.convex.site"}}}"#, serverToken: "t")
        #expect(await harness.section()?.warning?.contains("No token is saved") == true)
        #expect(
            await harness.section()?.warning?.contains("canopy ticket connect https://tm.example.convex.site") == true)
        await #expect { try await harness.call(TicketMethod.list, TicketListParams()) } throws: {
            let error = $0 as? ControlError
            return error?.code == "plugin_not_started" && error?.message.contains("No token is saved") == true
        }
    }

    @Test func aKeychainThatRefusesFailsWithKeychainFailed() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(
            dir, config: #"{"plugins": {"tickets": {"url": "https://tm.example.convex.site"}}}"#, serverToken: "t",
            secretStore: RefusingSecretStore())
        #expect(await harness.section()?.warning?.contains("User interaction is not allowed.") == true)
        let keychainFailed: @Sendable (any Error) -> Bool = {
            let error = $0 as? ControlError
            return error?.code == "keychain_failed" && error?.message.contains("User interaction") == true
        }
        await #expect(
            performing: { try await harness.call(TicketMethod.list, TicketListParams()) }, throws: keychainFailed)
        // `row new --ticket`, `plugin items tickets`, and `plugin new tickets` reach the plugin through the host.
        await #expect(
            performing: { try await harness.host.resolveLink(plugin: "tickets", reference: "853") },
            throws: keychainFailed)
        await #expect(
            performing: { try await harness.host.items("tickets", matching: PluginQuery()) },
            throws: keychainFailed)
        await #expect(performing: { try await harness.newRow("853") }, throws: keychainFailed)
    }

    @Test func aPluginThatCouldNotStartStillShowsTheSavedTicketsAndSaysWhyForTheRest() async throws {
        let dir = try TempDir()
        let first = try await TicketsHarness(dir, serverToken: "t")
        try await first.connect(token: "t")
        let row = try await first.newRow("853")
        first.close()
        await first.host.stop()
        await first.workspace.stop()

        let harness = try await TicketsHarness(
            dir, serverToken: "t", transport: first.transport, secretStore: RefusingSecretStore())
        #expect(await harness.section()?.warning?.contains("User interaction is not allowed.") == true)
        #expect(await eventually { harness.store.ticket(row.item).detail?.ticket.name == "ticket-0853-sameergoyal" })
        #expect(!harness.store.isRunning)
        #expect(harness.store.ticket("no-copy").placeholder(rowIsMissing: false, isRunning: false) == .notRunning)
    }

    @Test func aStartWithoutAURLSaysHowToConnect() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, config: #"{"plugins": {"tickets": {}}}"#, serverToken: "t")
        #expect(await harness.section()?.warning?.contains("canopy ticket connect <url>") == true)
    }

    @Test func disconnectRefusesWhileProgramsRunAndDeletesNothing() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await harness.connect(token: "t")
        let row = try await harness.addRowByHand(item: "0000000000000000000010001tickets", title: "0853-sameergoyal")
        await harness.runBusyProgram(in: row)

        await #expect {
            try await harness.call(TicketMethod.disconnect, TicketDisconnectParams(force: false))
        } throws: {
            errorCode($0) == "plugin_busy"
        }
        #expect(try harness.secrets.read("token") == "t")
        #expect(await harness.host.list().first { $0.id == "tickets" }?.on == true)

        _ = try await harness.call(TicketMethod.disconnect, TicketDisconnectParams(force: true))
        #expect(try harness.secrets.read("token") == nil)
        #expect(harness.terminals.tabs(inRow: row.path).isEmpty)
        #expect(await harness.host.list().first { $0.id == "tickets" }?.on == false)
        #expect(harness.store.url == nil)

        try await harness.connect(token: "t")
        #expect(await harness.section()?.rows.map(\.path) == [row.path])
    }

    @Test func disconnectingWhileOffStillDeletesTheToken() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try harness.secrets.write("stale", for: "token")
        _ = try await harness.call(TicketMethod.disconnect, TicketDisconnectParams(force: false))
        #expect(try harness.secrets.read("token") == nil)
    }

    @Test func statusSaysWhoWhereAndWhen() async throws {
        let dir = try TempDir()
        let harness = try await TicketsHarness(dir, serverToken: "t")
        try await harness.connect(token: "t")
        _ = try await harness.call(TicketMethod.list, TicketListParams())
        await harness.settle()
        harness.clock.advance(by: .seconds(20))
        #expect(
            await harness.host.list().first { $0.id == "tickets" }?.status
                == "connected as hindie@example.com to \(harness.url), updated 20 s ago")

        await harness.transport.failEverything(URLError(.cannotConnectToHost))
        _ = try? await harness.call(TicketMethod.list, TicketListParams())
        let status = await harness.host.list().first { $0.id == "tickets" }?.status
        #expect(status?.hasPrefix("Could not reach ticket-manager at \(harness.url)") == true)
        #expect(status?.hasSuffix("Last updated 20 s ago.") == true)
    }
}
