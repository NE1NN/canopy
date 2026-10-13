import Foundation
import Testing

@testable import CanopyWire

struct PairingLinkTests {
    @Test func roundTripsThroughItsURL() throws {
        let link = PairingLink(host: "studio.tail1234.ts.net", port: 6974, code: "K7QX-M2PD", address: "100.101.5.9")
        #expect(
            link.url.absoluteString
                == "canopy-phone://pair?host=studio.tail1234.ts.net&port=6974&code=K7QX-M2PD&addr=100.101.5.9")
        #expect(PairingLink(url: link.url) == link)
    }

    @Test func aLinkCarriesItsKind() throws {
        let link = PairingLink(host: "hindie-box.tail1234.ts.net", port: 6974, code: "C", address: nil, kind: "box")

        #expect(link.url.absoluteString.contains("kind=box"))
        #expect(PairingLink(url: link.url) == link)
    }

    /// As a Mac from before several servers makes it.
    @Test func aLinkWithoutAKindSaysNone() throws {
        let url = try #require(URL(string: "canopy-phone://pair?host=studio&port=6974&code=C"))

        #expect(PairingLink(url: url)?.kind == nil)
    }

    @Test func keepsAnIPv6AddressWhole() throws {
        let link = PairingLink(host: "fd7a:115c:a1e0::1", port: 6974, code: "AAAA-BBBB", address: nil)
        #expect(PairingLink(url: link.url) == link)
        #expect(link.hosts == ["fd7a:115c:a1e0::1"])
    }

    @Test func triesTheNameThenTheAddress() {
        let link = PairingLink(host: "studio.tail1234.ts.net", port: 6974, code: "C", address: "100.101.5.9")
        #expect(link.hosts == ["studio.tail1234.ts.net", "100.101.5.9"])
        let same = PairingLink(host: "100.101.5.9", port: 6974, code: "C", address: "100.101.5.9")
        #expect(same.hosts == ["100.101.5.9"])
    }

    @Test(arguments: [
        "https://pair?host=a&port=1&code=c",
        "canopy-phone://unpair?host=a&port=1&code=c",
        "canopy-phone://pair?port=1&code=c",
        "canopy-phone://pair?host=a&code=c",
        "canopy-phone://pair?host=a&port=0&code=c",
        "canopy-phone://pair?host=a&port=70000&code=c",
        "canopy-phone://pair?host=a&port=1",
        "canopy-phone://pair?host=a&port=1&code=",
    ])
    func refusesWhatIsNotAPairingLink(_ text: String) throws {
        #expect(PairingLink(url: try #require(URL(string: text))) == nil)
    }
}

struct PhoneMessageTests {
    @Test func tellsEventsFromResponses() throws {
        let event = PhoneEvent(event: PhoneEvent.inbox, subscription: "7", data: .object([:]))
        let response = ControlResponse.success(id: "7", result: .object(["mac": "studio"]))
        #expect(try PhoneMessage(line: ControlCodec.encodeLine(event)) == .event(event))
        #expect(try PhoneMessage(line: ControlCodec.encodeLine(response)) == .response(response))
        #expect(throws: DecodingError.self) { try PhoneMessage(line: Data("{}".utf8)) }
    }
}

struct PhoneInboxTests {
    static func agent(_ pane: String, _ state: AgentState, unseen: Bool = false, since: Double) -> PhoneAgent {
        PhoneAgent(pane: pane, state: state, unseen: unseen, since: since)
    }

    static func row(_ name: String, main: Bool = false, _ agents: [PhoneAgent]) -> PhoneRow {
        PhoneRow(path: "/w/\(name)", name: name, repo: "canopy", isMain: main, agents: agents)
    }

    static let inbox = PhoneInbox(rows: [
        row("main", main: true, [agent("p1", .working, since: 100)]),
        row("ask", [agent("p2", .waiting, since: 50)]),
        row("ask-later", [agent("p3", .waiting, since: 90)]),
        row("ready", [agent("p4", .done, unseen: true, since: 80)]),
        row("seen", [agent("p5", .done, since: 85)]),
        row("tests", [agent("p6", .working, since: 70)]),
        row("server", [agent("p7", .background, since: 75)]),
        row("idle", []),
        row("split", [agent("p8", .none, since: 10), agent("p9", .waiting, since: 20)]),
    ])

    @Test func aRowShowsItsMostUrgentAgent() {
        #expect(Self.inbox.rows.last?.dot == .waiting)
        #expect(Self.inbox.rows.first { $0.name == "seen" }?.dot == nil)
        #expect(Self.inbox.rows.first { $0.name == "idle" }?.dot == nil)
        #expect(Self.inbox.rows.first { $0.name == "server" }?.lead?.pane == "p7")
    }

    @Test func aStateFromANewerMacReadsAsNone() throws {
        let json = #"{"pane":"p1","state":"thinking","unseen":false,"since":5}"#
        #expect(try JSONDecoder().decode(PhoneAgent.self, from: Data(json.utf8)).state == AgentState.none)
        let pr = #"{"number":1,"state":"queued","title":"t","url":"u"}"#
        #expect(try JSONDecoder().decode(PhonePR.self, from: Data(pr.utf8)).state == .open)
    }
}

struct PhoneRowsResultTests {
    static let main = PhoneRow(path: "/w/main", name: "main", repo: "canopy", isMain: true)
    static let feature = PhoneRow(path: "/w/feat", name: "feat/x", repo: "canopy")
    static let fix = PhoneRow(path: "/w/fix", name: "fix/y", repo: "canopy")

    @Test func aRepoShowsItsMainRowApart() {
        let section = PhoneRowsResult.Section(
            name: "canopy", isPlugin: false, rows: [Self.feature, Self.main, Self.fix])
        #expect(section.main == Self.main)
        #expect(section.others.map(\.name) == ["feat/x", "fix/y"])
    }

    @Test func aSectionWithoutAMainRowListsEveryRow() {
        let ticket = PhoneRow(path: "/t/1", name: "#0853", plugin: "ticket")
        let section = PhoneRowsResult.Section(name: "ticket", isPlugin: true, rows: [ticket])
        #expect(section.main == nil)
        #expect(section.others == [ticket])
    }
}

struct PhoneServerKindTests {
    @Test func anOldHelloWithoutAKindDecodes() throws {
        let data = Data(#"{"mac": "Studio", "version": "0.9", "phone": "iPhone"}"#.utf8)

        let hello = try JSONDecoder().decode(PhoneHelloResult.self, from: data)

        #expect(hello == PhoneHelloResult(mac: "Studio", version: "0.9", phone: "iPhone"))
        #expect(hello.kind == nil)
    }

    @Test func aRowWithoutAHostDecodes() throws {
        let data = Data(#"{"path": "/w", "name": "main", "isMain": true, "agents": []}"#.utf8)

        #expect(try JSONDecoder().decode(PhoneRow.self, from: data).host == nil)
    }
}
