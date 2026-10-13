import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// `canopy phone agent`: what a task from the phone runs, on this Mac or on an upgraded host.
struct AgentCommandTests {
    func setUp(_ dir: TempDir, upgraded: Bool = true) async throws -> PluginControlTests.Setup {
        let setup = try await PluginControlTests().start(dir)
        try HostsConfigFile(url: setup.home.configFile).save("box", HostEntry(repos: [:], box: upgraded))
        return setup
    }

    func agent(_ setup: PluginControlTests.Setup, _ params: PhonesAgentParams) async throws -> PhonesAgentResult {
        try await PluginControlTests().call(setup, PhonesMethod.agent, params, as: PhonesAgentResult.self)
    }

    @Test func phoneAgentSetsAndClearsTheMacsCommand() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir)
        defer { PluginControlTests().stop(setup) }

        let shown = try await agent(setup, PhonesAgentParams())
        #expect(shown == PhonesAgentResult(command: PhoneAgentCommand.standard, isDefault: true))

        let set = try await agent(setup, PhonesAgentParams(command: "  codex --yolo "))
        #expect(set == PhonesAgentResult(command: "codex --yolo", isDefault: false))
        #expect(GlobalConfig.load(from: setup.home.configFile).agentCommand == "codex --yolo")
        // The hosts in config.json are left as they were.
        #expect(setup.workspace.hosts.hosts["box"]?.box == true)

        let reset = try await agent(setup, PhonesAgentParams(reset: true))
        #expect(reset.isDefault && reset.command == PhoneAgentCommand.standard)
        #expect(GlobalConfig.load(from: setup.home.configFile).agentCommand == nil)
    }

    @Test func anEmptyCommandIsRefused() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir)
        defer { PluginControlTests().stop(setup) }

        let code = try await PluginControlTests().errorCode(setup, PhonesMethod.agent, PhonesAgentParams(command: " "))

        #expect(code == "bad_params")
    }

    @Test func aHostsCommandGoesToItsBox() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir)
        defer { PluginControlTests().stop(setup) }

        let set = try await agent(setup, PhonesAgentParams(command: "claude --model opus", on: "box"))

        #expect(set == PhonesAgentResult(command: "claude --model opus", isDefault: false, on: "box"))
        #expect(setup.workspace.boxConfig(for: "box").agentCommand == "claude --model opus")
        // The Mac's own stays the standard one.
        #expect(try await agent(setup, PhonesAgentParams()).isDefault)

        _ = try await agent(setup, PhonesAgentParams(reset: true, on: "box"))
        #expect(setup.workspace.boxConfig(for: "box").agentCommand == nil)
    }

    @Test func aHostNotUpgradedOrUnknownIsRefused() async throws {
        let dir = try TempDir()
        let setup = try await setUp(dir, upgraded: false)
        defer { PluginControlTests().stop(setup) }

        let notUpgraded = try await PluginControlTests().errorCode(
            setup, PhonesMethod.agent, PhonesAgentParams(command: "x", on: "box"))
        let unknown = try await PluginControlTests().errorCode(
            setup, PhonesMethod.agent, PhonesAgentParams(command: "x", on: "nowhere"))

        #expect(notUpgraded == "host_not_upgraded")
        #expect(unknown == "host_not_found")
    }
}
