import Foundation
import Testing

@testable import CanopyCore

struct RelayTests {
    static let home = "/Users/me/.canopy"
    static let featX = RemoteRowEntry(
        host: "box", path: "/home/me/.canopy/worktrees/demo/feat-x",
        standIn: "/Users/me/.canopy/remote/box/demo/feat-x",
        branch: "feat/x", head: nil)
    static let featX2 = RemoteRowEntry(
        host: "box", path: "/home/me/.canopy/worktrees/demo/feat-x2",
        standIn: "/Users/me/.canopy/remote/box/demo/feat-x2", branch: "feat/x2", head: nil)
    static let nested = RemoteRowEntry(
        host: "box", path: "/home/me/.canopy/worktrees/demo/feat-x/vendor/lib",
        standIn: "/Users/me/.canopy/remote/box/demo/lib", branch: "lib", head: nil)

    static func local(_ remote: String, rows: [RemoteRowEntry] = [featX, featX2]) -> String {
        RelayPaths.local(remote, rows: rows, home: home)
    }

    @Test func aRowsRootMapsToItsStandIn() {
        #expect(Self.local(Self.featX.path) == Self.featX.standIn)
        #expect(Self.local(Self.featX.path + "/") == Self.featX.standIn)
    }

    @Test func aFolderInsideARowKeepsItsTail() {
        #expect(Self.local(Self.featX.path + "/Sources/App") == Self.featX.standIn + "/Sources/App")
    }

    @Test func aSiblingWithASharedPrefixIsNotInsideTheRow() {
        #expect(Self.local(Self.featX2.path + "/docs") == Self.featX2.standIn + "/docs")
        #expect(Self.local(Self.featX.path + "2", rows: [Self.featX]) == Self.home)
    }

    @Test func theLongestOfNestedRowsWins() {
        let rows = [Self.featX, Self.nested]
        #expect(Self.local(Self.nested.path + "/src", rows: rows) == Self.nested.standIn + "/src")
        #expect(Self.local(Self.nested.path + "/src", rows: rows.reversed()) == Self.nested.standIn + "/src")
        #expect(Self.local(Self.featX.path + "/vendor", rows: rows) == Self.featX.standIn + "/vendor")
    }

    @Test func aPathOutsideEveryRowMapsToTheHome() {
        #expect(Self.local("/home/me/Projects/demo") == Self.home)
        #expect(Self.local("/") == Self.home)
        #expect(Self.local("") == Self.home)
    }

    @Test func aPathThatCouldClimbOutOfTheStandInMapsToTheHome() {
        #expect(Self.local(Self.featX.path + "/../../secret") == Self.home)
        #expect(Self.local("home/me/.canopy/worktrees/demo/feat-x") == Self.home)
    }

    static func request(env: [String: String], age: Double? = nil) -> RelayRequest {
        RelayRequest(version: "0.1.0", args: ["agent-hook"], cwd: featX.path, env: env, stdin: nil, age: age)
    }

    static func environment(_ request: RelayRequest, receivedAt: Date = Date()) -> [String: String] {
        RelayRun.environment(
            for: request, host: "box", rows: [featX], home: CanopyHome(path: home), receivedAt: receivedAt,
            shellEnvironment: [
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/me", "TMPDIR": "/var/folders/x/T/",
                "SECRET": "mac",
            ])
    }

    @Test func aRelayedRunGetsOnlyTheRequestsCanopyVariables() {
        let env = Self.environment(
            Self.request(env: ["CANOPY_PANE": "p3", "HOME": "/home/me", "PATH": "/home/me/bin", "LANG": "C"]))

        #expect(env["CANOPY_PANE"] == "p3")
        #expect(env["LANG"] == nil)
        #expect(env["SECRET"] == nil)
    }

    @Test func aRelayedRunGetsThisMacsPathHomeAndTemporaryFolder() {
        let env = Self.environment(
            Self.request(env: ["HOME": "/home/me", "PATH": "/home/me/bin", "TMPDIR": "/tmp/host"]))

        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/me")
        #expect(env["TMPDIR"] == "/var/folders/x/T/")
    }

    @Test func aRelayedRunTargetsThisHomeAndHost() {
        let env = Self.environment(
            Self.request(env: [
                "CANOPY_HOME": "/home/me/.canopy", "CANOPY_HOST": "elsewhere", "CANOPY_ROW_PATH": Self.featX.path,
            ]))

        #expect(env["CANOPY_HOME"] == Self.home)
        #expect(env["CANOPY_HOST"] == "box")
        #expect(env["CANOPY_ROW_PATH"] == Self.featX.standIn)
    }

