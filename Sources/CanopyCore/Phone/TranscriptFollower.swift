import Foundation
import Synchronization

/// Follows a pane's conversation while a phone has it open. It checks the transcript's size a few times a second, which
/// also notices the pane moving to another session's file, and sends the entries that are new or changed since the
/// last it sent, so a folded group of tool calls is sent again as it grows.
public final class TranscriptFollower: Sendable {
    /// How many of the newest entries are compared each time the file grows.
    static let window = 100
    /// How far back each check reads, so a few huge tool results cannot make every check parse megabytes.
    static let maxSpan = 1 << 20

    private let pane: String
    private let path: @Sendable () async -> String?
    private let interval: Duration
    private let send: @Sendable (PhoneTranscriptUpdate) -> Void
    private let state: Mutex<State>
    private let task = Mutex<Task<Void, Never>?>(nil)

    private struct State {
        var path: String
        var size: Int?
        var sent: [String: TranscriptEntry]
        var stopped = false
    }

    /// `sent` is what the phone already has, from the page of `following` that started it. `path` says where the pane's
    /// transcript is now.
    public init(
        pane: String, following: String, path: @escaping @Sendable () async -> String?, sent: [TranscriptEntry],
        interval: Duration = .milliseconds(300), send: @escaping @Sendable (PhoneTranscriptUpdate) -> Void
    ) {
        self.pane = pane
        self.path = path
        self.interval = interval
        self.send = send
        state = Mutex(
            State(path: following, sent: Dictionary(sent.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })))
    }

    public var isStopped: Bool { state.withLock { $0.stopped } }

    public func start() {
        let interval = interval
        task.withLock { task in
            task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, await self.check() else { return }
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func stop() {
        state.withLock { $0.stopped = true }
        task.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    /// Sends what changed. Returns false once there is nothing left to follow.
    private func check() async -> Bool {
        guard let current = await path() else {
            state.withLock { $0.stopped = true }
            return false
        }
        let url = URL(fileURLWithPath: current)
        let size = (try? FileManager.default.attributesOfItem(atPath: current)[.size] as? Int) ?? nil
        let (moved, unchanged) = state.withLock { state -> (Bool, Bool) in
            let moved = state.path != current
            return (moved, !moved && state.size == size && size != nil)
        }
        if unchanged { return true }
        guard let page = try? TranscriptReader.page(of: url, before: nil, limit: Self.window, maxSpan: Self.maxSpan)
        else {
            state.withLock { $0.size = size }
            return true
        }
        let update = state.withLock { state -> PhoneTranscriptUpdate? in
            guard !state.stopped else { return nil }
            state.size = size
            if moved {
                state.path = current
                state.sent = Dictionary(page.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                let first = (try? TranscriptReader.page(of: url, before: nil, limit: 50)) ?? page
                return PhoneTranscriptUpdate(pane: pane, entries: first.entries, reset: true, older: first.older)
            }
            // Entries before the newest the phone has are older pages', which the phone asks for itself, except those it
            // has that changed, such as a group whose call failed after a later group was sent.
            let newest = page.entries.lastIndex { state.sent[$0.id] != nil } ?? page.entries.startIndex
            let changed = page.entries.enumerated().filter { index, entry in
                let held = state.sent[entry.id]
                return held != entry && (index >= newest || held != nil)
            }.map(\.element)
            for entry in changed { state.sent[entry.id] = entry }
            return changed.isEmpty ? nil : PhoneTranscriptUpdate(pane: pane, entries: changed)
        }
        if let update { send(update) }
        return true
    }
}
