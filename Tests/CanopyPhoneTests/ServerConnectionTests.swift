import CanopyWire
import Foundation
import Security
import Synchronization
import Testing

@testable import CanopyPhone

@MainActor
struct ServerConnectionTests {
    let mac = FakeMac()
    let sleeper = ManualSleeper()

    func connection() -> (ServerConnection, MemoryCredentialStore) {
        let paired = mac.paired()
        let credentials = MemoryCredentialStore(paired)
        return (
            ServerConnection(server: paired, transport: mac, credentials: credentials, sleep: sleeper.sleep),
            credentials
        )
    }

    static let inbox = PhoneInbox(rows: [
        PhoneRow(
            path: "/demo", name: "main", repo: "demo", isMain: true,
            agents: [PhoneAgent(pane: "p1", state: .working, since: 1_000)])
    ])

    @Test func aPairedPhoneSaysHelloWithItsTokenOnStart() async throws {
        mac.setInbox(Self.inbox)
        let (connection, _) = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        let hello = try #require(await mac.request(PhoneMethod.hello))
        #expect(try hello.decodeParams(PhoneHelloParams.self).token == "token-iPhone")
        #expect(connection.inbox == Self.inbox)
        #expect(connection.generation == 1)
    }

    /// A server renamed, updated, or upgraded to canopy-box says so in hello, and the phone keeps what it says.
    @Test func helloUpdatesTheKindAndName() async throws {
        let box = FakeMac.box()
        var stale = box.paired()
        stale.name = "old-name"
        stale.kind = PhoneServerKind.mac
        stale.version = nil
        let credentials = MemoryCredentialStore(stale)
        let connection = ServerConnection(server: stale, transport: box, credentials: credentials, sleep: sleeper.sleep)
        connection.start()
        #expect(await eventually { connection.status == .connected })

        #expect(connection.name == "hindie-box" && connection.isBox && connection.server.version == "0.9")
        #expect(credentials.loadAll() == [connection.server])
    }

    @Test func inboxEventsUpdateTheInbox() async throws {
        let (connection, _) = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        let first = try #require(connection.inboxAsOf)
        mac.setInbox(Self.inbox)
        #expect(await eventually { connection.inbox == Self.inbox })
        #expect(try #require(connection.inboxAsOf) >= first)
    }

    @Test func aDropKeepsTheLastInboxAndRetriesWithBackoff() async throws {
        mac.setInbox(Self.inbox)
        let (connection, _) = connection()
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
        mac.goAway()
        let (connection, _) = connection()
        connection.start()
        #expect(await eventually { sleeper.sleeping == 1 })
        mac.comeBack()
        connection.foreground()
        #expect(await eventually { connection.status == .connected })
    }

    @Test func goingToTheBackgroundClosesTheConnectionAndStopsTrying() async throws {
        let (connection, _) = connection()
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

    /// A server that forgot the phone shows as unpaired, keeps its place until it is removed, and is tried no more.
    @Test func anUnpairedServerStopsTrying() async throws {
        let (connection, credentials) = connection()
        connection.start()
        #expect(await eventually { connection.status == .connected })
        mac.forget(phone: "iPhone")
        mac.dropAll()
        #expect(await eventually { !connection.isPaired })
        #expect(connection.status == .unpaired("Studio no longer knows this iPhone. Pair it again."))
        #expect(credentials.loadAll().map(\.id) == [connection.id])
        #expect(connection.inbox == nil)
        let connects = mac.connects.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.connects.count == connects)
        #expect(sleeper.sleeping == 0)
        connection.foreground()
        try await Task.sleep(for: .milliseconds(50))
        #expect(mac.connects.count == connects)
        #expect(throws: PhoneProblem.self) { try connection.liveClient() }
    }

    @Test func clientWaitsForTheNextConnection() async throws {
        mac.goAway()
        let (connection, _) = connection()
        connection.start()
        let waiting = Task { try await connection.client() }
        #expect(await eventually { sleeper.sleeping == 1 })
        mac.comeBack()
        await sleeper.wake()
        let client = try await waiting.value
        #expect(await !client.isClosed)
    }

