import Foundation

@testable import CanopyCore

/// Records what a pane shows and stands in for the user at the keyboard.
@MainActor
final class FakeEmulator: TerminalEmulator {
    var size = TerminalSize.standard
    var onInput: ((Data) -> Void)?
    var onResize: ((TerminalSize) -> Void)?
    var onTitle: ((String) -> Void)?
    private(set) var shown = Data()

    var text: String { String(decoding: shown, as: UTF8.self) }

    func feed(_ data: Data) {
        shown.append(data)
    }

    /// What a terminal would show, roughly: escape sequences removed and lines split on newlines.
    var lines: [String] {
        let plain = text.replacingOccurrences(of: "\u{1b}\\[[0-9;?!]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        return TerminalText.trimmingTrailingBlankLines(plain.components(separatedBy: "\n"))
    }

    func screenText() -> String {
        lines.suffix(size.rows).joined(separator: "\n")
    }

    func recentText(lines count: Int) -> String {
        lines.suffix(count).joined(separator: "\n")
    }

    func type(_ text: String) {
        onInput?(Data(text.utf8))
    }
}

struct FakeEngine: TerminalEngine {
    func makeEmulator(size: TerminalSize) -> any TerminalEmulator {
        let emulator = FakeEmulator()
        emulator.size = size
        return emulator
    }
}

extension Fixture {
    /// Terminals run bash with a private HOME, so tests never depend on the login shell or startup files
    /// of whoever runs them.
    static func shellSettings(_ dir: TempDir) -> ShellSettings {
        let home = dir.sub("user-home")
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return ShellSettings(
            shell: "/bin/bash",
            baseEnvironment: ["HOME": home, "USER": NSUserName(), "BASH_SILENCE_DEPRECATION_WARNING": "1"],
            cliDirectory: nil,
            home: CanopyHome(path: dir.sub("home")),
            language: "en_US.UTF-8"
        )
    }

    @MainActor
    static func terminals(_ dir: TempDir) -> TerminalStore {
        TerminalStore(engine: FakeEngine(), settings: shellSettings(dir))
    }

    static func context(_ path: String, branch: String = "feat/x", repoPath: String = "/r/demo") -> PaneContext {
        PaneContext(
            row: Row(repoPath: repoPath, path: path, branch: branch, head: nil, rowClass: .canopy), repoName: "demo")
    }
}

extension Pane {
    var screen: FakeEmulator { emulator as! FakeEmulator }
}

/// True once no process is left in the group.
func processGroupEnded(_ group: pid_t) -> Bool {
    kill(-group, 0) == -1 && errno == ESRCH
}
