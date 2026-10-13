import CanopyAgents
import CanopyWire
import Foundation

extension BoxDaemon {
    /// Applies an agent report to a pane, returning its state after, or nil for a pane the box does not have.
    @discardableResult
    public func report(pane id: String, _ report: AgentReport) -> AgentState? {
        guard let index = state.panes.firstIndex(where: { $0.id == id }) else { return nil }
        let before = state.panes[index].agent
        _ = state.panes[index].agent.apply(report, now: Date())
        if state.panes[index].agent != before {
            changed()
            wakeWaiters()
        }
        return state.panes[index].agent.state
    }

    func wakeWaiters() {
        for wake in waiters.values { wake() }
    }
}