    @Test func aCancelledWaitForAClientEnds() async throws {
        mac.goAway()
        let (connection, _) = connection()
        connection.start()
        let waiting = Task { try await connection.client() }
        #expect(await eventually { sleeper.sleeping == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func waitingForAClientEndsWhenTheServerForgetsThePhone() async throws {
        let connection = try await connected(to: mac)
        let waiting = Task { try await connection.client(after: connection.generation) }
        try await Task.sleep(for: .milliseconds(20))
        mac.forget(phone: "iPhone")
        mac.dropAll()
        await #expect(throws: ServerConnection.NotPaired.self) { try await waiting.value }
        await #expect(throws: ServerConnection.NotPaired.self) { try await connection.client() }
    }
}

@MainActor
struct ServersTests {
    let mac = FakeMac()
    let box = FakeMac.box()
    let sleeper = ManualSleeper()

    func servers(
        _ credentials: any CredentialStore = MemoryCredentialStore(), timeout: Duration = .seconds(10),
        phoneName: String = "iPhone", now: @escaping @Sendable () -> Date = Date.init
    ) -> Servers {
        Servers(
            transport: FakeNetwork(mac, box), credentials: credentials, phoneName: phoneName, timeout: timeout,
            sleep: sleeper.sleep, now: now)
    }

