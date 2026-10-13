import Foundation
import Synchronization

/// The conversations and screens each connection follows, by the request that started them, so `phone.unsubscribe`
/// and closing the connection stop them.
final class PhoneStreams: Sendable {
    /// More than a phone has open at once, so a phone that never unsubscribes cannot pile them up.
    static let limit = 16

    private let streams = Mutex<[ObjectIdentifier: [String: @Sendable () -> Void]]>([:])

    /// Refuses a new stream on a connection that has as many as it may.
    func reserve(on session: PhoneSession) throws {
        let count = streams.withLock { $0[session.connectionID]?.count ?? 0 }
        guard count < Self.limit else {
            throw ControlError(
                code: "too_many_streams", message: "Unsubscribe from a conversation or screen before opening another.")
        }
    }

    func add(_ id: String, on session: PhoneSession, cancel: @escaping @Sendable () -> Void) {
        let connection = session.connectionID
        let (first, replaced) = streams.withLock { streams in
            let first = streams[connection] == nil
            let replaced = streams[connection, default: [:]].updateValue(cancel, forKey: id)
            return (first, replaced)
        }
        replaced?()
        guard first else { return }
        session.onClose { [weak self] in
            let all = self?.streams.withLock { $0.removeValue(forKey: connection) } ?? [:]
            for cancel in all.values { cancel() }
        }
    }

    func remove(_ id: String, on session: PhoneSession) {
        let cancel = streams.withLock { $0[session.connectionID]?.removeValue(forKey: id) }
        cancel?()
    }
}

/// Sends a pane's screen whenever it changes, four times a second at most, while a phone shows it.
@MainActor
final class ScreenWatcher {
    private let panes: PhonePanes
    private let pane: String
    private var last: [String]
    private let send: @Sendable (PhoneScreen) -> Void
    private var task: Task<Void, Never>?

    init(panes: PhonePanes, pane: String, after lines: [String], send: @escaping @Sendable (PhoneScreen) -> Void) {
        self.panes = panes
        self.pane = pane
        last = lines
        self.send = send
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.check() else { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Returns false once the pane is gone.
    private func check() -> Bool {
        guard let screen = try? panes.screen(PhonePaneParams(pane: pane), scrollback: nil) else { return false }
        guard screen.lines != last else { return true }
        last = screen.lines
        send(screen)
        return true
    }
}
