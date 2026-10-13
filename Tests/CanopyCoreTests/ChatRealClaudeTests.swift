import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// A chat against the installed Claude Code, on Haiku, started through the login shell as Canopy starts it. It uses
/// the Claude Code login and settings of whoever runs it, so it runs only with CANOPY_REAL_CLAUDE=1, which `make e2e`
/// sets.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_REAL_CLAUDE"] == "1"), .serialized)
struct ChatRealClaudeTests {
    let folder: TempDir
    let home = NSHomeDirectory()

    init() throws {
        folder = try TempDir()
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", "-b", "main", folder.path]
        try git.run()
        git.waitUntilExit()
    }

    func session(id: String? = nil) -> ChatSession {
        let folder = folder.path
        let home = home
        let settings = ShellSettings.current(
            home: CanopyHome(path: folder + "/.canopy-home"), cliDirectory: nil, logsCommands: false)
        return ChatSession(
            model: "haiku", mode: "default", sessionID: id, title: "",
            launcher: { model, mode, resume in
                var environment = ["HOME": home, "USER": NSUserName(), "LANG": "en_US.UTF-8", "TERM": "dumb"]
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
                // Through tee, so a failure can be read back from the stream itself.
                let script =
                    ClaudeLaunch.script(arguments: ClaudeLaunch.arguments(model: model, mode: mode, resume: resume))
                    .replacingOccurrences(of: "exec claude", with: "claude")
                    + " | tee -a \(SetupScript.quoted(folder + "/stream.log"))"
                return settings.script(script, environment: environment, directory: folder)
            },
            transcript: { ClaudeProjects.transcript(session: $0, folder: folder, home: home) },
            trust: ChatTrust(isTrusted: { true }, grant: {}))
    }

    func lastText(_ chat: ChatSession) -> String {
        chat.items.last { if case .text = $0.content { true } else { false } }?.plainText ?? ""
    }

    /// Allows the command if Claude Code asks, then waits until it runs. Claude Code runs some commands without asking.
    func startedRunning(_ chat: ChatSession) async -> Bool {
        await eventually(timeout: .seconds(120)) {
            if chat.permission != nil { chat.allow() }
            return !chat.runningCommands.isEmpty
        }
    }

    func finished(_ chat: ChatSession, within seconds: Int = 120) async -> Bool {
        await eventually(timeout: .seconds(seconds)) { !chat.isWorking }
    }

    @Test func aWholeConversation() async throws {
        defer { removeTranscripts() }
        let chat = session()
        defer { dump(chat) }

        chat.send("Reply with exactly the word PONG and nothing else.")
        #expect(await finished(chat))
        #expect(lastText(chat).contains("PONG"))
        #expect(chat.failure == nil)
        #expect(chat.queued.isEmpty)
        let id = try #require(chat.sessionID)
        #expect(chat.contextWindow != nil)
        #expect(chat.contextTokens != nil)

        chat.send("Use the Bash tool to run exactly this command: touch made.txt")
        #expect(await eventually(timeout: .seconds(120)) { chat.permission != nil })
        #expect(chat.permission?.subject.contains("touch made.txt") == true)
        chat.allow()
        #expect(await finished(chat))
        #expect(FileManager.default.fileExists(atPath: folder.sub("made.txt")))

        chat.send("Use the Bash tool to run exactly this command: rm made.txt")
        #expect(await eventually(timeout: .seconds(120)) { chat.permission != nil })
        chat.send("Do not delete it. Reply with exactly the word KEPT instead.")
        #expect(await finished(chat))
        #expect(chat.queued.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.sub("made.txt")))
        #expect(lastText(chat).contains("KEPT"))

        // A message sent while a command runs reaches Claude when that step ends, and its echo clears the queue.
        chat.send(#"Use the Bash tool to run exactly this command: python3 -c "import time; time.sleep(8)""#)
        #expect(await startedRunning(chat))
        chat.send("After that command, reply with exactly the word QUEUED and nothing else.")
        #expect(chat.queued.last?.waitsForStep == true)
        #expect(await finished(chat))
        #expect(chat.queued.isEmpty)
        #expect(lastText(chat).contains("QUEUED"))

        chat.send(#"Use the Bash tool to run exactly this command: python3 -c "import time; time.sleep(60)""#)
        #expect(await startedRunning(chat))
        chat.interrupt()
        #expect(await finished(chat, within: 20))
        chat.close()

        // Opened again, it shows the conversation and goes on with it.
        let resumed = session(id: id)
        resumed.open()
        #expect(resumed.items.contains { $0.plainText?.contains("PONG") == true })
        resumed.send("What file did you create earlier? Reply with just its name.")
        #expect(await finished(resumed))
        #expect(lastText(resumed).contains("made.txt"))
        #expect(resumed.sessionID == id)
        resumed.close()
    }

    /// Prints the conversation and keeps the stream log where it can be read after a failure.
    func dump(_ chat: ChatSession) {
        for item in chat.items {
            switch item.content {
            case .prompt(let prompt): print("CHAT you:", prompt.text)
            case .text(let text): print("CHAT claude:", text.markdown.prefix(200))
            case .tools(let group):
                print("CHAT tools:", group.summary, group.calls.map { $0.result?.prefix(80) ?? "running" })
            case .notice(let notice): print("CHAT notice:", notice)
            default: print("CHAT other:", item.id)
            }
        }
        print(
            "CHAT working:", chat.isWorking, "queued:", chat.queued.count, "failure:", String(describing: chat.failure))
        guard let kept = ProcessInfo.processInfo.environment["CANOPY_REAL_CLAUDE_LOG"] else { return }
        try? FileManager.default.removeItem(atPath: kept)
        try? FileManager.default.copyItem(atPath: folder.sub("stream.log"), toPath: kept)
    }

    func removeTranscripts() {
        let projects = ClaudeProjects.root(home: home).appending(path: ClaudeProjects.folderName(for: folder.path))
        if projects.path.contains("canopy-tests-") { try? FileManager.default.removeItem(at: projects) }
    }
}