    @Test func pairingSavesTheTokenSaysHelloAndSubscribes() async throws {
        mac.setInbox(ServerConnectionTests.inbox)
        let credentials = MemoryCredentialStore()
        let servers = servers(credentials)
        #expect(!servers.isPaired)
        let connection = try await servers.pair(mac.link)
        let paired = connection.server
        #expect(paired.name == "Studio" && paired.kind == PhoneServerKind.mac)
        #expect(paired.phone == "iPhone")
        #expect(paired.host == FakeMac.host)
        #expect(paired.address == FakeMac.address)
        #expect(credentials.loadAll() == [paired])
        #expect(await eventually { connection.status == .connected })
        #expect(connection.inbox == ServerConnectionTests.inbox)
        #expect(connection.inboxAsOf != nil)
        // One connection did all three, in order.
        #expect(mac.openLinks.count == 1)
        #expect(
            mac.openLinks.first?.requests.map(\.method) == [PhoneMethod.pair, PhoneMethod.hello, PhoneMethod.subscribe])
    }

    @Test func pairingTriesTheNameThenTheAddress() async throws {
        mac.state.withLock { $0.reachable = [FakeMac.address] }
        let servers = servers()
        try await servers.pair(mac.link)
        #expect(mac.connects == [FakeMac.host, FakeMac.address])
        #expect(servers.isPaired)
    }

    @Test func aUsedCodeSaysSo() async throws {
        try await servers().pair(mac.link)
        let second = servers(phoneName: "iPad")
        await #expect {
            try await second.pair(mac.link)
        } throws: { error in
            (error as? PhoneProblem)?.title == "That code expired or was already used."
        }
        #expect(!second.isPaired)
    }

    @Test func pairingWithAServerOutOfReachSaysWhatToCheck() async throws {
        mac.goAway()
        let credentials = MemoryCredentialStore()
        await #expect {
            try await servers(credentials).pair(mac.link)
        } throws: { error in
            let problem = error as? PhoneProblem
            return problem?.title == "Can't reach \(FakeMac.host)."
                && problem?.detail.contains("Tailscale") == true
        }
        #expect(credentials.loadAll().isEmpty)
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        mac.state.withLock { $0.hanging = [FakeMac.host, FakeMac.address] }
        await #expect {
            try await servers(timeout: .milliseconds(100)).pair(mac.link)
        } throws: { error in
            (error as? PhoneProblem)?.title == "Can't reach \(FakeMac.host)."
        }
    }

    @Test func pairingAnotherServerAddsIt() async throws {
        let credentials = MemoryCredentialStore()
        let servers = servers(credentials)
        let first = try await servers.pair(mac.link)
        let second = try await servers.pair(box.link)

        #expect(servers.connections.map(\.id) == [first.id, second.id])
        #expect(second.isBox && second.name == "hindie-box")
        #expect(await eventually { servers.connections.allSatisfy(\.isConnected) })
        #expect(first.inbox != nil && mac.openLinks.count == 1 && box.openLinks.count == 1)
        #expect(credentials.loadAll().map(\.id) == [first.id, second.id])
    }

    /// A new code from the same server pairs it again in its place, keeping its spot and its connection object.
    @Test func pairingTheSameServerAgainReplacesIt() async throws {
        let servers = servers()
        let first = try await servers.pair(mac.link)
        try await servers.pair(box.link)
        #expect(await eventually { first.isConnected })

        let again = try await servers.pair(mac.newCode("NEW1-CODE"))

        #expect(again === first)
        #expect(servers.connections.map(\.name) == ["Studio", "hindie-box"])
        #expect(await eventually { first.isConnected && first.server.token == "token-2" })
        #expect(await eventually { mac.openLinks.count == 1 })
    }

    @Test func aFailedPairingWhilePairedKeepsTheConnection() async throws {
        let servers = try await CanopyPhoneTests.servers(mac)
        let link = PairingLink(
            host: FakeMac.host, port: PhonePort.standard, code: "USED-CODE", address: FakeMac.address)
        await #expect(throws: PhoneProblem.self) { try await servers.pair(link) }
        let connection = try #require(servers.connections.first)
        #expect(connection.status == .connected)
        #expect(connection.server.token == "token-iPhone")
        #expect(mac.openLinks.count == 1)
    }

    @Test func pairingAgainReplacesTheConnectionWithOneLoopOnly() async throws {
        let servers = try await CanopyPhoneTests.servers(mac)
        let connection = try #require(servers.connections.first)
        // The scene comes back while the pairing waits, which must not start a second loop.
        servers.foreground()
        try await servers.pair(mac.link)
        #expect(await eventually { connection.status == .connected && connection.server.token != "token-iPhone" })
        #expect(await eventually { mac.openLinks.count == 1 })
        mac.dropAll()
        #expect(await eventually { mac.openLinks.count == 1 && connection.status == .connected })
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.openLinks.count == 1)
    }

    @Test func aPairingTheKeychainCannotKeepSaysSoAndTriesNoOtherHost() async throws {
        let servers = servers(FailingCredentialStore())
        await #expect {
            try await servers.pair(mac.link)
        } throws: { error in
            (error as? PhoneProblem)?.title == "This iPhone could not keep its pairing."
        }
        #expect(mac.requests.filter { $0.method == PhoneMethod.pair }.count == 1)
        #expect(!servers.isPaired)
    }

    @Test func serversComeBackInPairingOrder() async throws {
        let credentials = MemoryCredentialStore(box.paired(at: 20), mac.paired(at: 10))

        #expect(servers(credentials).connections.map(\.name) == ["Studio", "hindie-box"])
    }

    /// The box forgetting the phone leaves the Mac as it was, and the app stays out of Pairing.
    @Test func anUnpairedServerKeepsTheOthers() async throws {
        let servers = try await CanopyPhoneTests.servers(mac, box)
        box.forget(phone: "iPhone")
        box.dropAll()

        #expect(await eventually { servers.paired.map(\.name) == ["Studio"] })
        #expect(servers.connections.count == 2)
        #expect(servers.isPaired && servers.pairingNotice == nil)
        #expect(servers.connections.first?.isConnected == true)

        mac.forget(phone: "iPhone")
        mac.dropAll()
        #expect(await eventually { !servers.isPaired })
        #expect(servers.pairingNotice == "Studio and hindie-box no longer know this iPhone. Pair them again.")
    }

    /// A server that forgot the phone stays forgotten after a relaunch, rather than counting as paired again.
    @Test func aForgottenServerStaysForgottenAfterARelaunch() async throws {
        let credentials = MemoryCredentialStore(mac.paired(at: 0), box.paired(at: 1))
        let before = servers(credentials)
        before.start()
        #expect(await eventually { before.connections.allSatisfy(\.isConnected) })
        box.forget(phone: "iPhone")
        box.dropAll()
        #expect(await eventually { before.paired.map(\.name) == ["Studio"] })
        before.background()

        let after = servers(credentials)

        #expect(after.paired.map(\.name) == ["Studio"])
        #expect(after.connections.last?.status == .unpaired("hindie-box no longer knows this iPhone. Pair it again."))
    }

    @Test func aForgottenBoxSaysToPairItAgainWithItsHost() async throws {
        let servers = try await CanopyPhoneTests.servers(box)
        box.forget(phone: "iPhone")
        box.dropAll()
        let connection = try #require(servers.connections.first)
        #expect(await eventually { !connection.isPaired })

        #expect(
            throws: PhoneProblem(
                title: "hindie-box no longer knows this iPhone. Pair it again.",
                detail: "Pair it again with canopy phone pair --on hindie-box on the Mac.")
        ) { try connection.liveClient() }
    }

    @Test func removingAServerForgetsOnlyIt() async throws {
        let credentials = MemoryCredentialStore(mac.paired(at: 0), box.paired(at: 1))
        let servers = servers(credentials)
        servers.start()
        #expect(await eventually { servers.connections.allSatisfy(\.isConnected) })
        let removed = try #require(servers.connections.last)
        let waiting = Task { try await removed.client(after: removed.generation) }
        try await Task.sleep(for: .milliseconds(20))

        servers.remove(id: removed.id)

        #expect(servers.connections.map(\.name) == ["Studio"])
        #expect(credentials.loadAll().map(\.name) == ["Studio"])
        #expect(await eventually { box.openLinks.isEmpty })
        #expect(mac.openLinks.count == 1)
        await #expect(throws: ServerConnection.NotPaired.self) { try await waiting.value }
        await #expect(throws: ServerConnection.NotPaired.self) { try await removed.client(after: removed.generation) }
    }

    @Test func eachServerBacksOffOnItsOwn() async throws {
        let servers = try await CanopyPhoneTests.servers(mac, box, sleeper: sleeper)
        box.goAway()

        #expect(await eventually { sleeper.sleeping == 1 })
        #expect(servers.connections.first?.isConnected == true)
        #expect(servers.connections.last?.isUnreachable == true)
        box.comeBack()
        await sleeper.wake()
        #expect(await eventually { servers.connections.allSatisfy(\.isConnected) })
    }
}