    @Test func aRowPathOnAnotherHostIsNotTranslatedByThisHostsRows() {
        let other = RemoteRowEntry(
            host: "other", path: "/srv/feat-y", standIn: "/Users/me/.canopy/remote/other/demo/feat-y", branch: nil,
            head: nil)
        let env = RelayRun.environment(
            for: Self.request(env: ["CANOPY_ROW_PATH": "/srv/feat-y"]), host: "box", rows: [other],
            home: CanopyHome(path: Self.home), receivedAt: Date(), shellEnvironment: [:])

        #expect(env["CANOPY_ROW_PATH"] == Self.home)
    }

    @Test func aRelayedRunIsDatedByWhenTheRelayStarted() throws {
        let received = Date(timeIntervalSince1970: 1_800_000_000)

        let dated = Self.environment(Self.request(env: [:], age: 2.5), receivedAt: received)
        let undated = Self.environment(Self.request(env: ["CANOPY_STARTED_AT": "1"]), receivedAt: received)

        #expect(try #require(dated["CANOPY_STARTED_AT"].flatMap(Double.init)) == 1_799_999_997.5)
        #expect(undated["CANOPY_STARTED_AT"] == nil)
    }

    @Test func aRelayedRunStartsInTheNearestFolderTheMacHas() throws {
        let dir = try TempDir()
        let row = RemoteRowEntry(
            host: "box", path: "/home/me/.canopy/worktrees/demo/feat-x", standIn: dir.sub("remote/box/demo/feat-x"),
            branch: "feat/x", head: nil)
        let other = RemoteRowEntry(
            host: "other", path: "/home/me/Projects", standIn: dir.sub("remote/other/demo/main"), branch: "main",
            head: nil)
        try FileManager.default.createDirectory(atPath: row.standIn + "/Sources", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: other.standIn, withIntermediateDirectories: true)
        func folder(_ cwd: String) -> String {
            var request = Self.request(env: [:])
            request.cwd = cwd
            return RelayRun.folder(for: request, host: "box", rows: [row, other], home: CanopyHome(path: dir.path))
        }

        #expect(folder(row.path + "/Sources") == row.standIn + "/Sources")
        #expect(folder(row.path + "/Sources/only/on/the/host") == row.standIn + "/Sources")
        #expect(folder(row.path) == row.standIn)
        #expect(folder("/home/me/Projects") == dir.path)
    }

    @Test func aRequestRoundTripsAsJSON() throws {
        let request = RelayRequest(
            version: "0.1.0", args: ["agent-hook", "--event", "Stop"], cwd: "/home/me", env: ["CANOPY_PANE": "p1"],
            stdin: Data("{\"a\":1}".utf8).base64EncodedString(), age: 0.25)

        let decoded = try JSONDecoder().decode(RelayRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded == request)
        #expect(decoded.input == Data("{\"a\":1}".utf8))
    }

    @Test func aRequestWithoutStdinOrAgeDecodes() throws {
        let line = #"{"version":"0.1.0","args":["list"],"cwd":"/home/me","env":{}}"#

        let decoded = try JSONDecoder().decode(RelayRequest.self, from: Data(line.utf8))

        #expect(decoded.args == ["list"])
        #expect(decoded.input == nil)
        #expect(decoded.age == nil)
    }

    @Test func aReplyRoundTripsAsJSON() throws {
        let reply = RelayReply(stdout: Data("out\n".utf8), stderr: Data([0xff, 0x00]), status: 3)

        let decoded = try JSONDecoder().decode(RelayReply.self, from: JSONEncoder().encode(reply))

        #expect(decoded == reply)
        #expect(Data(base64Encoded: decoded.stdout) == Data("out\n".utf8))
        #expect(Data(base64Encoded: decoded.stderr) == Data([0xff, 0x00]))
    }

    @Test func aFailureReplyCarriesItsMessageOnStderr() {
        let reply = RelayReply.failure("Canopy is not running.")

        #expect(reply.status == 1)
        #expect(Data(base64Encoded: reply.stdout) == Data())
        #expect(Data(base64Encoded: reply.stderr) == Data("Canopy is not running.\n".utf8))
        #expect(RelayReply.failure("x", status: 2).status == 2)
        #expect(reply.code == nil)
        #expect(RelayReply.failure("x", code: "relay_outdated").code == "relay_outdated")
    }
}
