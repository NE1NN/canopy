import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct PhoneListenerTests {
    final class Harness: Sendable {
        let registry: PhoneRegistry
        let listener: PhoneListener
        let addresses = Shared(["127.0.0.1"])
        let closedSessions = Shared<[String]>([])

        init(_ dir: TempDir, helloTimeout: Duration = .seconds(10), handler: PhoneHandler? = nil) {
            registry = PhoneRegistry(file: URL(fileURLWithPath: dir.sub("phones.json")))
            let addresses = self.addresses
            let closed = closedSessions
            let echo: PhoneHandler = { request, session in
                session.onClose { closed.withLock { $0.append(session.phone.name) } }
                return PhoneReply(.success(id: request.id, result: .object(["method": .string(request.method)])))
            }
            listener = PhoneListener(
                port: 0, addresses: { addresses.withLock { $0 } },
                gate: PhoneGate(
                    registry: registry, macName: "studio", helloTimeout: helloTimeout, handler: handler ?? echo))
        }

        var port: UInt16 {
            get throws { try #require(listener.endpoints.first?.port) }
        }

        func client() throws -> PhoneTestClient {
            try PhoneTestClient(port: try port)
        }

        /// A paired phone's token.
        func pair(_ name: String = "iPhone") async throws -> String {
            let code = await registry.newCode().code
            let client = try client()
            let response = try await offPool {
                try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: code, name: name)))
            }
            return try #require(response.result).decode(PhonePairResult.self).token
        }

        /// A connection that said hello.
        func authenticated(_ token: String) async throws -> PhoneTestClient {
            let client = try client()
            let response = try await offPool {
                try client.call(PhoneMethod.hello, try .from(PhoneHelloParams(token: token)))
            }
            #expect(response.error == nil)
            return client
        }
    }

    @Test func aPairedPhoneSaysHelloAndCallsPhoneMethods() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let code = await harness.registry.newCode().code
        let client = try harness.client()
        let paired = try await offPool {
            try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: code, name: "Hindie's iPhone")))
        }
        let result = try #require(paired.result).decode(PhonePairResult.self)
        #expect(result.phone == "Hindie's iPhone" && result.mac == "studio")

        let hello = try await offPool {
            try client.call(PhoneMethod.hello, try .from(PhoneHelloParams(token: result.token)))
        }
        let greeting = try #require(hello.result).decode(PhoneHelloResult.self)
        #expect(greeting == PhoneHelloResult(mac: "studio", version: CanopyVersion.current, phone: "Hindie's iPhone"))

        let rows = try await offPool { try client.call(PhoneMethod.rows) }
        #expect(rows.result == .object(["method": .string(PhoneMethod.rows)]))
    }

    @Test func aHelloAndARequestSentTogetherBothCount() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }
        let token = try await harness.pair()

        let client = try harness.client()
        var both = try ControlCodec.encodeLine(
            ControlRequest(method: PhoneMethod.hello, params: try .from(PhoneHelloParams(token: token)), id: "h"))
        both.append(try ControlCodec.encodeLine(ControlRequest(method: PhoneMethod.rows, id: "r")))
        try client.sendRaw(both)
        let first = try await offPool { try client.next() }?.response
        let second = try await offPool { try client.next() }?.response
        #expect(first?.id == "h" && first?.error == nil)
        #expect(second?.id == "r" && second?.error == nil)
    }

    @Test func methodsOffTheListAreRefusedAndTheConnectionStays() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }
        let client = try await harness.authenticated(try await harness.pair())

        for method in [ControlMethod.rowRemove, ControlMethod.repoRemove, "hooks.install", PhoneMethod.pair] {
            let refused = try await offPool { try client.call(method) }
            #expect(refused.error?.code == "method_not_allowed")
        }
        let rows = try await offPool { try client.call(PhoneMethod.rows) }
        #expect(rows.error == nil)
    }

    @Test func aWrongTokenIsUnpairedAndCloses() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }
        _ = try await harness.pair()

        let client = try harness.client()
        try client.send(PhoneMethod.hello, try .from(PhoneHelloParams(token: "not-a-token")))
        try client.send(PhoneMethod.rows)
        let messages = try await offPool { try client.untilClosed() }
        #expect(messages.compactMap(\.response?.error?.code) == ["unpaired"])
    }

    @Test(arguments: [PhoneMethod.rows, PhoneMethod.subscribe, ControlMethod.status])
    func anyOtherFirstMessageCloses(_ method: String) async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let client = try harness.client()
        try client.send(method)
        let messages = try await offPool { try client.untilClosed() }
        #expect(messages.compactMap(\.response?.error?.code) == ["not_authenticated"])
    }

    @Test func pairingAloneDoesNotLetAPhoneIn() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let code = await harness.registry.newCode().code
        let client = try harness.client()
        _ = try await offPool { try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: code, name: "a"))) }
        try client.send(PhoneMethod.rows)
        let messages = try await offPool { try client.untilClosed() }
        #expect(messages.compactMap(\.response?.error?.code) == ["not_authenticated"])
    }

    @Test func aBadPairingCodeCloses() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let client = try harness.client()
        try client.send(PhoneMethod.pair, try .from(PhonePairParams(code: "AAAA-AAAA", name: "a")))
        let messages = try await offPool { try client.untilClosed() }
        #expect(messages.compactMap(\.response?.error?.code) == ["bad_pairing_code"])
    }

    @Test func silenceClosesTheConnection() async throws {
        let dir = try TempDir()
        let harness = Harness(dir, helloTimeout: .milliseconds(300))
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let client = try harness.client()
        let started = ContinuousClock.now
        let messages = try await offPool { try client.untilClosed() }
        #expect(messages.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func helloInTimeKeepsTheConnectionOpen() async throws {
        let dir = try TempDir()
        let harness = Harness(dir, helloTimeout: .milliseconds(300))
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let client = try await harness.authenticated(try await harness.pair())
        try await Task.sleep(for: .milliseconds(600))
        let rows = try await offPool { try client.call(PhoneMethod.rows) }
        #expect(rows.error == nil)
    }

    @Test func notJSONCloses() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let client = try harness.client()
        try client.sendRaw(Data("hello\n".utf8))
        let messages = try await offPool { try client.untilClosed() }
        #expect(messages.compactMap(\.response?.error?.code) == ["bad_request"])
    }

    @Test func aHugeLineCloses() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }

        let client = try await harness.authenticated(try await harness.pair())
        let huge = Data(repeating: 0x61, count: LineBuffer.maximumLine + 1)
        try? client.sendRaw(huge)
        let messages = try await offPool { try client.untilClosed() }
        #expect(messages.compactMap(\.response?.error?.code) == ["bad_request"])
    }

    @Test func removingAPhoneClosesItsConnectionsAtOnce() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }
        let token = try await harness.pair("a")
        let other = try await harness.authenticated(try await harness.pair("b"))
        let client = try await harness.authenticated(token)
        _ = try await offPool { try client.call(PhoneMethod.subscribe) }
        _ = try await offPool { try other.call(PhoneMethod.subscribe) }

        let removed = try await harness.registry.remove(name: "a")
        harness.listener.disconnect(phoneID: removed.id)
        #expect(try await offPool { try client.untilClosed() }.isEmpty)
        #expect(await eventually { harness.closedSessions.withLock { $0 } == ["a"] })
        #expect(try await offPool { try other.call(PhoneMethod.rows) }.error == nil)

        let again = try harness.client()
        try again.send(PhoneMethod.hello, try .from(PhoneHelloParams(token: token)))
        #expect(try await offPool { try again.untilClosed() }.compactMap(\.response?.error?.code) == ["unpaired"])
    }

    @Test func eventsComeAfterTheAnswerThatStartedThem() async throws {
        let dir = try TempDir()
        let handler: PhoneHandler = { request, session in
            PhoneReply(.success(id: request.id, result: "first")) {
                session.send(PhoneEvent(event: PhoneEvent.inbox, subscription: request.id, data: "second"))
            }
        }
        let harness = Harness(dir, handler: handler)
        try await harness.listener.refresh()
        defer { harness.listener.stop() }
        let client = try await harness.authenticated(try await harness.pair())

        try client.send(PhoneMethod.subscribe, id: "s1")
        let first = try await offPool { try client.next() }
        let second = try await offPool { try client.next() }
        #expect(first?.response?.result == "first")
        #expect(second?.event?.data == "second" && second?.event?.subscription == "s1")
    }

    @Test func listensOnlyWhileItHasAnAddress() async throws {
        let dir = try TempDir()
        let harness = Harness(dir)
        harness.addresses.withLock { $0 = [] }
        try await harness.listener.refresh()
        defer { harness.listener.stop() }
        #expect(harness.listener.endpoints.isEmpty)

        harness.addresses.withLock { $0 = ["127.0.0.1"] }
        try await harness.listener.refresh()
        let port = try harness.port
        let token = try await harness.pair()
        let client = try await harness.authenticated(token)

        harness.addresses.withLock { $0 = [] }
        try await harness.listener.refresh()
        #expect(harness.listener.endpoints.isEmpty)
        #expect(try await offPool { try client.untilClosed() }.isEmpty)
        #expect(throws: (any Error).self) { try PhoneTestClient(port: port) }
    }
}