@MainActor
struct CredentialStoreTests {
    /// What `KeychainCredentialStore` holds under its old account, from before several servers.
    static let legacy = Data(
        #"{"host": "studio.tail1234.ts.net", "port": 6974, "address": "100.101.5.9", "token": "t1", "mac": "Studio", "phone": "iPhone", "version": "0.9"}"#
            .utf8)

    @Test func aPairingFromBeforeSeveralServersIsKept() throws {
        let server = try JSONDecoder().decode(PairedServer.self, from: Self.legacy)

        #expect(server.name == "Studio" && server.kind == PhoneServerKind.mac && server.token == "t1")
        #expect(server.hosts == ["studio.tail1234.ts.net", "100.101.5.9"])
        #expect(server.pairedAt == .distantPast && !server.id.isEmpty)
        let again = try JSONDecoder().decode(PairedServer.self, from: JSONEncoder().encode(server))
        #expect(again == server)
    }

    @Test func aLinkFromTheSameServerIsItsByWhereItListens() {
        let server = FakeMac().paired()

        #expect(server.isServer(of: FakeMac().link))
        #expect(
            server.isServer(of: PairingLink(host: "100.101.5.9", port: PhonePort.standard, code: "C", address: nil)))
        #expect(!server.isServer(of: FakeMac.box().link))
        #expect(!server.isServer(of: PairingLink(host: FakeMac.host, port: 7000, code: "C", address: nil)))
    }
}

