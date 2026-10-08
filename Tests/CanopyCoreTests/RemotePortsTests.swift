import Foundation
import Testing

@testable import CanopyCore

struct RemotePortAttributionTests {
    static func row(_ path: String, _ standIn: String) -> RemoteRowEntry {
        RemoteRowEntry(host: "box", path: path, standIn: standIn, branch: nil, head: nil)
    }

    static func port(_ number: UInt16, _ processes: RemoteProcess...) -> RemoteListeningPort {
        RemoteListeningPort(port: number, address: "127.0.0.1", processes: processes)
    }

    static func process(_ pid: Int32, ancestors: [Int32] = [1], folder: String? = nil) -> RemoteProcess {
        RemoteProcess(pid: pid, name: "node", ancestors: ancestors, folder: folder)
    }

    let rows = [row("/h/app", "/s/app"), row("/h/app/sub", "/s/sub"), row("/h/app-web", "/s/web")]
    let sessions = ["s-app": "/s/app", "s-web": "/s/web"]
    let shells: [String: Int32] = ["s-app": 100, "s-web": 200]

    func assign(_ ports: RemoteListeningPort...) -> [String: [RemoteListeningPort]] {
        RemotePortAttribution.assign(ports, rows: rows, sessions: sessions, shells: shells)
    }

    @Test func aProcessStartedInASessionBelongsToItsRowWhereverItWorks() {
        let server = Self.port(5173, Self.process(812, ancestors: [810, 200, 1], folder: "/h/app/sub"))

        #expect(assign(server) == ["/s/web": [server]])
    }

    @Test func theNearestSessionShellWins() {
        let server = Self.port(5173, Self.process(812, ancestors: [100, 200, 1]))

        #expect(assign(server) == ["/s/app": [server]])
    }

    @Test func aProcessOfNoSessionBelongsToTheDeepestRowHoldingItsFolder() {
        let nested = Self.port(3000, Self.process(30, folder: "/h/app/sub/src"))
        let root = Self.port(3001, Self.process(31, folder: "/h/app"))

        #expect(assign(nested, root) == ["/s/sub": [nested], "/s/app": [root]])
    }

    @Test func aSiblingWithASharedPrefixIsNotInsideTheRow() {
        let web = Self.port(4000, Self.process(40, folder: "/h/app-web/src"))
        let stranger = Self.port(4001, Self.process(41, folder: "/h/app-webby"))
        let climbing = Self.port(4002, Self.process(42, folder: "/h/app/../elsewhere"))

        #expect(assign(web, stranger, climbing) == ["/s/web": [web]])
    }

    @Test func aPortInNoRowIsLeftOut() {
        let lost = Self.port(9000, Self.process(90, ancestors: [1], folder: "/srv/other"), Self.process(91))

        #expect(assign(lost).isEmpty)
    }

    @Test func aPortSharedByTwoRowsGoesToItsFirstProcesssRow() {
        let shared = Self.port(
            5000, Self.process(50, ancestors: [200, 1]), Self.process(51, ancestors: [100, 1]))

        #expect(assign(shared) == ["/s/web": [shared]])
    }

    @Test func aRowsPortsAreInOrder() {
        let high = Self.port(8080, Self.process(80, ancestors: [100]))
        let low = Self.port(3000, Self.process(30, ancestors: [100]))

        #expect(assign(high, low) == ["/s/app": [low, high]])
    }

    @Test func aSessionOfAnotherRowIsNotOneOfThese() {
        let server = Self.port(5173, Self.process(812, ancestors: [300, 1]))

        let assigned = RemotePortAttribution.assign(
            [server], rows: rows, sessions: ["s-gone": "/s/gone"], shells: ["s-gone": 300])

        #expect(assigned.isEmpty)
    }
}

struct LocalPortChooserTests {
    @Test func theSamePortWhenItIsFree() {
        #expect(LocalPortChooser.port(for: 5173, taken: [], isFree: { _ in true }) == 5173)
    }

    @Test func takenAndBusyPortsAreSkipped() {
        let port = LocalPortChooser.port(for: 5173, taken: [5173, 5175], isFree: { $0 != 5174 })

        #expect(port == 5176)
    }

    @Test func nothingPastTheLastPort() {
        #expect(LocalPortChooser.port(for: 65534, taken: [65535], isFree: { $0 != 65534 }) == nil)
        #expect(LocalPortChooser.port(for: 65535, taken: [], isFree: { _ in true }) == 65535)
    }

    /// `ssh -O forward -L` succeeds on one family alone, so a server on the other would catch some of `localhost`.
    @Test func aPortHeldOnEitherLoopbackIsNotFree() throws {
        let v4 = try Listener(family: AF_INET)
        let v6 = try Listener(family: AF_INET6)

        #expect(!LocalPortChooser.isFree(v4.port))
        #expect(!LocalPortChooser.isFree(v6.port))
    }

    @Test func aPortNobodyHoldsIsFree() throws {
        var listener: Listener? = try Listener(family: AF_INET)
        let port = try #require(listener?.port)
        listener = nil

        #expect(LocalPortChooser.isFree(port))
    }
}

struct RemotePortTargetTests {
    func target(_ address: String) -> String {
        RemoteListeningPort(port: 5173, address: address, processes: []).target
    }

    @Test func loopbackAndWildcardsReachTheServerOnLoopback() {
        #expect(target("0.0.0.0") == "127.0.0.1")
        #expect(target("127.0.0.1") == "127.0.0.1")
        #expect(target("::") == "[::1]")
        #expect(target("::1") == "[::1]")
    }

    @Test func anotherAddressIsUsedAsItIs() {
        #expect(target("10.0.0.5") == "10.0.0.5")
        #expect(target("fd00::5") == "[fd00::5]")
    }
}
