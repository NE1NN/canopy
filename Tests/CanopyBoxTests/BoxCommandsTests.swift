import CanopyAgents
import CanopyTestSupport
import CanopyWire
import Foundation
import Testing

@testable import CanopyBoxKit

struct BoxCommandsTests {
    static func request(
        _ args: [String], pane: String? = nil, repo: String? = "demo", cwd: String = "/", stdin: Data? = nil
    ) -> RelayRequest {
        var env: [String: String] = ["CANOPY_HOME_ID": BoxTestHome.homeID]
        env["CANOPY_PANE"] = pane
        env["CANOPY_REPO"] = repo
        return RelayRequest(
            version: "v", args: args, cwd: cwd, env: env, stdin: stdin?.base64EncodedString(), age: 0.1)
    }

    static func text(_ base64: String) -> String {
        String(decoding: Data(base64Encoded: base64) ?? Data(), as: UTF8.self)
    }

    @Test func agentHookReportsAndPrintsNothing() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        let input = Data(#"{"hook_event_name": "UserPromptSubmit", "session_id": "s"}"#.utf8)
        let reply = await BoxCommands.answer(Self.request(["agent-hook"], pane: pane, stdin: input), on: daemon)
        #expect(reply == RelayReply(stdout: Data(), stderr: Data(), status: 0))
        #expect(await daemon.snapshot().panes.first?.agent == .working)
    }

    @Test func hooksNeverLeaveTheBox() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let mac = try FakeMac(at: home.paths.appSocket, .reply(.failure("no")))
        let input = Data(#"{"hook_event_name": "Stop"}"#.utf8)
        let reply = await BoxCommands.answer(Self.request(["agent-hook"], pane: "p12", stdin: input), on: daemon)
        #expect(reply.status == 0)
        #expect(mac.count == 0)
    }

    @Test func rowNewPrintsWhatTheMacPrints() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let reply = try #require(await BoxCommands.run(Self.request(["row", "new", "feat/n"]), on: daemon))
        let path = home.paths.worktrees(repo: "demo") + "/feat-n"
        #expect(reply.status == 0)
        #expect(Self.text(reply.stdout) == "Created new branch feat/n from origin/main in \(path).\n")
        let ran = try #require(
            await BoxCommands.run(Self.request(["row", "new", "feat/run", "--run", "echo hi", "--json"]), on: daemon))
        let json = try JSONDecoder().decode(BoxCommands.RowNewOutput.self, from: Data(base64Encoded: ran.stdout)!)
        #expect(json.pane == "b1")
        #expect(json.row.branch == "feat/run")
    }

    @Test func rowNewElsewhereGoesToTheMac() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        for args in [
            ["row", "new", "x", "--on", "local"], ["row", "new", "--pr", "12"], ["row", "new", "x", "--select"],
            ["row", "new", "x", "--repo", "elsewhere"], ["row", "new", "--help"], ["web", "open", "https://a.b"],
        ] {
            #expect(await BoxCommands.run(Self.request(args), on: daemon) == nil, "\(args)")
        }
        #expect(await BoxCommands.run(Self.request(["row", "new", "y", "--on", "box"]), on: daemon)?.status == 0)
    }

    @Test func rowListListsTheBoxsRows() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        _ = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/l"))
        let reply = try #require(await BoxCommands.run(Self.request(["row", "list"]), on: daemon))
        let lines = Self.text(reply.stdout).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("BRANCH"))
        #expect(lines[1].hasPrefix("main  ") && lines[1].hasSuffix(home.clone))
        #expect(lines[2].hasPrefix("feat/l") && lines[2].contains(" canopy "))
    }

    @Test func rowRemoveTakesTheRowYouAreIn() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let made = try await daemon.rowNew(BoxRowNewParams(repo: "demo", branch: "feat/rm"))
        let reply = try #require(await BoxCommands.run(Self.request(["row", "rm"], cwd: made.row.path), on: daemon))
        #expect(Self.text(reply.stdout) == "Removed feat/rm.\n")
        #expect(await BoxCommands.run(Self.request(["row", "rm", "not-a-box-row"]), on: daemon) == nil)
    }

    @Test func termCommandsAnswerForBoxPanesAndPassTheRestOn() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let pane = try await daemon.paneNew(BoxPaneNewParams(rowPath: home.clone))
        #expect(await BoxCommands.run(Self.request(["term", "send", "p12", "hi"]), on: daemon) == nil)
        let sent = try #require(await BoxCommands.run(Self.request(["term", "send", pane, "echo hi"]), on: daemon))
        #expect(Self.text(sent.stdout) == "Sent to \(pane).\n")
        await daemon.report(pane: pane, AgentReport(state: .done, session: "s"))
        let waited = try #require(
            await BoxCommands.run(Self.request(["term", "wait", pane, "--timeout", "5s"]), on: daemon))
        #expect(Self.text(waited.stdout) == "\(pane) done\n")
        let listed = try #require(await BoxCommands.run(Self.request(["term", "list"], cwd: home.clone), on: daemon))
        #expect(Self.text(listed.stdout).split(separator: "\n").last?.hasPrefix(pane) == true)
        let read = try #require(await BoxCommands.run(Self.request(["term", "read", pane, "--json"]), on: daemon))
        #expect(
            try JSONDecoder().decode(TermReadResult.self, from: Data(base64Encoded: read.stdout)!).text.isEmpty == false
        )
    }

    @Test func jsonFailuresPrintAnErrorObject() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let reply = try #require(await BoxCommands.run(Self.request(["row", "rm", home.clone, "--json"]), on: daemon))
        #expect(reply.status == 1)
        #expect(Self.text(reply.stderr) == "error: The main checkout cannot be removed.\n")
        let printed = try JSONDecoder().decode([String: ControlError].self, from: Data(base64Encoded: reply.stdout)!)
        #expect(printed["error"]?.code == "cannot_remove_main")
    }

    @Test func aSilentMacFailsWithinTheWait() async throws {
        let home = try await BoxTestHome()
        let mac = try FakeMac(at: home.paths.appSocket, .silent)
        let started = ContinuousClock.now
        let reply = await MacRelay.forward(
            Self.request(["web", "open", "x"]), appSocket: home.paths.appSocket, acknowledgementWait: .milliseconds(500)
        )
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(reply == .failure(MacRelay.notConnected))
        #expect(mac.count == 1)
    }

    @Test func noMacSocketFailsAtOnce() async throws {
        let home = try await BoxTestHome()
        let reply = await MacRelay.forward(Self.request(["web", "open", "x"]), appSocket: home.paths.appSocket)
        #expect(reply == .failure(MacRelay.notConnected))
        #expect(MacRelay.notConnected == "This needs Canopy on the Mac, which isn't connected.")
    }

    @Test func theMacsReplyComesBackWhole() async throws {
        let home = try await BoxTestHome()
        let daemon = try await home.daemon()
        let answer = RelayReply(stdout: Data("out\n".utf8), stderr: Data("err\n".utf8), status: 3)
        let mac = try FakeMac(at: home.paths.appSocket, .reply(answer))
        let reply = await BoxCommands.answer(Self.request(["web", "open", "https://a.b"]), on: daemon)
        #expect(reply == answer)
        #expect(mac.requests.withLock { $0.first?.args } == ["web", "open", "https://a.b"])
    }
}
