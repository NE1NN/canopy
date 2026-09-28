import Foundation
import Testing

@testable import CanopyCore

struct PaneEnvironmentTests {
    let context = PaneContext(
        row: Row(repoPath: "/r/demo", path: "/w/feat-x", branch: "feat/x", head: nil, rowClass: .canopy),
        repoName: "demo"
    )

    func settings(_ base: [String: String], shell: String = "/bin/zsh") -> ShellSettings {
        ShellSettings(
            shell: shell, baseEnvironment: base, cliDirectory: "/App/Contents/Resources/bin",
            home: CanopyHome(path: "/h/.canopy"), language: "en_AU.UTF-8")
    }

    @Test func keepsLoginSessionVariablesAndDropsTheRest() {
        let base = [
            "HOME": "/Users/me", "USER": "me", "SSH_AUTH_SOCK": "/tmp/agent", "CLAUDE_CODE_CHILD_SESSION": "1",
            "PATH": "/some/tool/bin:/usr/bin", "GIT_DIR": "/elsewhere/.git", "ZDOTDIR": "/Users/me/.config/zsh",
        ]

        let environment = PaneEnvironment.build(settings: settings(base), context: context, pane: PaneID(12))

        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["USER"] == "me")
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(environment["ZDOTDIR"] == "/Users/me/.config/zsh")
        #expect(environment["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(environment["GIT_DIR"] == nil)
        #expect(environment["PATH"] == "/App/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["SHELL"] == "/bin/zsh")
        #expect(environment["LANG"] == "en_AU.UTF-8")
    }

    @Test func describesTheTerminalRowAndPane() {
        let environment = PaneEnvironment.build(settings: settings([:]), context: context, pane: PaneID(12))

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "Canopy")
        #expect(environment["CANOPY_HOME"] == "/h/.canopy")
        #expect(environment["CANOPY_REPO"] == "demo")
        #expect(environment["CANOPY_ROW"] == "feat/x")
        #expect(environment["CANOPY_ROW_PATH"] == "/w/feat-x")
        #expect(environment["CANOPY_ROOT_PATH"] == "/r/demo")
        #expect(environment["CANOPY_PANE"] == "p12")
        #expect(environment["HOME"] == NSHomeDirectory())
    }

    @Test func keepsTheAppsOwnLanguage() {
        let environment = PaneEnvironment.build(
            settings: settings(["LANG": "fr_FR.UTF-8"]), context: context, pane: PaneID(1))

        #expect(environment["LANG"] == "fr_FR.UTF-8")
    }

    @Test func languageFollowsTheLocaleWhenMacOSHasIt() {
        let installed: Set<String> = ["en_AU.UTF-8", "en_US.UTF-8"]

        #expect(LoginShell.language(for: "en_AU", exists: installed.contains) == "en_AU.UTF-8")
        #expect(LoginShell.language(for: "en_AU@rg=auzzzz", exists: installed.contains) == "en_AU.UTF-8")
        #expect(LoginShell.language(for: "en-AU", exists: installed.contains) == "en_AU.UTF-8")
        #expect(LoginShell.language(for: "xx_YY", exists: installed.contains) == "en_US.UTF-8")
    }

    @Test func interactiveShellIsALoginShell() {
        let launch = settings([:]).interactiveShell(environment: [:], directory: "/w")

        #expect(launch.executable == "/bin/zsh")
        #expect(launch.arguments == ["-zsh"])
        #expect(launch.directory == "/w")
    }

    @Test func scriptsRunInAnInteractiveLoginShell() {
        let zsh = settings([:]).script("echo hi", environment: [:], directory: "/w")
        let fish = settings([:], shell: "/opt/homebrew/bin/fish").script("echo hi", environment: [:], directory: "/w")

        #expect(zsh.arguments == ["zsh", "-i", "-l", "-c", "echo hi"])
        #expect(fish.executable == "/bin/zsh")
        #expect(fish.arguments == ["zsh", "-i", "-l", "-c", "echo hi"])
    }

    @Test func loginShellIsRunnable() {
        #expect(access(LoginShell.path(), X_OK) == 0)
    }

    @Test func terminalsTakeZDOTDIRFromTheLoginSessionNotFromWhateverLaunchedTheApp() {
        // Like `canopy` run from a shell whose ~/.zshenv exports ZDOTDIR. A Terminal window would read that ~/.zshenv.
        let launcher = ["HOME": "/Users/me", "ZDOTDIR": "/Users/me/.config/zsh"]
        let home = CanopyHome(path: "/h/.canopy")

        let unset = ShellSettings.current(
            home: home, cliDirectory: nil, logsCommands: true, environment: launcher, sessionVariable: { _ in nil })
        let set = ShellSettings.current(
            home: home, cliDirectory: nil, logsCommands: true, environment: launcher,
            sessionVariable: { $0 == "ZDOTDIR" ? "/session/zsh" : nil })

        #expect(unset.baseEnvironment["ZDOTDIR"] == nil)
        #expect(set.baseEnvironment["ZDOTDIR"] == "/session/zsh")
        #expect(set.baseEnvironment["HOME"] == "/Users/me")
    }

    @Test func readsLaunchctlsAnswer() {
        #expect(LoginShell.sessionValue(launchctlOutput: Data()) == nil)
        #expect(LoginShell.sessionValue(launchctlOutput: Data("/Users/me/z dot\n".utf8)) == "/Users/me/z dot")
        #expect(LoginShell.sessionValue(launchctlOutput: Data("\n".utf8)) == "")
        #expect(LoginShell.sessionVariable("CANOPY_NEVER_SET_\(UUID().uuidString)") == nil)
    }
}
