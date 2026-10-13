import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct PhoneServiceTests {
    @MainActor
    final class Harness {
        let home: CanopyHome
        let terminals: TerminalStore
        let activity: ActivityLog
        let service: PhoneService
        let row: Row
        let addresses: Shared<[String]>
        let panes: PhonePanes

        init(
            _ dir: TempDir,
            listen: PhoneListenAddress = .address("127.0.0.1", port: 0),
            tailscale: [String] = []
        ) throws {
            home = CanopyHome(path: dir.sub("home"))
            try home.ensureExists()
            row = Row(repoPath: dir.sub("r"), path: dir.sub("r"), branch: "main", head: nil, rowClass: .main)
            try FileManager.default.createDirectory(atPath: row.path, withIntermediateDirectories: true)
            terminals = Fixture.terminals(dir)
            activity = ActivityLog(folder: home.activityFolder, logsCommands: true)
            let hub = PhoneHub(
                terminals: terminals,
                snapshot: WorkspaceSnapshot(repos: [RepoSnapshot(path: row.path, name: "r", rows: [row])]),
                updates: AsyncStream { _ in }, coalescing: .milliseconds(20))
            let addresses = Shared(tailscale)
            self.addresses = addresses
            panes = PhonePanes(terminals: terminals)
            panes.start()
            service = PhoneService(
                home: home, hub: hub, panes: panes, activity: activity, listen: listen, macName: "studio",
                tailscaleAddresses: { addresses.withLock { $0 } }, dnsName: { "studio.tail1234.ts.net" })
        }

        func start() async {
            await service.start()
        }

        func close() {
            service.stop()
            panes.stop()
            terminals.closeAll()
            activity.flushNow()
        }

        /// Pairs a phone through the listener, and returns its open, authenticated connection.
        func pairedClient(_ name: String = "iPhone") async throws -> PhoneTestClient {
            let pairing = try await service.pair()
            let link = try #require(URL(string: pairing.link).flatMap(PairingLink.init(url:)))
            let client = try PhoneTestClient(host: link.host, port: link.port)
            let paired = try await offPool {
                try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: link.code, name: name)))
            }
            let token = try #require(paired.result).decode(PhonePairResult.self).token
            let hello = try await offPool {
                try client.call(PhoneMethod.hello, try .from(PhoneHelloParams(token: token)))
            }
            #expect(hello.error == nil)
            return client
        }

        func events(_ type: String) throws -> [ActivityEvent] {
            activity.flushNow()
            return ActivityReader.events(in: home.activityFolder, since: .distantPast, until: nil, types: [type])
        }
    }

    @Test func pairsAPhoneThatThenSubscribes() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        await harness.start()
        defer { harness.close() }
        let pane = harness.terminals.openTab(for: PaneContext(row: harness.row, repoName: "r")).pane

        let client = try await harness.pairedClient()
        let subscribed = try await offPool { try client.call(PhoneMethod.subscribe) }
        let inbox = try #require(subscribed.result).decode(PhoneInbox.self)
        #expect(inbox.rows.map(\.name) == ["main"])
        #expect(inbox.rows[0].agents.isEmpty)

        pane.report(AgentReport(state: .waiting))
        let event = try await offPool { try client.next() }?.event
        #expect(event?.event == PhoneEvent.inbox && event?.subscription == subscribed.id)
        let changed = try #require(event).data.decode(PhoneInbox.self)
        #expect(changed.rows[0].agents.map(\.state) == [.waiting])

        let rows = try await offPool { try client.call(PhoneMethod.rows) }
        #expect(try #require(rows.result).decode(PhoneRowsResult.self).sections.map(\.name) == ["r"])
    }

    @Test func aSecondSubscribeReplacesTheFirst() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        await harness.start()
        defer { harness.close() }
        let pane = harness.terminals.openTab(for: PaneContext(row: harness.row, repoName: "r")).pane
        let client = try await harness.pairedClient()
        _ = try await offPool { try client.call(PhoneMethod.subscribe) }
        let second = try await offPool { try client.call(PhoneMethod.subscribe) }

        pane.report(AgentReport(state: .working))
        let event = try await offPool { try client.next() }?.event
        #expect(event?.subscription == second.id)
        #expect(try await offPool { try client.isQuiet(for: .milliseconds(300)) })
    }

    @Test func listsAndRemovesPhones() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        await harness.start()
        defer { harness.close() }
        let client = try await harness.pairedClient("Hindie's iPhone")

        let listed = await harness.service.list()
        #expect(listed.map(\.name) == ["Hindie's iPhone"])
        #expect(listed[0].connected && listed[0].lastConnected != nil)

        let removed = try await harness.service.remove(name: "Hindie's iPhone")
        #expect(removed.name == "Hindie's iPhone")
        #expect(try await offPool { try client.untilClosed() }.isEmpty)
        #expect(await harness.service.list().isEmpty)
        #expect(try harness.events(ActivityType.phonePaired).map(\.data) == [["phone": "Hindie's iPhone"]])
        #expect(try harness.events(ActivityType.phoneRemoved).map(\.data) == [["phone": "Hindie's iPhone"]])
    }

    @Test func waitsForTheCodeToPair() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        await harness.start()
        defer { harness.close() }
        let pairing = try await harness.service.pair()
        async let paired = harness.service.waitForPairing(code: pairing.code)
        let link = try #require(URL(string: pairing.link).flatMap(PairingLink.init(url:)))
        let client = try PhoneTestClient(host: link.host, port: link.port)
        _ = try await offPool {
            try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: link.code, name: "a")))
        }
        #expect(await paired?.name == "a")
    }

    @Test func statusSaysWhereItListens() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir)
        await harness.start()
        defer { harness.close() }
        let status = await harness.service.status()
        #expect(status.listening)
        #expect(status.endpoints.map(\.address) == ["127.0.0.1"])
        #expect(status.problem == nil)
        #expect(status.notifications == PhonesStatusResult.noPushKey)
    }

    @Test func listensOnTailscaleAndLinksItsName() async throws {
        let dir = try TempDir()
        // Loopback stands in for the Tailscale address, which this Mac may not have.
        let harness = try Harness(
            dir, listen: .tailscale(port: 0, ignored: nil), tailscale: ["127.0.0.1"])
        await harness.start()
        defer { harness.close() }
        let pairing = try await harness.service.pair()
        let link = try #require(URL(string: pairing.link).flatMap(PairingLink.init(url:)))
        #expect(link.host == "studio.tail1234.ts.net")
        #expect(link.address == "127.0.0.1")
        let status = await harness.service.status()
        #expect(link.port == status.endpoints.first?.port)
    }

    @Test func withoutTailscaleItStaysClosedAndSaysWhy() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir, listen: .tailscale(port: 0, ignored: nil))
        await harness.start()
        defer { harness.close() }
        let status = await harness.service.status()
        #expect(!status.listening)
        #expect(status.problem?.contains("Tailscale") == true)
        await #expect(throws: ControlError.self) { try await harness.service.pair() }
        do {
            _ = try await harness.service.pair()
        } catch let error as ControlError {
            #expect(error.code == "phone_listener_closed")
        }

        harness.addresses.withLock { $0 = ["127.0.0.1"] }
        await harness.service.refresh()
        #expect(await harness.service.status().listening)
    }

    @Test func aReleaseBuildSaysItIgnoredTheOverride() async throws {
        let dir = try TempDir()
        let harness = try Harness(
            dir, listen: .tailscale(port: 0, ignored: "127.0.0.1:7000"))
        await harness.start()
        defer { harness.close() }
        let status = await harness.service.status()
        #expect(status.problem?.contains("CANOPY_PHONE_LISTEN=127.0.0.1:7000 is ignored") == true)
    }

    @Test func aDevBuildWithoutAnOverrideSaysHowToOpenIt() async throws {
        let dir = try TempDir()
        let harness = try Harness(dir, listen: .closed(malformed: nil), tailscale: ["127.0.0.1"])
        await harness.start()
        defer { harness.close() }
        let status = await harness.service.status()
        #expect(!status.listening)
        #expect(status.problem?.contains("only where CANOPY_PHONE_LISTEN says") == true)
        let malformed = try Harness(dir, listen: .closed(malformed: "nope"))
        await malformed.start()
        defer { malformed.close() }
        #expect(
            await malformed.service.status().problem?.contains("CANOPY_PHONE_LISTEN=nope is not an address") == true)
    }
}

struct TailscaleStatusTests {
    @Test func readsTheMagicDNSName() throws {
        let json = #"{"Version":"1.76.1","Self":{"DNSName":"studio.tail1234.ts.net.","TailscaleIPs":["100.101.5.9"]}}"#
        #expect(TailscaleStatus.dnsName(fromStatusJSON: Data(json.utf8)) == "studio.tail1234.ts.net")
    }

    @Test(arguments: [#"{"Self":{"DNSName":""}}"#, #"{"Self":{}}"#, "{}", "not json"])
    func hasNoNameWithoutOne(_ json: String) {
        #expect(TailscaleStatus.dnsName(fromStatusJSON: Data(json.utf8)) == nil)
    }
}
