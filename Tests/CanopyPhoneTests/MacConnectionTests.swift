import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

@MainActor
struct MacConnectionTests {
    let mac = FakeMac()
    let credentials = MemoryCredentialStore()
    let sleeper = ManualSleeper()

    func connection(timeout: Duration = .seconds(10)) -> MacConnection {
        MacConnection(
            transport: mac, credentials: credentials, phoneName: "iPhone", timeout: timeout, sleep: sleeper.sleep)
    }

    static let inbox = PhoneInbox(rows: [
        PhoneRow(
            path: "/demo", name: "main", repo: "demo", isMain: true,
            agents: [PhoneAgent(pane: "p1", state: .working, since: 1_000)])
    ])

    @Test func pairingSavesTheTokenSaysHelloAndSubscribes() async throws {
        mac.setInbox(Self.inbox)
        let connection = connection()
        #expect(connection.paired == nil)
        try await connection.pair(mac.link)
        let paired = try #require(connection.paired)
        #expect(paired.mac == "Studio")
        #expect(paired.phone == "iPhone")
        #expect(paired.host == FakeMac.host)
        #expect(paired.address == FakeMac.address)
        #expect(credentials.load() == paired)
        #expect(await eventually { connection.status == .connected })
        #expect(connection.inbox == Self.inbox)
        #expect(connection.inboxAsOf != nil)
        // One connection did all three, in order.
        #expect(mac.openLinks.count == 1)
        #expect(
            mac.openLinks.first?.requests.map(\.method) == [PhoneMethod.pair, PhoneMethod.hello, PhoneMethod.subscribe])
    }

    @Test func pairingTriesTheNameThenTheAddress() async throws {
        mac.state.withLock { $0.reachable = [FakeMac.address] }
        let connection = connection()
        try await connection.pair(mac.link)
        #expect(mac.connects == [FakeMac.host, FakeMac.address])
        #expect(connection.paired != nil)
    }

    @Test func aUsedCodeSaysSo() async throws {
        let connection = connection()
        try await connection.pair(mac.link)
        let second = MacConnection(
            transport: mac, credentials: MemoryCredentialStore(), phoneName: "iPad", sleep: sleeper.sleep)
        await #expect {
            try await second.pair(mac.link)
        } throws: { error in
            (error as? PhoneProblem)?.title == "That code expired or was already used."
        }
        #expect(second.paired == nil)
    }

    @Test func pairingWithAMacOutOfReachSaysWhatToCheck() async throws {
        mac.goAway()
        let connection = connection()
        await #expect {
            try await connection.pair(mac.link)
        } throws: { error in
            let problem = error as? PhoneProblem
            return problem?.title == "Can't reach \(FakeMac.host)."
                && problem?.detail.contains("Tailscale") == true
        }
        #expect(credentials.load() == nil)
    }

    @Test func aMacThatNeverAnswersTimesOut() async throws {
        mac.state.withLock { $0.hanging = [FakeMac.host, FakeMac.address] }
        let connection = connection(timeout: .milliseconds(100))
        await #expect {
            try await connection.pair(mac.link)
        } throws: { error in
            (error as? PhoneProblem)?.title == "Can't reach \(FakeMac.host)."
        }
    }

    @Test func aPairedPhoneSaysHelloWithItsTokenOnStart() async throws {
        try credentials.save(mac.paired())
        mac.setInbox(Self.inbox)
        let connection = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        let hello = try #require(await mac.request(PhoneMethod.hello))
        #expect(try hello.decodeParams(PhoneHelloParams.self).token == "token-iPhone")
        #expect(connection.inbox == Self.inbox)
        #expect(connection.generation == 1)
    }

    @Test func inboxEventsUpdateTheInbox() async throws {
        try credentials.save(mac.paired())
        let connection = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        let first = try #require(connection.inboxAsOf)
        mac.setInbox(Self.inbox)
        #expect(await eventually { connection.inbox == Self.inbox })
        #expect(try #require(connection.inboxAsOf) >= first)
    }

    @Test func aDropKeepsTheLastInboxAndRetriesWithBackoff() async throws {
        try credentials.save(mac.paired())
        mac.setInbox(Self.inbox)
        let connection = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        let asOf = connection.inboxAsOf
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        #expect(connection.inbox == Self.inbox)
        #expect(connection.inboxAsOf == asOf)
        for expected in [1, 2, 4, 8, 16, 30, 30] {
            #expect(await eventually { sleeper.sleeping == 1 })
            #expect(sleeper.durations.last == .seconds(expected))
            await sleeper.wake()
        }
        #expect(await eventually { sleeper.sleeping == 1 })
        mac.comeBack()
        await sleeper.wake()
        #expect(await eventually { connection.status == .connected })
        #expect(connection.generation == 2)
        // A good connection starts the backoff over.
        mac.goAway()
        #expect(await eventually { sleeper.sleeping == 1 })
        #expect(sleeper.durations.last == .seconds(1))
    }

    @Test func comingToTheForegroundRetriesAtOnce() async throws {
        try credentials.save(mac.paired())
        mac.goAway()
        let connection = connection()
        connection.start()
        #expect(await eventually { sleeper.sleeping == 1 })
        mac.comeBack()
        connection.foreground()
        #expect(await eventually { connection.status == .connected })
    }

    @Test func goingToTheBackgroundClosesTheConnectionAndStopsTrying() async throws {
        try credentials.save(mac.paired())
        let connection = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        connection.background()
        #expect(await eventually { mac.openLinks.isEmpty })
        let connects = mac.connects.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.connects.count == connects)
        #expect(sleeper.sleeping == 0)
        connection.foreground()
        #expect(await eventually { connection.status == .connected && mac.openLinks.count == 1 })
    }

    @Test func anUnpairedPhoneGoesBackToPairingAndStopsTrying() async throws {
        try credentials.save(mac.paired())
        let connection = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        mac.forget(phone: "iPhone")
        mac.dropAll()
        #expect(await eventually { connection.paired == nil })
        #expect(credentials.load() == nil)
        #expect(connection.pairingNotice == "Studio no longer knows this iPhone. Pair it again.")
        #expect(connection.inbox == nil)
        let connects = mac.connects.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.connects.count == connects)
        #expect(sleeper.sleeping == 0)
        connection.foreground()
        try await Task.sleep(for: .milliseconds(50))
        #expect(mac.connects.count == connects)
    }

    @Test func clientWaitsForTheNextConnection() async throws {
        try credentials.save(mac.paired())
        mac.goAway()
        let connection = connection()
        connection.start()
        let waiting = Task { try await connection.client() }
        #expect(await eventually { sleeper.sleeping == 1 })
        mac.comeBack()
        await sleeper.wake()
        let client = try await waiting.value
        #expect(await !client.isClosed)
    }

    @Test func aCancelledWaitForAClientEnds() async throws {
        try credentials.save(mac.paired())
        mac.goAway()
        let connection = connection()
        connection.start()
        let waiting = Task { try await connection.client() }
        #expect(await eventually { sleeper.sleeping == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func unpairingForgetsTheTokenAndCloses() async throws {
        try credentials.save(mac.paired())
        let connection = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        connection.unpair()
        #expect(connection.paired == nil)
        #expect(connection.inbox == nil)
        #expect(credentials.load() == nil)
        #expect(connection.pairingNotice == nil)
        #expect(await eventually { mac.openLinks.isEmpty })
    }
}
