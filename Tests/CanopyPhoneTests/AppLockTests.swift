import Foundation
import Synchronization
import Testing

@testable import CanopyPhone

final class FakeAuthenticator: Authenticator {
    let result: Mutex<AuthResult>
    let asked = Mutex(0)

    init(_ result: AuthResult) {
        self.result = Mutex(result)
    }

    func authenticate(reason: String) async -> AuthResult {
        asked.withLock { $0 += 1 }
        return result.withLock { $0 }
    }

    var isAvailable: Bool { result.withLock { $0 } != .unavailable }
}

final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

@MainActor
struct AppLockTests {
    let clock = TestClock()

    func lock(_ result: AuthResult = .success, defaults: UserDefaults = freshDefaults()) -> (AppLock, FakeAuthenticator)
    {
        let authenticator = FakeAuthenticator(result)
        let lock = AppLock(defaults: defaults, authenticator: authenticator, now: { [clock] in clock.now })
        return (lock, authenticator)
    }

    func advance(_ seconds: TimeInterval) {
        clock.advance(seconds)
    }

    @Test func lockedAtLaunchUntilFaceID() async {
        let (lock, authenticator) = lock()
        #expect(lock.isEnabled)
        lock.launch()
        #expect(lock.isLocked)
        await lock.unlock()
        #expect(!lock.isLocked)
        #expect(authenticator.asked.withLock { $0 } == 1)
    }

    @Test func backWithinFiveMinutesNeedsNothing() async {
        let (lock, authenticator) = lock()
        lock.launch()
        await lock.unlock()
        lock.phaseChanged(to: .inactive)
        lock.phaseChanged(to: .background)
        advance(299)
        lock.phaseChanged(to: .active)
        #expect(!lock.isLocked)
        #expect(!lock.isCovered)
        #expect(authenticator.asked.withLock { $0 } == 1)
    }

    @Test func backAfterFiveMinutesNeedsFaceID() async {
        let (lock, _) = lock()
        lock.launch()
        await lock.unlock()
        lock.phaseChanged(to: .background)
        advance(300)
        lock.phaseChanged(to: .active)
        #expect(lock.isLocked)
    }

    @Test func theAppIsCoveredWhileAwaySoTheAppSwitcherShowsNoAgent() async {
        let (lock, _) = lock()
        lock.launch()
        await lock.unlock()
        lock.phaseChanged(to: .inactive)
        #expect(lock.isCovered)
        lock.phaseChanged(to: .active)
        #expect(!lock.isCovered)
    }

    @Test func aFailedFaceIDStaysLocked() async {
        let (lock, _) = lock(.failed)
        lock.launch()
        await lock.unlock()
        #expect(lock.isLocked)
    }

    @Test func aPhoneWithNoPasscodeCannotLockAndOpens() async {
        let (lock, _) = lock(.unavailable)
        lock.launch()
        await lock.unlock()
        #expect(!lock.isLocked)
        #expect(!lock.canLock)
    }

    @Test func turningTheLockOffAsksForFaceIDFirst() async {
        let (lock, authenticator) = lock(.failed)
        await lock.setEnabled(false)
        #expect(lock.isEnabled)
        authenticator.result.withLock { $0 = .success }
        await lock.setEnabled(false)
        #expect(!lock.isEnabled)
        await lock.setEnabled(true)
        #expect(lock.isEnabled)
        #expect(authenticator.asked.withLock { $0 } == 2)
    }

    @Test func offMeansNeverLockedAndItIsRemembered() async {
        let defaults = freshDefaults()
        let (lock, _) = lock(defaults: defaults)
        await lock.setEnabled(false)
        lock.launch()
        #expect(!lock.isLocked)
        lock.phaseChanged(to: .inactive)
        #expect(!lock.isCovered)
        lock.phaseChanged(to: .background)
        advance(3_600)
        lock.phaseChanged(to: .active)
        #expect(!lock.isLocked)
        let (relaunched, _) = self.lock(defaults: defaults)
        #expect(!relaunched.isEnabled)
    }
}

@MainActor
struct SettingsModelTests {
    @Test func settingsListEachServer() async throws {
        let mac = FakeMac()
        let box = FakeMac.box()
        let servers = try await servers(mac, box)
        let settings = SettingsModel(servers: servers)

        let list = settings.list
        #expect(list.map(\.name) == ["Studio", "hindie-box"])
        #expect(list.map(\.kindText) == ["Mac", "Host"])
        let studio = try #require(list.first)
        #expect(studio.host == FakeMac.host)
        #expect(studio.address == FakeMac.address)
        #expect(studio.phone == "iPhone")
        #expect(studio.version == "0.9")
        #expect(studio.statusText == "Connected")
        #expect(
            studio.removeHint == "Studio still lists this iPhone until you run canopy phone remove \"iPhone\" there.")
        #expect(
            list.last?.removeHint
                == "hindie-box still lists this iPhone until you run canopy phone remove \"iPhone\" --on hindie-box on the Mac."
        )
    }

    @Test func removingAServerForgetsIt() async throws {
        let mac = FakeMac()
        let box = FakeMac.box()
        let servers = try await servers(mac, box)
        let settings = SettingsModel(servers: servers)

        settings.remove(id: try #require(settings.list.last).id)

        #expect(settings.list.map(\.name) == ["Studio"])
        #expect(await eventually { box.openLinks.isEmpty })
    }

    @Test func statusSaysWhenAServerIsOutOfReachOrForgotThePhone() async throws {
        let mac = FakeMac()
        let box = FakeMac.box()
        let servers = try await servers(mac, box)
        let settings = SettingsModel(servers: servers)
        mac.goAway()
        box.forget(phone: "iPhone")
        box.dropAll()
        #expect(await eventually { settings.list.map(\.statusText) == ["Can't reach Studio", "No longer paired"] })
    }
}
