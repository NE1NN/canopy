import CanopyWire
import Foundation
import Observation

/// The home screen: pinned rows, then what needs the author, what finished, and what still runs.
@MainActor @Observable
public final class InboxModel {
    public let connection: MacConnection
    public let pins: PinStore
    /// Panes whose answer is on its way.
    public private(set) var answering: Set<String> = []
    /// What went wrong with the last answer, until dismissed.
    public private(set) var notice: PhoneProblem?
    private var isStarted = false

    public init(connection: MacConnection, pins: PinStore) {
        self.connection = connection
        self.pins = pins
    }

    /// Takes the first launch's pins from the first inbox that has any.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        observe(
            { [connection] in connection.inbox?.defaultPins ?? [] }, while: { [weak self] in self?.isStarted == true }
        ) {
            [pins] defaults in pins.adoptDefaults(defaults)
        }
    }

    public func stop() {
        isStarted = false
    }

    private var inbox: PhoneInbox { connection.inbox ?? PhoneInbox() }

    public var sections: PhoneInbox.Sections { inbox.sections(pinned: pins.pins) }
    public var waitingCount: Int { inbox.waitingCount }
    public var agentCount: Int { inbox.agentCount }
    public var hasInbox: Bool { connection.inbox != nil }

    /// The inbox is the last one the Mac sent before it went out of reach.
    public var isStale: Bool { connection.isUnreachable && connection.inbox != nil }
    public var asOf: Date? { connection.inboxAsOf }

    public func isPinned(_ row: PhoneRow) -> Bool { pins.pins.contains(row.path) }

    public func togglePin(_ row: PhoneRow) {
        pins.toggle(row.path)
    }

    /// The small label after a row's name: its plugin's item, or its repo when the inbox spans several.
    public func label(for row: PhoneRow) -> String? {
        if let plugin = row.plugin { return plugin }
        let repos = Set(inbox.rows.compactMap(\.repo))
        return repos.count > 1 ? row.repo : nil
    }

    /// Allow or Deny for a permission prompt, straight from the list.
    public func answer(_ item: PhoneInbox.Item, allow: Bool) async {
        guard let prompt = item.agent.prompt else { return }
        let pane = item.agent.pane
        answering.insert(pane)
        defer { answering.remove(pane) }
        do {
            _ = try await connection.liveClient().call(
                PhoneMethod.answer, PhoneAnswerParams(pane: pane, prompt: prompt.id, answer: PhoneAnswer(allow: allow)),
                as: PhonePaneParams.self)
            notice = nil
        } catch {
            notice = connection.problem(error)
        }
    }

    public func dismissNotice() {
        notice = nil
    }
}