/// The Keychain's items for one service, in memory, failing writes while `refusesWrites`.
final class FakeKeychain: KeychainItems, @unchecked Sendable {
    let items = Mutex<[String: Data]>([:])
    let refusesWrites = Mutex(false)

    func all() -> [(account: String, data: Data)] {
        items.withLock { $0.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    }

    func write(_ data: Data, account: String) -> OSStatus {
        guard !refusesWrites.withLock({ $0 }) else { return errSecInteractionNotAllowed }
        items.withLock { $0[account] = data }
        return errSecSuccess
    }

    func delete(account: String) {
        _ = items.withLock { $0.removeValue(forKey: account) }
    }

    var accounts: [String] { items.withLock { $0.keys.sorted() } }
}

@MainActor
struct KeychainMoveTests {
    /// The author's phone, paired with one Mac before this update, keeps that pairing through it.
    @Test func aPairingFromBeforeSeveralServersMovesToItsOwnItem() throws {
        let keychain = FakeKeychain()
        keychain.items.withLock { $0["mac"] = CredentialStoreTests.legacy }
        let store = KeychainCredentialStore(items: keychain)

        let servers = store.loadAll()

        #expect(servers.map(\.name) == ["Studio"] && servers.first?.token == "t1")
        #expect(keychain.accounts == ["server.mac"])
        // A second launch reads the moved item, once.
        #expect(KeychainCredentialStore(items: keychain).loadAll() == servers)
    }

    @Test func aMoveTheKeychainRefusesKeepsTheOldItemAndTheSameServer() throws {
        let keychain = FakeKeychain()
        keychain.items.withLock { $0["mac"] = CredentialStoreTests.legacy }
        keychain.refusesWrites.withLock { $0 = true }

        let first = KeychainCredentialStore(items: keychain).loadAll()
        let second = KeychainCredentialStore(items: keychain).loadAll()

        #expect(keychain.accounts == ["mac"])
        #expect(first.map(\.id) == ["mac"] && second.map(\.id) == ["mac"])
    }

    /// Removing the moved Mac while the move never finished must not bring it back on the next launch.
    @Test func removingAServerWhoseMoveNeverFinishedForgetsTheOldItemToo() throws {
        let keychain = FakeKeychain()
        keychain.items.withLock { $0["mac"] = CredentialStoreTests.legacy }
        keychain.refusesWrites.withLock { $0 = true }
        let store = KeychainCredentialStore(items: keychain)
        let server = try #require(store.loadAll().first)

        store.remove(id: server.id)

        #expect(KeychainCredentialStore(items: keychain).loadAll().isEmpty)
    }

    @Test func anOldItemLeftBehindByAnEarlierMoveIsDropped() throws {
        let keychain = FakeKeychain()
        keychain.items.withLock { $0["mac"] = CredentialStoreTests.legacy }
        let moved = KeychainCredentialStore(items: keychain).loadAll()
        keychain.items.withLock { $0["mac"] = CredentialStoreTests.legacy }

        #expect(KeychainCredentialStore(items: keychain).loadAll() == moved)
        #expect(keychain.accounts == ["server.mac"])
    }

    @Test func serversSaveAndGoOneItemEach() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(items: keychain)
        let mac = FakeMac().paired(at: 1)
        let box = FakeMac.box().paired(at: 2)
        try store.save(box)
        try store.save(mac)

        #expect(store.loadAll().map(\.name) == ["Studio", "hindie-box"])
        store.remove(id: mac.id)
        #expect(store.loadAll().map(\.name) == ["hindie-box"])
    }
}

/// A Keychain that refuses every save.
struct FailingCredentialStore: CredentialStore {
    func loadAll() -> [PairedServer] { [] }
    func save(_ server: PairedServer) throws {
        throw PhoneProblem(title: "This iPhone could not keep its pairing.", detail: "The Keychain said -25299.")
    }
    func remove(id: String) {}
}
