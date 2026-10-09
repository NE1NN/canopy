import Foundation

/// What the author has in front of them, which decides the panes they have seen and the one they are focused on.
public struct AgentViewing: Sendable, Equatable {
    /// The selected row.
    public var rowPath: String?
    /// Canopy is the active app and its window is visible.
    public var isFrontmost: Bool

    public init(rowPath: String? = nil, isFrontmost: Bool = false) {
        self.rowPath = rowPath
        self.isFrontmost = isFrontmost
    }
}

/// Which states `canopy term wait` waits for.
public enum AgentWaitTarget: String, Codable, Sendable, CaseIterable {
    case done
    case waiting
    /// A turn that ended with background work still running.
    case background
    /// Done or waiting. Coordinators wait on a row to learn it finished, and a background row has not.
    case any
    /// Done, waiting, or background: the turn is over, whatever it left running.
    case ended

    public func matches(_ state: AgentState) -> Bool {
        switch self {
        case .done: state == .done
        case .waiting: state == .waiting
        case .background: state == .background
        case .any: state == .done || state == .waiting
        case .ended: state == .done || state == .waiting || state == .background
        }
    }

    var label: String {
        switch self {
        case .any: "done or waiting"
        case .ended: "done, waiting, or background"
        default: rawValue
        }
    }
}

public enum AgentEvent {
    case changed(Pane, AgentChange)
    /// Sent before the pane's agent state clears.
    case closed(Pane)
}

extension TerminalTab {
    /// The most urgent of its panes' dots.
    public var agentDot: AgentDot? {
        paneList.compactMap(\.agent.dot).max()
    }

    /// What its background panes wait on.
    public var backgroundTasks: [String] {
        paneList.flatMap(\.agent.backgroundTasks)
    }
}

extension TerminalStore {
    /// The most urgent dot among the row's panes, in every tab.
    public func agentDot(inRow path: String) -> AgentDot? {
        tabs(inRow: path).compactMap(\.agentDot).max()
    }

    /// The most urgent dot among several rows' panes, for a collapsed group.
    public func agentDot(inRows paths: [String]) -> AgentDot? {
        paths.compactMap(agentDot(inRow:)).max()
    }

    /// What the row's background panes wait on, in every tab.
    public func backgroundTasks(inRow path: String) -> [String] {
        tabs(inRow: path).flatMap(\.backgroundTasks)
    }

    /// What several rows' background panes wait on, for a collapsed group.
    public func backgroundTasks(inRows paths: [String]) -> [String] {
        paths.flatMap(backgroundTasks(inRow:))
    }

    /// Whether the author sees the pane: Canopy is frontmost, and the pane is in the selected row's selected tab.
    public func isOnScreen(_ pane: Pane) -> Bool {
        guard viewing.isFrontmost, let (path, tab) = tab(containing: pane.id), path == viewing.rowPath else {
            return false
        }
        return selectedTab(inRow: path)?.id == tab.id
    }

    /// Whether the pane on screen is the one the author is focused on.
    public func isFocused(_ pane: Pane) -> Bool {
        isOnScreen(pane) && tab(containing: pane.id)?.1.grid?.focusedPaneID == pane.id
    }

    /// Clears the green of every pane the author now sees.
    func markSeenOnScreen() {
        guard viewing.isFrontmost, let path = viewing.rowPath, let tab = selectedTab(inRow: path) else { return }
        for pane in tab.paneList {
            pane.markSeen()
        }
    }

    func agentChanged(_ pane: Pane, _ change: AgentChange) {
        if change.to == .done, isOnScreen(pane) {
            pane.markSeen()
        }
        if change.alerts, !isFocused(pane) {
            onAgentAlert(pane, change.to)
        }
        notifyAgentObservers(.changed(pane, change))
    }

    /// Waits until one of the panes reaches the state, and returns the first that does, in the order given.
    /// A pane already there counts at once, unless it got input since.
    public func waitForAgents(_ ids: [PaneID], for target: AgentWaitTarget, timeout: Duration) async throws -> (
        Pane, AgentState
    ) {
        let panes = try ids.map { id in
            guard let pane = pane(id) else { throw WorkspaceError.paneNotFound(id.description) }
            return pane
        }
        if let ready = panes.first(where: { target.matches($0.agent.state) && $0.agentIsFresh }) {
            return (ready, ready.agent.state)
        }
        let watched = Set(ids)
        let wait = AgentWait()
        let observer = observeAgents { event in
            switch event {
            case .changed(let pane, let change) where watched.contains(pane.id):
                if target.matches(change.to) {
                    wait.finish(.success((pane, change.to)))
                } else if change.to == .none {
                    wait.finish(.failure(WorkspaceError.agentStopped(pane.id.description)))
                }
            case .closed(let pane) where watched.contains(pane.id):
                wait.finish(.failure(WorkspaceError.paneClosed(pane.id.description)))
            default:
                break
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            wait.finish(.failure(WorkspaceError.waitTimeout(ids.map(\.description), target.label)))
        }
        defer {
            stopObservingAgents(observer)
            timer.cancel()
        }
        // A client that goes away cancels the request, which ends the wait rather than leaving it to its timeout.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { wait.start($0) }
        } onCancel: {
            Task { @MainActor in wait.finish(.failure(CancellationError())) }
        }
    }
}

/// One `waitForAgents` call, which the first of an event and its timeout finishes.
@MainActor
private final class AgentWait {
    private var continuation: CheckedContinuation<(Pane, AgentState), any Error>?
    private var result: Result<(Pane, AgentState), any Error>?

    func start(_ continuation: CheckedContinuation<(Pane, AgentState), any Error>) {
        if let result {
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<(Pane, AgentState), any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
