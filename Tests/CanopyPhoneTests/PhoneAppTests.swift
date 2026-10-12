import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

@MainActor
struct PairingModelTests {
    let mac = FakeMac()

    func connection() -> MacConnection {
        MacConnection(
            transport: mac, credentials: MemoryCredentialStore(), phoneName: "iPhone", sleep: ManualSleeper().sleep)
    }

    @Test func aPastedLinkPairs() async throws {
        let connection = connection()
        let pairing = PairingModel(connection: connection)
        await pairing.pair(text: "  \(mac.link.url.absoluteString)\n")
        #expect(connection.paired?.mac == "Studio")
        #expect(pairing.problem == nil)
        #expect(!pairing.isPairing)
    }

    @Test(arguments: ["", "hello", "https://example.com", "canopy-phone://pair?host=a"])
    func whatIsNotAPairingLinkSaysSo(_ text: String) async throws {
        let pairing = PairingModel(connection: connection())
        await pairing.pair(text: text)
        #expect(pairing.problem?.title == "That isn't a Canopy pairing link.")
        #expect(mac.connects.isEmpty)
    }

    @Test func aFailedPairingSaysWhy() async throws {
        mac.goAway()
        let pairing = PairingModel(connection: connection())
        await pairing.pair(text: mac.link.url.absoluteString)
        #expect(pairing.problem?.title == "Can't reach \(FakeMac.host).")
    }

    @Test func theSameCodeScannedTwiceWhilePairingPairsOnce() async throws {
        let connection = connection()
        let pairing = PairingModel(connection: connection)
        async let first: Void = pairing.pair(mac.link.url)
        async let second: Void = pairing.pair(mac.link.url)
        _ = await (first, second)
        #expect(mac.requests.filter { $0.method == PhoneMethod.pair }.count == 1)
        #expect(connection.paired != nil)
    }
}

@MainActor
struct PhoneAppTests {
    let mac = FakeMac()

    func app(credentials: MemoryCredentialStore = MemoryCredentialStore()) -> PhoneApp {
        PhoneApp(
            transport: mac, credentials: credentials, defaults: freshDefaults(),
            authenticator: FakeAuthenticator(.success), phoneName: "iPhone")
    }

    @Test func anUnpairedAppHasNothingToLock() async throws {
        let app = app()
        app.launch()
        #expect(!app.lock.isLocked)
        app.phaseChanged(to: .background)
        app.phaseChanged(to: .active)
        #expect(!app.lock.isLocked)
    }

    @Test func aPairingLinkOpensPairing() async throws {
        let app = app()
        app.launch()
        app.open(mac.link.url)
        #expect(await eventually { app.connection.status == .connected })
        app.open(URL(string: "https://example.com")!)
    }

    @Test func goingAwayClosesTheConnectionAndComingBackOpensIt() async throws {
        let app = app(credentials: MemoryCredentialStore(mac.paired()))
        app.launch()
        #expect(app.lock.isLocked)
        #expect(await eventually { app.connection.status == .connected })
        app.phaseChanged(to: .inactive)
        #expect(app.connection.isConnected)
        app.phaseChanged(to: .background)
        #expect(await eventually { mac.openLinks.isEmpty })
        app.phaseChanged(to: .active)
        #expect(await eventually { app.connection.status == .connected && mac.openLinks.count == 1 })
    }
}
