import CanopyAgents
import CanopySystem
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

/// The built `canopy-box`, run as the host runs it.
struct BoxProcessTests {
    /// The program beside the test bundle, which the test target's dependency on it builds.
    static let program: String? = {
        let starts =
            [Bundle(for: Running.self).bundleURL] + Bundle.allBundles.map(\.bundleURL)
            + [URL(fileURLWithPath: CommandLine.arguments[0])]
        for start in starts {
            var folder = start.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = folder.appending(path: "canopy-box").path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
                folder = folder.deletingLastPathComponent()
            }
        }
        return nil
    }()

    /// `canopy-box serve` running in the background, with a tmux folder of the test's own.
    final class Running: Sendable {
        let handle = SubprocessHandle()
        let result: Task<SubprocessResult, any Error>

        init(root: String, homeID: String, tmuxFolder: String) throws {
            let program = try #require(BoxProcessTests.program)
            var environment = GitFixture.environment
            environment["TMUX_TMPDIR"] = tmuxFolder
            environment["TMUX"] = nil
            let fixed = environment
            let handle = handle
            result = Task {
                try await offPool {
                    try Subprocess.run(
                        program, ["serve", "--home-id", homeID, "--root", root], environment: fixed, directory: nil,
                        timeout: .seconds(60), handle: handle)
                }
            }
        }

        deinit { handle.cancel() }
    }

    @Test func serveAnswersHelloAndStopsOnSIGTERM() async throws {
        let dir = try TempDir(in: "/tmp")
        let paths = BoxPaths(root: dir.path, homeID: "abc12345")
        let running = try Running(root: dir.path, homeID: "abc12345", tmuxFolder: dir.path)
        #expect(await eventually { (try? UnixConnection.connect(path: paths.socket)) != nil })
        let response = try await BoxClient(path: paths.socket).call(BoxMethod.hello, BoxHelloParams(version: "1"))
        #expect(try response.result?.decode(BoxHelloResult.self).homeID == "abc12345")
        running.handle.signal(SIGTERM)
        let result = try await running.result.value
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(!FileManager.default.fileExists(atPath: paths.socket))
    }

    @Test func aSecondServeOnOneHomeRefusesToStart() async throws {
        let dir = try TempDir(in: "/tmp")
        let paths = BoxPaths(root: dir.path, homeID: "abc12346")
        let first = try Running(root: dir.path, homeID: "abc12346", tmuxFolder: dir.path)
        #expect(await eventually { (try? UnixConnection.connect(path: paths.socket)) != nil })
        let refused = try Running(root: dir.path, homeID: "abc12346", tmuxFolder: dir.path)
        let second = try await refused.result.value
        #expect(second.status == 1)
        #expect(String(decoding: second.stderr, as: UTF8.self).contains("already runs for this home"))
        #expect(first.handle.isRunning)
    }

    /// Two started at the same moment both pass the socket check; the home's lock lets only one go on.
    @Test func aSecondServeWhileTheHomeIsLockedStopsAtOnce() async throws {
        let dir = try TempDir()
        let paths = BoxPaths(root: Paths.canonical(dir.path), homeID: "abc12347")
        try FileManager.default.createDirectory(atPath: paths.folder, withIntermediateDirectories: true)
        let held = try InstanceLock(path: paths.folder + "/serve.lock")

        let status = await BoxMain.run(["serve", "--home-id", "abc12347", "--root", dir.path])

        #expect(status == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.stateFile))
        withExtendedLifetime(held) {}
    }

    @Test func aBadCommandPrintsUsage() async throws {
        #expect(await BoxMain.run(["serve"]) == 2)
        #expect(await BoxMain.run(["nothing"]) == 2)
        #expect(await BoxMain.run(["serve", "--home-id", "a/b"]) == 2)
    }
}
