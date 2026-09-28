import Foundation
import Testing

@testable import CanopyCore

/// A report as the zsh shim prints it after a command.
func commandMark(
    token: String = "t0k", exit: String = "0", ms: String = "12", command: String = "ls", cwd: String = "/tmp",
    end: String = "\u{07}"
) -> Data {
    Data("\u{1b}]6973;command;\(token);\(exit);\(ms);\(command);\(cwd)\(end)".utf8)
}

struct CommandMarkScannerTests {
    let ls = CommandMark(command: "ls", directory: "/tmp", exitCode: 0, durationMs: 12)

    @Test func findsAReportAmongOtherOutput() {
        var scanner = CommandMarkScanner(token: "t0k")
        let output = Data("hi \u{1b}[31mred\u{1b}[0m\r\n".utf8) + commandMark() + Data("\u{1b}]0;title\u{07}$ ".utf8)

        #expect(scanner.scan(output) == [ls])
    }

    @Test func findsAReportSplitAtAnyByte() {
        let output = Data("before\u{1b}[1m".utf8) + commandMark() + Data("after".utf8)
        for split in 0...output.count {
            var scanner = CommandMarkScanner(token: "t0k")
            let found = scanner.scan(output.prefix(split)) + scanner.scan(output.dropFirst(split))
            #expect(found == [ls], "split at \(split)")
        }
    }

    @Test func acceptsEitherTerminator() {
        var scanner = CommandMarkScanner(token: "t0k")

        #expect(scanner.scan(commandMark(end: "\u{1b}\\")) == [ls])
    }

    @Test func decodesEncodedText() {
        var scanner = CommandMarkScanner(token: "t0k")
        let report = commandMark(
            exit: "130", ms: "", command: "echo 'a%3Bb' %25d%0Anext%1B", cwd: "/tmp/caf\u{e9} \u{2713}")

        #expect(
            scanner.scan(report) == [
                CommandMark(command: "echo 'a;b' %d\nnext\u{1b}", directory: "/tmp/caf\u{e9} \u{2713}", exitCode: 130)
            ])
    }

    @Test func ignoresReportsThatAreNotThisShells() {
        var scanner = CommandMarkScanner(token: "t0k")
        let others = [
            commandMark(token: "forged"), commandMark(exit: "zero"), Data("\u{1b}]6973;command;t0k;0;1;ls\u{07}".utf8),
            Data("\u{1b}]69730;command;t0k;0;1;ls;/tmp\u{07}".utf8), Data("\u{1b}]52;c;aGk=\u{07}".utf8),
        ]

        #expect(scanner.scan(others.reduce(Data(), +)).isEmpty)
        #expect(scanner.scan(commandMark()) == [ls])
    }

    @Test func dropsAReportCutShortByAnotherSequence() {
        var scanner = CommandMarkScanner(token: "t0k")
        let cut = Data("\u{1b}]6973;command;t0k;0".utf8) + Data("\u{1b}[31m".utf8)
        let cancelled = Data("\u{1b}]6973;command;t0k;0;1;ls;/tmp\u{18}".utf8)

        #expect(scanner.scan(cut + cancelled + commandMark()) == [ls])
    }

    @Test func ignoresReportsTooLongToBeReal() {
        var scanner = CommandMarkScanner(token: "t0k")

        #expect(scanner.scan(commandMark(command: String(repeating: "x", count: 70_000))).isEmpty)
        #expect(scanner.scan(commandMark()) == [ls])
    }
}

@MainActor
struct ZshCommandLoggingTests {
    func commands(_ terminals: TerminalStore) async -> [ActivityEvent] {
        await logged(terminals, "term").filter { $0.type == ActivityType.termCommand }
    }

    /// Types `command`, then waits for its output to show `marker`, which must differ from the typed line zsh echoes.
    func run(_ pane: Pane, _ command: String, until marker: String) async -> Bool {
        await pane.run(command)
        return await eventually { pane.screen.text.contains(marker) }
    }

    static let barrier = "echo done-$((40 + 2))"

