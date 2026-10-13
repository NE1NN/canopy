import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

@MainActor
struct ChatRowsTests {
    let home: TempDir
    let folder: TempDir

    init() throws {
        home = try TempDir()
        folder = try TempDir()
    }

    func session(trusted: Bool = true) -> ChatSession {
        let home = home.path
        let folder = folder.path
        return ChatSession(
            model: nil, mode: "default", sessionID: nil, title: "",
            launcher: { model, mode, resume in
                var launch = FakeClaude.launch(home: home, folder: folder)
                launch.arguments =
                    ["python3", "-I", FakeClaude.script]
                    + ClaudeLaunch.arguments(model: model, mode: mode, resume: resume)
                return launch
            },
            transcript: { ClaudeProjects.transcript(session: $0, folder: folder, home: home) },
            trust: ChatTrust(isTrusted: { trusted }, grant: {}))
    }

    func kinds(_ rows: [ChatRow]) -> [String] {
        rows.map {
            switch $0 {
            case .item(let item): if case .prompt = item.content { "prompt" } else { "item" }
            case .streaming: "streaming"
            case .queued: "queued"
            case .permission: "permission"
            case .trust: "trust"
            case .failure: "failure"
            case .status: "status"
            case .running: "running"
            case .empty: "empty"
            }
        }
    }

    @Test func aNewChatIsEmpty() {
        #expect(kinds(ChatRows.rows(for: session())) == ["empty"])
    }

    @Test func anUntrustedFolderAsksFirst() {
        let chat = session(trusted: false)
        chat.open()
        #expect(kinds(ChatRows.rows(for: chat)) == ["trust"])
    }

    @Test func showsTheConversationThenWhatIsPendingThenTheStatus() async throws {
        let chat = session()
        chat.send("run make deploy")

        #expect(await eventually { chat.permission != nil })
        #expect(kinds(ChatRows.rows(for: chat)) == ["prompt", "item", "permission", "status"])

        chat.allow()
        #expect(await eventually { !chat.isWorking })
        #expect(kinds(ChatRows.rows(for: chat)) == ["prompt", "item", "item", "status"])
        chat.close()
    }

    @Test func showsAFailureInsteadOfTheStatus() async throws {
        let chat = session()
        chat.send("crash")
        #expect(await eventually { chat.failure != nil })

        #expect(kinds(ChatRows.rows(for: chat)) == ["prompt", "failure"])
    }

    @Test func rowsAreKeyedSoAChangeShows() async throws {
        let chat = session()
        chat.send("run ls")
        #expect(await eventually { chat.permission != nil })
        let before = ChatRows.rows(for: chat)
        chat.allow()
        #expect(await eventually { !chat.isWorking })
        let after = ChatRows.rows(for: chat)

        // The tool group got its result: same ID, new key.
        #expect(before[1].id == after[1].id)
        #expect(before[1].key != after[1].key)
        #expect(before[0].key == after[0].key)
        chat.close()
    }
}
