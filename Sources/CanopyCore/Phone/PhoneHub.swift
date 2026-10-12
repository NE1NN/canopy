import Foundation

/// Keeps phones' inboxes current. Agent changes and new snapshots send at once, after a short pause that gathers
/// changes made together, and a slow poll catches what has no event, such as the author seeing a done agent.
@MainActor
public final class PhoneHub {
    public typealias Send = @Sendable (PhoneInbox) -> Void

    private let terminals: TerminalStore
    private let updates: AsyncStream<WorkspaceSnapshot>
    private let pollInterval: Duration
    private let coalescing: Duration
    public private(set) var snapshot: WorkspaceSnapshot
    private var subscribers: [UUID: Subscriber] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var observer: UUID?
    private var pending: Task<Void, Never>?

    private struct Subscriber {
        var lastSent: PhoneInbox
        let send: Send
    }

    public init(
        terminals: TerminalStore, snapshot: WorkspaceSnapshot, updates: AsyncStream<WorkspaceSnapshot>,
        pollInterval: Duration = .seconds(2), coalescing: Duration = .milliseconds(100)
    ) {
        self.terminals = terminals
        self.snapshot = snapshot
        self.updates = updates
        self.pollInterval = pollInterval
        self.coalescing = coalescing
    }

    public func start() {
        guard observer == nil else { return }
        observer = terminals.observeAgents { [weak self] _ in self?.changed() }
        let updates = self.updates
        tasks.append(
            Task { [weak self] in
                for await snapshot in updates {
                    guard let self else { return }
                    self.snapshot = snapshot
                    self.changed()
                }
            })
        let interval = pollInterval
        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self else { return }
                    self.publish()
                }
            })
    }

    public func stop() {
        if let observer { terminals.stopObservingAgents(observer) }
        observer = nil
        for task in tasks { task.cancel() }
        tasks = []
        pending?.cancel()
        pending = nil
        subscribers = [:]
    }

    public var inbox: PhoneInbox {
        PhoneInboxBuilder.inbox(snapshot, terminals: terminals)
    }

    public var rows: PhoneRowsResult {
        PhoneInboxBuilder.rows(snapshot, terminals: terminals)
    }

    /// Sends the inbox to `send` each time it changes, starting now if it differs from `lastSent`. The subscription it
    /// replaces, if any, ends in the same step, so no change reaches both.
    public func subscribe(after lastSent: PhoneInbox, replacing previous: UUID? = nil, _ send: @escaping Send) -> UUID {
        if let previous { subscribers[previous] = nil }
        let id = UUID()
        subscribers[id] = Subscriber(lastSent: lastSent, send: send)
        changed()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func changed() {
        guard pending == nil, !subscribers.isEmpty else { return }
        let pause = coalescing
        pending = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            self?.publish()
        }
    }

    private func publish() {
        guard !subscribers.isEmpty else { return }
        let current = inbox
        for (id, subscriber) in subscribers where subscriber.lastSent != current {
            subscribers[id]?.lastSent = current
            subscriber.send(current)
        }
    }
}
