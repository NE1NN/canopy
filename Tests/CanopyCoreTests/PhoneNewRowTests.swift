import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// A task from the phone on this Mac: the row by `row new`'s rules, its setup, then the agent's line in a new tab.
@MainActor
struct PhoneNewRowTests {
    func setUp(_ dir: TempDir, config: String?) async throws -> RowLifecycle {
        try await RowSetupTests().setUp(dir, config: config).1
    }

    /// Writes the pane and each argument after the command, so a test sees what the agent would get.
    static let recorder = #"printf '%s|' "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../ran""#

    /// Typed text would reach the shell's line editor, where a control character is a key even inside quotes.
    nonisolated static let briefs = [
        "Fix it's $(touch pwned) login", "tab\there", "\u{15}touch pwned\r", "\u{3}two\nlines \u{7}",
    ]

    @Test(arguments: briefs)
    func newRowMakesTheRowAndRunsTheLine(_ brief: String) async throws {
        let dir = try TempDir()
        let rows = try await setUp(dir, config: nil)
        defer { rows.terminals.closeAll() }

        let made = try await rows.phoneNewRow(
            PhoneNewRowParams(repo: "demo", branch: "feat/phone", brief: brief),
            line: PhoneAgentCommand.line(Self.recorder, brief: brief))

        #expect(made.branch == "feat/phone")
        let row = try #require(await rows.workspace.snapshot.row(path: made.path))
        #expect(rows.terminals.tabs(inRow: row.path).compactMap(\.focused?.id.description) == [made.pane])
        #expect(await eventually { RowSetupTests().read(dir.sub("ran")) == "\(made.pane)|\(brief)|" })
        #expect(!FileManager.default.fileExists(atPath: row.path + "/pwned"))
        #expect(!FileManager.default.fileExists(atPath: dir.sub("home/pwned")))
    }

    @Test func aFailedSetupStartsNoAgent() async throws {
        let dir = try TempDir()
        let rows = try await setUp(dir, config: #"{"setup": ["exit 5"]}"#)
        defer { rows.terminals.closeAll() }

        let error = await #expect(throws: ControlError.self) {
            try await rows.phoneNewRow(
                PhoneNewRowParams(repo: "demo", branch: "feat/broken", brief: "go"),
                line: PhoneAgentCommand.line(Self.recorder, brief: "go"))
        }

        #expect(error?.code == "setup_failed")
        #expect(error?.message.contains("feat/broken") == true)
        #expect(error?.message.contains("Setup tab") == true)
        let row = try #require(await rows.workspace.snapshot.repos.first?.rows.first { $0.branch == "feat/broken" })
        // No tab was opened for the agent: only the failed Setup tab is there.
        #expect(rows.terminals.tabs(inRow: row.path).map(\.name) == ["Setup"])
    }

    @Test func aBranchAlreadyMadeIsRefused() async throws {
        let dir = try TempDir()
        let rows = try await setUp(dir, config: nil)
        defer { rows.terminals.closeAll() }
        let params = PhoneNewRowParams(repo: "demo", branch: "feat/twice", brief: "")
        _ = try await rows.phoneNewRow(params, line: "true")

        let error = await #expect(throws: WorkspaceError.self) { try await rows.phoneNewRow(params, line: "true") }

        #expect(error.map { ControlError($0).code } != nil)
        #expect(rows.terminals.tabs(inRow: dir.path).isEmpty)
    }

    @Test func anUnknownRepoIsRefused() async throws {
        let dir = try TempDir()
        let rows = try await setUp(dir, config: nil)
        defer { rows.terminals.closeAll() }

        await #expect(throws: WorkspaceError.repoNotFound("nope")) {
            try await rows.phoneNewRow(PhoneNewRowParams(repo: "nope", branch: "x", brief: ""), line: "true")
        }
    }
}