    /// The four startup files in `folder`, a path under HOME, each adding its own path to LOADED when zsh reads it.
    func startupFiles(in folder: String) -> [String: String] {
        let paths = [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { folder.isEmpty ? $0 : "\(folder)/\($0)" }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, #"LOADED+=" \#($0)""#) })
    }

    /// Which startup files ran, then ZDOTDIR's value, type, and value in the environment, what is left of Canopy's
    /// variables, and the history file macOS's /etc/zshrc picked.
    static let check =
        #"print -r -- "check:$LOADED:${ZDOTDIR-unset}:${(t)ZDOTDIR}:$(printenv ZDOTDIR):"#
        + #"${CANOPY_USER_ZDOTDIR-none}:${CANOPY_COMMAND_TOKEN-none}:$HISTFILE""#

    /// Runs a last command and waits until it is logged, so every command before it is too.
    func barrier(_ pane: Pane, _ terminals: TerminalStore) async -> Bool {
        await pane.run(Self.barrier)
        return await eventually { await commands(terminals).last?.data["cmd"] == .string(Self.barrier) }
    }

    @Test func commandsAreLoggedWithTheirExitCodeFolderAndDuration() async throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(atPath: dir.sub("sub"), withIntermediateDirectories: true)
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "alias hello='echo hi-from-alias'"])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(await run(pane, "hello", until: "hi-from-alias"))
        await pane.run("(exit 3)")
        await pane.run("cd sub && sleep 0.3")
        await pane.run(#"echo 'a;b' "%d""#)
        #expect(await eventually { await commands(terminals).count == 4 })

        let events = await commands(terminals)
        #expect(events.map(\.data["cmd"]) == ["hello", "(exit 3)", "cd sub && sleep 0.3", #"echo 'a;b' "%d""#])
        #expect(events.map(\.data["exit"]) == [0, 3, 0, 0])
        #expect(events.map(\.data["cwd"]) == [dir.path, dir.path, dir.path, dir.sub("sub")].map(JSONValue.string))
        #expect(events.allSatisfy { $0.data["pane"] == "p1" && $0.row == "feat/x" && $0.source == .ui })
        guard case .number(let slept) = events[2].data["durationMs"] else {
            Issue.record("no duration")
            return
        }
        #expect(slept >= 300 && slept < 5_000)
    }

    @Test func theUsersStartupFilesLoadAsUsual() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""))
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let loaded = " .zshenv .zprofile .zshrc .zlogin"
        let home = dir.sub("user-home")
        #expect(await run(pane, Self.check, until: "check:\(loaded):unset:::none:none:\(home)/.zsh_history"))
    }

    @Test func aZDOTDIRSetInTheUsersZshenvIsFollowed() async throws {
        let dir = try TempDir()
        var files = startupFiles(in: "").merging(startupFiles(in: ".config/zsh")) { $1 }
        files[".zshenv", default: ""] += "\nexport ZDOTDIR=$HOME/.config/zsh"
        let terminals = try Fixture.zshTerminals(dir, files: files)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let loaded = " .zshenv .config/zsh/.zprofile .config/zsh/.zshrc .config/zsh/.zlogin"
        let config = dir.sub("user-home/.config/zsh")
        #expect(
            await run(
                pane, Self.check,
                until: "check:\(loaded):\(config):scalar-export:\(config):none:none:\(config)/.zsh_history"))
        #expect(await eventually { await commands(terminals).map(\.data["cmd"]) == [.string(Self.check)] })
    }

    @Test(arguments: [false, true])
    func aZDOTDIRFromTheLoginSessionIsKept(logsCommands: Bool) async throws {
        let dir = try TempDir()
        let zdot = dir.sub("user-home/z dot")
        let terminals = try Fixture.zshTerminals(
            dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 }, logsCommands: logsCommands,
            environment: ["ZDOTDIR": zdot])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
        #expect(
            await run(
                pane, Self.check, until: "check:\(loaded):\(zdot):scalar-export:\(zdot):none:none:\(zdot)/.zsh_history")
        )
        let logged: [JSONValue?] = logsCommands ? [.string(Self.check)] : []
        #expect(await eventually { await commands(terminals).map(\.data["cmd"]) == logged })
    }

    @Test func anUnreadableZshenvIsSkippedQuietlyAsZshSkipsIt() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""))
        defer { terminals.closeAll() }
        chmod(dir.sub("user-home/.zshenv"), 0)
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let home = dir.sub("user-home")
        #expect(
            await run(pane, Self.check, until: "check: .zprofile .zshrc .zlogin:unset:::none:none:\(home)/.zsh_history")
        )
        #expect(!pane.screen.text.contains("permission denied"))
    }

    @Test func anEmptyZDOTDIRIsKeptAsZshKeepsIt() async throws {
        // zsh reads startup files from a ZDOTDIR that is set, even to nothing, so from /, never from HOME.
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: startupFiles(in: ""), environment: ["ZDOTDIR": ""])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(
            await run(pane, Self.check, until: "check:::scalar-export::none:none:\(dir.sub("user-home"))/.zsh_history"))
    }

    @Test func setupScriptsReadTheLoginSessionsZDOTDIR() async throws {
        let dir = try TempDir()
        let zdot = dir.sub("user-home/z dot")
        let terminals = try Fixture.zshTerminals(
            dir, files: startupFiles(in: "").merging(startupFiles(in: "z dot")) { $1 }, environment: ["ZDOTDIR": zdot])
        defer { terminals.closeAll() }
        let script = #"print -r -- "check:$LOADED:${ZDOTDIR-unset}""#
        let pane = terminals.openTab(for: Fixture.context(dir.path), command: .script(script)).focused

        let loaded = " z dot/.zshenv z dot/.zprofile z dot/.zshrc z dot/.zlogin"
        #expect(await eventually { pane.screen.text.contains("check:\(loaded):\(zdot)") })
    }

    @Test func theUsersOwnHooksKeepRunningWhateverTheirOptions() async throws {
        let dir = try TempDir()
        let zshrc = """
            setopt ksh_arrays
            user_hook() { print -r -- ran >> $HOME/hook.log }
            precmd_functions+=(user_hook)
            """
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": zshrc])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        await pane.run("echo one")
        #expect(await barrier(pane, terminals))

        let runs = (try? String(contentsOfFile: dir.sub("user-home/hook.log"), encoding: .utf8)) ?? ""
        #expect(runs.split(separator: "\n").count == 3, "the hook ran at \(runs.count / 4) prompts")
        #expect(await commands(terminals).map(\.data["cmd"]) == ["echo one", .string(Self.barrier)])
    }

    @Test func aZshrcThatResetsTheHookListsStillHasItsCommandsLogged() async throws {
        for reset in ["precmd_functions=(user_hook)", "preexec_functions=(user_hook)"] {
            let dir = try TempDir()
            let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "user_hook() { :; }\n" + reset])
            defer { terminals.closeAll() }
            let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

            await pane.run("echo one")
            #expect(await barrier(pane, terminals), "\(reset)")
            #expect(await commands(terminals).map(\.data["cmd"]) == ["echo one", .string(Self.barrier)], "\(reset)")
        }
    }

    @Test func aShimDeletedWhileCanopyRunsIsWrittenAgain() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "alias hello='echo hi-from-alias'"])
        defer { terminals.closeAll() }
        let first = terminals.openTab(for: Fixture.context(dir.path)).focused
        #expect(await run(first, "echo first-$((40 + 2))", until: "first-42"))
        try FileManager.default.removeItem(at: terminals.settings.home.zshShimFolder)

        let pane = terminals.addPane(for: Fixture.context(dir.path), fits: { _ in true })
        #expect(await run(pane, "hello", until: "hi-from-alias"))
        #expect(await eventually { await commands(terminals).last?.data["cmd"] == "hello" })
    }

    @Test func commandsHistoryIgnoreMatchesAreLeftOut() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "HISTORY_IGNORE='(*secret*|ls)'"])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        await pane.run("echo my-secret-one")
        await pane.run("ls")
        await pane.run("echo public-two")
        #expect(await barrier(pane, terminals))

        #expect(await commands(terminals).map(\.data["cmd"]) == ["echo public-two", .string(Self.barrier)])
    }

    @Test func commandsStartingWithASpaceAreLeftOutUnderHistIgnoreSpace() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, files: [".zshrc": "setopt hist_ignore_space"])
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        await pane.run(" echo secret-one")
        await pane.run("echo public-two")
        #expect(await barrier(pane, terminals))

        #expect(await commands(terminals).map(\.data["cmd"]) == ["echo public-two", .string(Self.barrier)])
    }

    @Test func reportsWithoutTheShellsTokenAreIgnored() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        let forge = #"printf '\e]6973;command;forged;0;1;fake;/\a'"#
        await pane.run(forge)
        #expect(await barrier(pane, terminals))

        #expect(await commands(terminals).map(\.data["cmd"]) == [.string(forge), .string(Self.barrier)])
    }

    @Test func zshIsLeftAloneWhenCommandLoggingIsOff() async throws {
        let dir = try TempDir()
        let terminals = try Fixture.zshTerminals(dir, logsCommands: false)
        defer { terminals.closeAll() }
        let pane = terminals.openTab(for: Fixture.context(dir.path)).focused

        #expect(await run(pane, #"print -r -- "zd:${ZDOTDIR-unset}""#, until: "zd:unset"))
        #expect(await run(pane, Self.barrier, until: "done-42"))

        #expect(await commands(terminals).isEmpty)
    }

    @Test func onlyZshShellsGetTheShim() throws {
        let dir = try TempDir()
        var settings = Fixture.shellSettings(dir)
        settings.logsCommands = true

        let environment = ["ZDOTDIR": "/z"]

        let bash = settings.interactiveShell(environment: environment, directory: "/", commandToken: "t0k")
        settings.shell = "/bin/zsh"
        let zsh = settings.interactiveShell(environment: environment, directory: "/", commandToken: "t0k")
        let zshWithoutZDOTDIR = settings.interactiveShell(environment: [:], directory: "/", commandToken: "t0k")
        let script = settings.script("true", environment: environment, directory: "/")

        #expect(bash.environment == environment)
        #expect(zsh.environment["ZDOTDIR"] == settings.home.zshShimFolder.path)
        #expect(zsh.environment["CANOPY_USER_ZDOTDIR"] == "/z")
        #expect(zsh.environment["CANOPY_COMMAND_TOKEN"] == "t0k")
        #expect(zshWithoutZDOTDIR.environment["CANOPY_USER_ZDOTDIR"] == nil)
        #expect(script.environment == environment)
    }
}
