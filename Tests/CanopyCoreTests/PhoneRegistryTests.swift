import Foundation
import Synchronization
import Testing

@testable import CanopyCore

final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

struct PhoneRegistryTests {
    func registry(_ dir: TempDir, _ clock: TestClock = TestClock()) -> PhoneRegistry {
        PhoneRegistry(file: URL(fileURLWithPath: dir.sub("home/phones.json")), now: { clock.now })
    }

    @Test func aCodePairsOnceAndTheTokenOpensTheConnection() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let code = await registry.newCode()
        #expect(code.code.count == 9)
        let paired = try await registry.redeem(code: code.code, name: "Hindie's iPhone")
        #expect(paired.phone.name == "Hindie's iPhone")
        #expect(await registry.authenticate(token: paired.token)?.id == paired.phone.id)
        #expect(await registry.authenticate(token: paired.token + "x") == nil)
        #expect(await registry.authenticate(token: "") == nil)

        await #expect(throws: PhoneRegistry.badCode) {
            try await registry.redeem(code: code.code, name: "Another")
        }
    }

    @Test func aCodeExpiresAfterFiveMinutes() async throws {
        let dir = try TempDir()
        let clock = TestClock()
        let registry = registry(dir, clock)
        let late = await registry.newCode()
        let inTime = await registry.newCode()
        #expect(late.expires == clock.now + 300)
        clock.advance(299)
        _ = try await registry.redeem(code: inTime.code, name: "a")
        clock.advance(2)
        await #expect(throws: PhoneRegistry.badCode) {
            try await registry.redeem(code: late.code, name: "b")
        }
    }

    @Test func codesReadTheWayPeopleTypeThem() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let code = await registry.newCode().code
        let typed = " " + code.replacingOccurrences(of: "-", with: "").lowercased() + " "
        _ = try await registry.redeem(code: typed, name: "a")
    }

    @Test func fiveWrongCodesVoidEveryCodeOutstanding() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let code = await registry.newCode()
        for _ in 0..<5 {
            await #expect(throws: PhoneRegistry.badCode) { try await registry.redeem(code: "AAAA-AAAA", name: "x") }
        }
        await #expect(throws: PhoneRegistry.badCode) { try await registry.redeem(code: code.code, name: "x") }
        let fresh = await registry.newCode()
        _ = try await registry.redeem(code: fresh.code, name: "x")
    }

    @Test func fourWrongCodesVoidNothingAndARightOneStartsTheCountAgain() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let first = await registry.newCode()
        let second = await registry.newCode()
        for _ in 0..<4 {
            await #expect(throws: PhoneRegistry.badCode) { try await registry.redeem(code: "AAAA-AAAA", name: "x") }
        }
        _ = try await registry.redeem(code: first.code, name: "a")
        for _ in 0..<4 {
            await #expect(throws: PhoneRegistry.badCode) { try await registry.redeem(code: "AAAA-AAAA", name: "x") }
        }
        _ = try await registry.redeem(code: second.code, name: "b")
    }

    @Test func aRemovedPhoneIsNotConnected() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let paired = try await registry.redeem(code: await registry.newCode().code, name: "a")
        #expect(await registry.connected(paired.phone.id))
        _ = try await registry.remove(name: "a")
        #expect(await !registry.connected(paired.phone.id))
    }

    @Test func theFileKeepsOnlyAHashOfTheToken() async throws {
        let dir = try TempDir()
        let clock = TestClock()
        let registry = registry(dir, clock)
        let paired = try await registry.redeem(code: await registry.newCode().code, name: "a")
        let file = dir.sub("home/phones.json")
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(!text.contains(paired.token))
        #expect(text.contains(paired.phone.tokenHash))
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let reloaded = self.registry(dir, clock)
        #expect(await reloaded.authenticate(token: paired.token)?.name == "a")
    }

    @Test func anUnreadableFileIsLeftAloneAndPairsNothing() async throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(atPath: dir.sub("home"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: dir.sub("home/phones.json")))
        let registry = registry(dir)
        let code = await registry.newCode().code
        do {
            _ = try await registry.redeem(code: code, name: "a")
            Issue.record("paired with an unreadable phones.json")
        } catch let error as ControlError {
            #expect(error.code == "phones_unreadable")
        }
        await #expect(throws: ControlError.self) { try await registry.remove(name: "a") }
        #expect(try String(contentsOfFile: dir.sub("home/phones.json"), encoding: .utf8) == "not json")
    }

    @Test func aRemovalThatCannotSaveKeepsThePhone() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let paired = try await registry.redeem(code: await registry.newCode().code, name: "a")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.sub("home"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.sub("home")) }
        await #expect(throws: ControlError.self) { try await registry.remove(name: "a") }
        #expect(await registry.authenticate(token: paired.token)?.name == "a")
    }

    @Test func tokensAreLongAndDifferent() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let first = try await registry.redeem(code: await registry.newCode().code, name: "a").token
        let second = try await registry.redeem(code: await registry.newCode().code, name: "b").token
        #expect(first != second)
        #expect(Data(base64URLEncoded: first)?.count == 32)
    }

    @Test func aTakenNameGetsANumber() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        for _ in 0..<3 {
            _ = try await registry.redeem(code: await registry.newCode().code, name: "iPhone")
        }
        #expect(await registry.phones.map(\.name) == ["iPhone", "iPhone 2", "iPhone 3"])
    }

    @Test func anEmptyOrLongNameIsTidied() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let blank = try await registry.redeem(code: await registry.newCode().code, name: "  \n ").phone
        #expect(blank.name == "iPhone")
        let long = try await registry.redeem(
            code: await registry.newCode().code, name: String(repeating: "x", count: 200))
        #expect(long.phone.name.count == 64)
    }

    @Test func removingAPhoneRevokesItsToken() async throws {
        let dir = try TempDir()
        let registry = registry(dir)
        let paired = try await registry.redeem(code: await registry.newCode().code, name: "a")
        let removed = try await registry.remove(name: "a")
        #expect(removed.id == paired.phone.id)
        #expect(await registry.authenticate(token: paired.token) == nil)
        await #expect(throws: PhoneRegistry.notFound("a")) { try await registry.remove(name: "a") }
    }

    @Test func connectingRecordsWhen() async throws {
        let dir = try TempDir()
        let clock = TestClock()
        let registry = registry(dir, clock)
        let paired = try await registry.redeem(code: await registry.newCode().code, name: "a")
        #expect(paired.phone.lastConnected == nil)
        clock.advance(60)
        await registry.connected(paired.phone.id)
        #expect(await registry.phones.first?.lastConnected == clock.now)
    }

    @Test func waitingForACodeEndsWhenItPairsOrExpires() async throws {
        let dir = try TempDir()
        let clock = TestClock()
        let registry = registry(dir, clock)
        let code = await registry.newCode()
        async let paired = registry.waitForPairing(code: code.code)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await registry.redeem(code: code.code, name: "a")
        #expect(await paired?.name == "a")

        let lapsed = await registry.newCode()
        async let nothing = registry.waitForPairing(code: lapsed.code, polling: .milliseconds(10))
        clock.advance(301)
        #expect(await nothing == nil)
    }
}
