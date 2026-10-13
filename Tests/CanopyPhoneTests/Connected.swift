import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

/// A connection to the fake Mac, paired and connected, with its inbox in place.
@MainActor
func connected(to mac: FakeMac, inbox: PhoneInbox = PhoneInbox(), sleeper: ManualSleeper = ManualSleeper()) async throws
    -> MacConnection
{
    mac.setInbox(inbox)
    let connection = MacConnection(
        transport: mac, credentials: MemoryCredentialStore(mac.paired()), phoneName: "iPhone", sleep: sleeper.sleep)
    connection.start()
    try #require(await eventually { connection.status == .connected })
    return connection
}

/// UserDefaults of a test's own, so settings never leak between tests.
func freshDefaults() -> UserDefaults {
    let name = "canopy-phone-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

enum Rows {
    static func agent(
        _ pane: String, _ state: AgentState, since: Double = 1_000, unseen: Bool = false, line: String? = nil,
        prompt: OpenPrompt? = nil, transcript: Bool = true
    ) -> PhoneAgent {
        PhoneAgent(
            pane: pane, state: state, unseen: unseen, since: since, lastLine: line, prompt: prompt,
            hasTranscript: transcript)
    }

    static let permission = OpenPrompt(id: "prompt-1", kind: .permission, tool: "Bash", detail: "npx convex deploy")

    static let main = PhoneRow(
        path: "/canopy", name: "main", repo: "canopy", isMain: true,
        agents: [agent("p1", .working, since: 1_900, line: "Watching 6 rows.")])
    static let ticket = PhoneRow(
        path: "/tickets/0853", name: "#0853", plugin: "ticket",
        agents: [agent("p2", .waiting, since: 1_800, line: "Wants to run npx convex deploy", prompt: permission)])
    static let companion = PhoneRow(
        path: "/canopy-ios", name: "feat/ios-companion", repo: "canopy",
        agents: [agent("p3", .waiting, since: 1_700, line: "Asks: Tailscale or a Cloudflare tunnel?")])
    static let drain = PhoneRow(
        path: "/canopy-drain", name: "fix/port-scan-drain", repo: "canopy",
        agents: [agent("p4", .done, since: 1_100, unseen: true, line: "READY: PR #41 open, CI green")])
    static let labels = PhoneRow(
        path: "/canopy-labels", name: "feat/port-labels", repo: "canopy",
        agents: [agent("p5", .working, since: 1_500, line: "Running make test")])
    static let idle = PhoneRow(path: "/canopy-idle", name: "fix/hand-checks", repo: "canopy")

    static let inbox = PhoneInbox(rows: [main, companion, drain, labels, idle, ticket])
}