struct TailscaleAddressTests {
    @Test func keepsOnlyTailscaleAddressesOnTunnels() {
        let interfaces = [
            NetworkInterfaceAddress(interface: "en0", address: "192.168.1.20"),
            NetworkInterfaceAddress(interface: "en0", address: "100.64.0.9"),
            NetworkInterfaceAddress(interface: "utun4", address: "100.101.5.9"),
            NetworkInterfaceAddress(interface: "utun4", address: "fd7a:115c:a1e0::5a01:509"),
            NetworkInterfaceAddress(interface: "utun4", address: "fe80::1"),
            NetworkInterfaceAddress(interface: "utun2", address: "100.128.0.1"),
            NetworkInterfaceAddress(interface: "utun2", address: "100.63.255.255"),
            NetworkInterfaceAddress(interface: "utun3", address: "fd7a:115c:a1e1::1"),
            NetworkInterfaceAddress(interface: "lo0", address: "127.0.0.1"),
        ]
        #expect(TailscaleAddresses.select(interfaces) == ["100.101.5.9", "fd7a:115c:a1e0::5a01:509"])
    }

    @Test func readsThisMacsInterfaces() {
        #expect(NetworkInterfaceAddress.current().contains { $0.interface == "lo0" && $0.address == "127.0.0.1" })
    }
}

