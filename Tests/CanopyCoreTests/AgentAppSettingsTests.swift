import Foundation
import Testing

@testable import CanopyCore

struct AgentAppSettingsTests {
    func config(_ json: String) throws -> GlobalConfig {
        try JSONDecoder().decode(GlobalConfig.self, from: Data(json.utf8))
    }

    @Test func soundsDefaultToGlassAndPing() throws {
        let defaults = try config("{}")
        #expect(AgentSound.sound(for: .done, in: defaults) == "Glass")
        #expect(AgentSound.sound(for: .waiting, in: defaults) == "Ping")
        #expect(AgentSound.sound(for: .working, in: defaults) == nil)
        #expect(AgentSound.sound(for: AgentState.none, in: defaults) == nil)
    }

    @Test func soundsCanBeChangedSilencedOrTurnedOff() throws {
        let chosen = try config(#"{"agentDoneSound": "Hero", "agentWaitingSound": "~/Sounds/ask.aiff"}"#)
        #expect(AgentSound.sound(for: .done, in: chosen) == "Hero")
        #expect(AgentSound.sound(for: .waiting, in: chosen) == "~/Sounds/ask.aiff")

        let silent = try config(#"{"agentWaitingSound": ""}"#)
        #expect(AgentSound.sound(for: .waiting, in: silent) == nil)
        #expect(AgentSound.sound(for: .done, in: silent) == "Glass")

        let off = try config(#"{"agentSounds": false}"#)
        #expect(AgentSound.sound(for: .done, in: off) == nil)
        #expect(AgentSound.sound(for: .waiting, in: off) == nil)

        #expect(AgentSound.fallback(for: .done) == "Glass")
        #expect(AgentSound.fallback(for: .waiting) == "Ping")
    }

    @Test func theOfferIsRememberedInStateJSON() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        var state = AppState()
        #expect(!state.agentHooksOffered)
        state.agentHooksOffered = true
        try store.save(state)
        #expect(store.load().state.agentHooksOffered)

        try #"{"version": 1}"#.write(to: URL(fileURLWithPath: dir.sub("state.json")), atomically: true, encoding: .utf8)
        #expect(!store.load().state.agentHooksOffered)
    }

    @Test func theWorkspaceRecordsTheOffer() async throws {
        let dir = try TempDir()
        let home = CanopyHome(path: dir.sub("home"))
        let workspace = Workspace(home: home, git: Fixture.git)
        try await workspace.start()
        #expect(await !workspace.agentHooksOffered)
        try await workspace.setAgentHooksOffered()
        #expect(await workspace.agentHooksOffered)
        #expect(StateStore(url: home.stateFile).load().state.agentHooksOffered)
    }

    @Test func theInstallIsOfferedOnceToClaudeCodeUsers() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("claude"))
        let settings = Fixture.claudeSettings(dir)

        // No Claude Code config folder: Claude Code is not used here.
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: true, settings: settings, configFolder: folder))

        try settings.install()
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))

        try Data("not json".utf8).write(to: settings.url)
        #expect(!ClaudeHooksOffer.shouldOffer(alreadyOffered: false, settings: settings, configFolder: folder))
    }
}
