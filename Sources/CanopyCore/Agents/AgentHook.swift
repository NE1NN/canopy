import Foundation

/// What `canopy agent-hook` sends, and where.
public struct AgentHookRequest: Sendable {
    public var socketPath: String
    public var request: ControlRequest
}

public enum AgentHook {
    /// The request for a hook's input, or nil outside a Canopy terminal or for an event that maps to nothing.
    /// A relayed hook is dated by `CANOPY_STARTED_AT`, when it ran on the host, since this process started later.
    public static func request(input: Data, environment: [String: String], startedAt: Date?) -> AgentHookRequest? {
        guard let pane = environment["CANOPY_PANE"], !pane.isEmpty,
            let home = environment[CanopyHome.environmentKey], !home.isEmpty,
            let report = ClaudeHookMapping.report(
                from: input, startedAt: relayedStart(in: environment) ?? startedAt),
            let params = try? JSONValue.from(TermStateParams(pane: pane, report))
        else { return nil }
        return AgentHookRequest(
            socketPath: CanopyHome(path: home).socketPath,
            request: ControlRequest(method: TermMethod.state, params: params))
    }

    static func relayedStart(in environment: [String: String]) -> Date? {
        guard let seconds = environment["CANOPY_STARTED_AT"].flatMap(Double.init), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
