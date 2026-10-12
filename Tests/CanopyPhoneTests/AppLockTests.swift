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

    @Test func offMeansNeverLockedAndItIsRemembered() async {
        let defaults = freshDefaults()
        let (lock, _) = lock(defaults: defaults)
        lock.isEnabled = false
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
    @Test func showsThePairedMacAndUnpairs() async throws {
        let mac = FakeMac()
        let connection = try await connected(to: mac)
        let settings = SettingsModel(connection: connection)
        #expect(settings.mac == "Studio")
        #expect(settings.host == FakeMac.host)
        #expect(settings.address == FakeMac.address)
        #expect(settings.phone == "iPhone")
        #expect(settings.version == "0.9")
        #expect(settings.statusText == "Connected")
        #expect(
            settings.removeHint == "Studio still lists this iPhone until you run canopy phone remove \"iPhone\" there.")
        settings.unpair()
        #expect(connection.paired == nil)
        #expect(await eventually { mac.openLinks.isEmpty })
    }

    @Test func statusSaysWhenTheMacIsOutOfReach() async throws {
        let mac = FakeMac()
        let connection = try await connected(to: mac)
        let settings = SettingsModel(connection: connection)
        mac.goAway()
        #expect(await eventually { settings.statusText == "Can't reach Studio" })
    }
}
