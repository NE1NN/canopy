import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyBoxKit

struct TmuxTests {
    let server: TmuxServer
    let dir: TempDir
    var tmux: Tmux { server.tmux }

    init() throws {
        server = try TmuxServer()
        dir = try TempDir()
    }

    func file(_ name: String) -> String { dir.sub(name) }

    func contents(_ name: String) -> Data? { FileManager.default.contents(atPath: file(name)) }

    @Test func aSessionStartsInItsFolderWithItsVariables() async throws {
        try await tmux.newSession(
            "t1", folder: dir.path, environment: ["CANOPY_PANE": "t1"],
            command: "printf '%s %s' \"$PWD\" \"$CANOPY_PANE\" > seen; sleep 30")
        #expect(await eventually { contents("seen") == Data("\(dir.path) t1".utf8) })
        #expect(await tmux.hasSession("t1"))
        #expect(!(await tmux.hasSession("t")))
    }

    @Test func aSessionsVariableReadsBackUntilItIsUnsetOrTheSessionIsGone() async throws {
        try await tmux.newSession(
            "v", folder: dir.path, environment: ["CANOPY_ROW_PATH": "/w/my row"], command: "exec sleep 30")

        #expect(await tmux.variable("CANOPY_ROW_PATH", of: "v") == "/w/my row")
        #expect(await tmux.variable("CANOPY_PANE", of: "v") == nil)
        #expect(await tmux.variable("CANOPY_ROW_PATH", of: "gone") == nil)
    }

    @Test func panesListEachSessionsCommandAndFolder() async throws {
        try await tmux.newSession("a", folder: dir.path, environment: [:], command: "exec sleep 30")
        try await tmux.newSession("b", folder: "/", environment: [:], command: "exec sleep 31")
        #expect(
            await eventually {
                let panes = (try? await tmux.panes()) ?? []
                return panes.map(\.session).sorted() == ["a", "b"]
                    && panes.allSatisfy { $0.command == "sleep" && $0.pid > 0 }
                    && panes.first { $0.session == "a" }?.folder == dir.path
            })
    }

    @Test func noServerMeansNoPanes() async throws {
        #expect(try await tmux.panes().isEmpty)
        #expect(!(await tmux.hasSession("x")))
    }

    @Test func sentTextArrivesVerbatim() async throws {
        try await tmux.newSession("s", folder: dir.path, environment: [:], command: "cat > out")
        let text = #"-n 'quoted' "double" $HOME \t Enter C-c ;"#
        try await tmux.sendText(text, to: "s")
        try await tmux.sendBytes(Data([0x0D]), to: "s")
        try await tmux.sendBytes(Data([0x04]), to: "s")
        #expect(await eventually { contents("out") == Data((text + "\n").utf8) })
    }

    @Test func aTrailingSemicolonOrBackslashSemicolonStays() async throws {
        try await tmux.newSession("q", folder: dir.path, environment: [:], command: "cat > out")
        for text in ["a;", #"b\;"#, ";"] {
            try await tmux.sendText(text, to: "q")
            try await tmux.sendBytes(Data([0x0D]), to: "q")
        }
        try await tmux.sendBytes(Data([0x04]), to: "q")
        #expect(await eventually { contents("out") == Data("a;\nb\\;\n;\n".utf8) })
    }

    @Test func bytesArriveExactly() async throws {
        try await tmux.newSession(
            "k", folder: dir.path, environment: [:], command: "stty raw -echo; touch ready; head -c 4 > out")
        #expect(await eventually { contents("ready") != nil })
        try await tmux.sendBytes(Data([0x1B, 0x03, 0x41, 0x0D]), to: "k")
        #expect(await eventually { contents("out") == Data([0x1B, 0x03, 0x41, 0x0D]) })
    }

    @Test func aPasteIsBracketedAndWhole() async throws {
        let pasted = Data("\u{1b}[200~hello\rworld\u{1b}[201~".utf8)
        try await tmux.newSession(
            "p", folder: dir.path, environment: [:],
            command: "printf '\\033[?2004h'; stty raw -echo; touch ready; head -c \(pasted.count) > out")
        #expect(await eventually { contents("ready") != nil })
        try await tmux.paste("hello\nworld", to: "p")
        #expect(await eventually { contents("out") == pasted })
    }

    @Test func captureReadsTheScreenOrTheLastLines() async throws {
        try await tmux.newSession("c", folder: dir.path, environment: [:], command: "seq 1 100; sleep 30")
        #expect(await eventually { (try? await tmux.capture("c", lines: 3)) == "98\n99\n100" })
        let screen = try await tmux.capture("c", lines: nil)
        #expect(screen.hasSuffix("100"))
        #expect(!screen.hasPrefix("1\n"))
        await #expect(throws: TmuxError.self) { try await tmux.capture("nope", lines: nil) }
    }

    @Test func killingASessionEndsIt() async throws {
        try await tmux.newSession("z", folder: dir.path, environment: [:], command: "sleep 30")
        await tmux.killSession("z")
        #expect(!(await tmux.hasSession("z")))
    }
}
