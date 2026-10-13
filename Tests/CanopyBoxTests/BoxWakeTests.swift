import CanopyAgents
import CanopyServer
import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

/// The box's side of waking it: the key from the Mac, which instance it is, and what hello hands phones.
struct BoxWakeTests {
    static let key = BoxWakeKey(accessKeyID: "AKIAEXAMPLE", secretAccessKey: "s3cret-wake")

    @Test func readsTheInstanceAndRegionWithAToken() async throws {
        let imds = try FakeIMDS()

        let identity = await InstanceMetadata.identity(address: "127.0.0.1", port: imds.port)

        #expect(identity == InstanceIdentity(instanceID: imds.instanceID, region: imds.region))
        #expect(
            imds.requests == [
                "PUT /latest/api/token HTTP/1.1", "GET /latest/meta-data/instance-id HTTP/1.1",
                "GET /latest/meta-data/placement/region HTTP/1.1",
            ])
    }

    @Test func aServiceThatNeverAnswersIsGivenUpOnInTime() async throws {
        let silent = try TCPListener(address: "127.0.0.1", port: 0) { _ in }
        defer { silent.close() }
        let started = ContinuousClock.now

        let identity = await InstanceMetadata.identity(
            address: "127.0.0.1", port: silent.port, timeout: .milliseconds(300))

        #expect(identity == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// Off EC2 nothing answers, and the box carries on without a wake key, soon.
    @Test func withoutInstanceMetadataThereIsNoWakeKey() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        var config = home.config
        config.wake = Self.key
        try await daemon.configure(config)
        let closed = try FakeIMDS()
        let port = closed.port
        _ = consume closed
        try "127.0.0.1 \(port)".write(toFile: home.paths.folder + "/imds", atomically: true, encoding: .utf8)
        let started = ContinuousClock.now

        await daemon.learnInstance()

        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(BoxMain.phoneWake(home.paths) == nil)
    }

    /// The box's files copied to another instance learn the new one at the next start.
    @Test func theInstanceIsReadAgainAtStart() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        var config = home.config
        config.wake = Self.key
        try await daemon.configure(config)
        try BoxFiles.write(
            try JSONEncoder().encode(InstanceIdentity(instanceID: "i-old", region: "ap-southeast-2")),
            to: home.paths.instanceFile)
        let imds = try FakeIMDS()
        try BoxFiles.write(Data("127.0.0.1 \(imds.port)".utf8), to: home.paths.folder + "/imds")

        await daemon.learnInstance()
        #expect(BoxDaemon.load(InstanceIdentity.self, from: home.paths.instanceFile)?.instanceID == "i-old")
        await daemon.learnInstance(again: true)

        #expect(BoxDaemon.load(InstanceIdentity.self, from: home.paths.instanceFile)?.instanceID == imds.instanceID)
    }

    /// A Mac whose Keychain would not say leaves the box's key as it was.
    @Test func aConfigureThatKeepsTheKeyLeavesIt() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        var config = home.config
        config.wake = Self.key
        try await daemon.configure(config)

        try await daemon.configure(BoxConfig(host: "box", repos: home.config.repos, keepsWake: true))

        #expect(await daemon.wakeKey == Self.key)
        #expect(BoxDaemon.load(BoxWakeKey.self, from: home.paths.wakeFile) == Self.key)
    }

    @Test func theWakeKeyLivesInWakeJsonNotConfigJson() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        var config = home.config
        config.wake = Self.key

        try await daemon.configure(config)

        let settings = try String(contentsOfFile: home.paths.configFile, encoding: .utf8)
        #expect(!settings.contains("s3cret-wake"))
        #expect(BoxDaemon.load(BoxWakeKey.self, from: home.paths.wakeFile) == Self.key)
        let mode = try FileManager.default.attributesOfItem(atPath: home.paths.wakeFile)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // A restart keeps it; a configure without one forgets it.
        let restarted = BoxDaemon(paths: home.paths, tmux: home.server.tmux, git: { GitFixture.clone($0) })
        await restarted.start()
        #expect(await restarted.wakeKey == Self.key)
        try await restarted.configure(home.config)
        #expect(!FileManager.default.fileExists(atPath: home.paths.wakeFile))
    }

    @Test func aBoxsHelloCarriesItsWakeKey() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon(configured: false)
        let imds = try FakeIMDS()
        try "127.0.0.1 \(imds.port)".write(toFile: home.paths.folder + "/imds", atomically: true, encoding: .utf8)
        try "127.0.0.1 0".write(toFile: home.paths.folder + "/phone-listen", atomically: true, encoding: .utf8)
        var config = home.config
        config.wake = Self.key
        try await daemon.configure(config)
        await daemon.learnInstance()
        let phones = BoxMain.phoneServer(daemon: daemon, paths: home.paths, environment: [:])
        await phones.refresh()
        defer { phones.stop() }
        let port = try #require(await phones.status().endpoints.first?.port)
        let code = await phones.registry.newCode().code
        let client = try PhoneTestClient(port: port)
        let paired = try await offPool {
            try client.call(PhoneMethod.pair, try .from(PhonePairParams(code: code, name: "iPhone")))
        }
        let token = try #require(paired.result).decode(PhonePairResult.self).token

        let hello = try await offPool { try client.call(PhoneMethod.hello, try .from(PhoneHelloParams(token: token))) }

        #expect(
            try #require(hello.result).decode(PhoneHelloResult.self).wake
                == PhoneWake(
                    accessKeyID: Self.key.accessKeyID, secretAccessKey: Self.key.secretAccessKey,
                    instanceID: imds.instanceID, region: imds.region))
    }
}
