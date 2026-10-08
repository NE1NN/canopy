import Foundation
import Testing

@testable import CanopyCore

struct HostConfigTests {
    private func config(in dir: TempDir, _ text: String) throws -> URL {
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func aHostReadsItsReposWakeAndIdleMinutes() throws {
        let dir = try TempDir()
        let file = try config(
            in: dir,
            #"""
            {"hosts": {"box": {"repos": {"solis-v1": "/home/u/solis-v1"}, "wake": "aws start", "idleDetachMinutes": 5}}}
            """#)

        let hosts = HostsConfig.load(from: file)

        #expect(
            hosts.hosts["box"]
                == HostEntry(repos: ["solis-v1": "/home/u/solis-v1"], wake: "aws start", idleDetachMinutes: 5))
        #expect(hosts.warnings.isEmpty)
    }

    @Test func idleMinutesDefaultTo30AndZeroTurnsDetachingOff() throws {
        let dir = try TempDir()
        let file = try config(
            in: dir,
            #"{"hosts": {"a": {"repos": {}}, "b": {"repos": {}, "idleDetachMinutes": 0}, "c": {"repos": {}, "idleDetachMinutes": -4}}}"#
        )

        let hosts = HostsConfig.load(from: file).hosts

        #expect(hosts["a"]?.idleDetachMinutes == 30)
        #expect(hosts["b"]?.idleDetachMinutes == 0)
        #expect(hosts["c"]?.idleDetachMinutes == 30)
        #expect(hosts["a"]?.wake == nil)
    }

    @Test func aHostThatCannotBeReadIsLeftOutWithAWarning() throws {
        let dir = try TempDir()
        let file = try config(in: dir, #"{"hosts": {"bad": {"repos": "nope"}, "good": {"repos": {"r": "/x"}}}}"#)

        let hosts = HostsConfig.load(from: file)

        #expect(Array(hosts.hosts.keys) == ["good"])
        #expect(hosts.warnings.count == 1)
        #expect(hosts.warnings.first?.contains("bad") == true)
    }

    @Test func noHostsKeyNoFileAndBrokenJSONEachGiveNoHosts() throws {
        let dir = try TempDir()
        let file = try config(in: dir, #"{"plugins": {}}"#)
        #expect(HostsConfig.load(from: file).hosts.isEmpty)
        #expect(HostsConfig.load(from: URL(fileURLWithPath: dir.sub("missing.json"))).hosts.isEmpty)
        try "{not json".write(to: file, atomically: true, encoding: .utf8)
        #expect(HostsConfig.load(from: file).hosts.isEmpty)
    }

    @Test func savingAHostKeepsEveryOtherKeyAndItsSpelling() throws {
        let original = """
            {
              "logCommands": false,
              "plugins": {"tickets": {"url": "u", "x": 1e2}},
              "zeta": [1, 2]
            }

            """
        let dir = try TempDir()
        let file = try config(in: dir, original)
        let hosts = HostsConfigFile(url: file)

        try hosts.save("box", HostEntry(repos: ["solis-v1": "/home/u/s"], wake: "w", idleDetachMinutes: 30))

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(#""x": 1e2"#))
        #expect(text.range(of: "logCommands")!.lowerBound < text.range(of: "plugins")!.lowerBound)
        #expect(text.range(of: "zeta")!.lowerBound < text.range(of: "hosts")!.lowerBound)
        #expect(HostsConfig.load(from: file).hosts["box"]?.repos == ["solis-v1": "/home/u/s"])
        #expect(try PluginConfig.sections(in: file)["tickets"] != nil)
    }

    @Test func removingAHostDropsOnlyThatHost() throws {
        let dir = try TempDir()
        let file = try config(in: dir, #"{"hosts": {"a": {"repos": {}}, "b": {"repos": {}}}}"#)
        let hosts = HostsConfigFile(url: file)

        try hosts.remove("a")

        #expect(Array(HostsConfig.load(from: file).hosts.keys) == ["b"])
    }

    @Test func aRepoFindsItsCloneByNameOrByTheEndOfItsPath() {
        let entry = HostEntry(repos: ["solis-v1": "/home/u/solis", "web-app": "/home/u/web"])

        #expect(entry.clonePath(repoName: "solis-v1", repoPath: "/Users/me/solis-v1") == "/home/u/solis")
        #expect(entry.clonePath(repoName: "code/web-app", repoPath: "/Users/me/code/web-app") == "/home/u/web")
        #expect(entry.clonePath(repoName: "other", repoPath: "/Users/me/other") == nil)
    }
}
