import Foundation
import Testing

@testable import CanopyCore

struct TerminalModelTests {
    @Test func tabNamesCountUpAndReuseGaps() {
        #expect(TabNaming.next(after: []) == "Terminal")
        #expect(TabNaming.next(after: ["Terminal"]) == "Terminal 2")
        #expect(TabNaming.next(after: ["Terminal", "Terminal 2", "Setup"]) == "Terminal 3")
        #expect(TabNaming.next(after: ["Terminal 2"]) == "Terminal")
        #expect(TabNaming.next(after: ["Terminal", "Terminal 3"]) == "Terminal 2")
    }

    @Test func programTitleHoldsWhileItsProgramIsInFront() {
        let claude = ForegroundProcess(pid: 20, name: "claude")
        let shell = ForegroundProcess(pid: 10, name: "zsh")
        let title = ProgramTitle(text: "✳ Claude Code", group: 20)

        #expect(PaneTitle.resolve(title, foreground: claude) == "✳ Claude Code")
        #expect(PaneTitle.resolve(title, foreground: shell) == "zsh")
        #expect(PaneTitle.resolve(nil, foreground: shell) == "zsh")
        #expect(PaneTitle.resolve(ProgramTitle(text: "", group: 10), foreground: shell) == "zsh")
        #expect(PaneTitle.resolve(title, foreground: nil) == "✳ Claude Code")
        #expect(PaneTitle.resolve(nil, foreground: nil) == "")
    }

    @Test func quitWarningCountsTerminalsAndNamesEachProgramOnce() {
        #expect(BusyTerminals.quitWarning(["claude"]) == "1 terminal is running a process: claude. Quitting stops it.")
        #expect(
            BusyTerminals.quitWarning(["claude", "bun", "claude"])
                == "3 terminals are running processes: claude, bun. Quitting stops them.")
    }
}

struct RepoConfigTests {
    @Test func readsCommandsAndDefaultsMissingOnes() throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(atPath: dir.sub(".canopy"), withIntermediateDirectories: true)
        try #"{"setup": ["bun install"], "other": true}"#.write(
            toFile: dir.sub(".canopy/config.json"), atomically: true, encoding: .utf8)

        #expect(try RepoConfig.load(from: dir.path) == RepoConfig(setup: ["bun install"], teardown: []))
        #expect(try RepoConfig.load(from: dir.sub("nowhere")) == RepoConfig())
    }

    @Test func explainsWhatIsWrong() throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(atPath: dir.sub(".canopy"), withIntermediateDirectories: true)
        let path = dir.sub(".canopy/config.json")

        try "{".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: WorkspaceError.self) { try RepoConfig.load(from: dir.path) }

        try #"{"teardown": [1]}"#.write(toFile: path, atomically: true, encoding: .utf8)
        do {
            _ = try RepoConfig.load(from: dir.path)
            Issue.record("expected an error")
        } catch let error as WorkspaceError {
            #expect(error.code == "bad_config")
            #expect(error.message.hasPrefix("Could not read \(path): teardown.0:"))
        }
    }
}