struct PhoneListenAddressTests {
    @Test func listensOnTailscaleByDefault() {
        let resolved = PhoneListenAddress.resolve(environment: [:], allowsOverride: true)
        #expect(resolved == PhoneListenAddress(override: nil, port: PhonePort.standard, ignoredOverride: nil))
    }

    @Test func aDevBuildTakesAnAddressFromTheEnvironment() {
        let resolved = PhoneListenAddress.resolve(
            environment: ["CANOPY_PHONE_LISTEN": "127.0.0.1:7123"], allowsOverride: true)
        #expect(resolved == PhoneListenAddress(override: "127.0.0.1", port: 7123, ignoredOverride: nil))
        let v6 = PhoneListenAddress.resolve(environment: ["CANOPY_PHONE_LISTEN": "[::1]:7123"], allowsOverride: true)
        #expect(v6.override == "::1" && v6.port == 7123)
    }

    @Test func aReleaseBuildIgnoresIt() {
        let resolved = PhoneListenAddress.resolve(
            environment: ["CANOPY_PHONE_LISTEN": "0.0.0.0:6974"], allowsOverride: false)
        #expect(
            resolved == PhoneListenAddress(override: nil, port: PhonePort.standard, ignoredOverride: "0.0.0.0:6974"))
    }

    @Test(arguments: ["127.0.0.1", "127.0.0.1:", ":7123", "127.0.0.1:99999", "localhost:7123"])
    func aMalformedOverrideIsIgnored(_ text: String) {
        let resolved = PhoneListenAddress.resolve(environment: ["CANOPY_PHONE_LISTEN": text], allowsOverride: true)
        #expect(resolved.override == nil && resolved.ignoredOverride == text)
    }
}
