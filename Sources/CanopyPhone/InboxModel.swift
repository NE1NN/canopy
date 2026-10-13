import CanopyWire
import Foundation
import Observation

/// The Inbox: agents waiting for the author, and done agents not yet read.
@MainActor @Observable
public final class InboxModel {
    public let connection: MacConnection
    /// Panes whose answer is on its way.
    public private(set) var answering: Set<String> = []
    /// What went wrong with the last answer or mark read, until dismissed.
    public private(set) var notice: PhoneProblem?
    /// Done agents marked read here, by pane and when they finished, hidden until the Mac's inbox catches up.
    private var read: [String: Double] = [:]

    public init(connection: MacConnection) {
        self.connection = connection
    }

    private var inbox: PhoneInbox { connection.inbox ?? PhoneInbox() }

    public var sections: PhoneInbox.Sections {
        var sections = inbox.sections
        sections.done.removeAll { read[$0.agent.pane] == $0.agent.since }
        return sections
    }

    public var badgeCount: Int { sections.count }
    public var runningCount: Int { inbox.runningCount }
    public var hasInbox: Bool { connection.inbox != nil }

    /// The inbox is the last one the Mac sent before it went out of reach.
    public var isStale: Bool { connection.isUnreachable && connection.inbox != nil }
    public var asOf: Date? { connection.inboxAsOf }

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

    /// Marks a done agent read, here and on the Mac, as opening it does.
    public func markRead(_ item: PhoneInbox.Item) async {
        await markRead([item])
    }

    public func markAllRead() async {
        await markRead(sections.done)
    }

    private func markRead(_ items: [PhoneInbox.Item]) async {
        for item in items { read[item.agent.pane] = item.agent.since }
        do {
            let client = try connection.liveClient()
            for item in items {
                _ = try await client.call(
                    PhoneMethod.seen, PhonePaneParams(pane: item.agent.pane), as: PhonePaneParams.self)
            }
            notice = nil
        } catch {
            for item in items where read[item.agent.pane] == item.agent.since {
                read[item.agent.pane] = nil
            }
            notice = connection.problem(error)
        }
    }

    public func dismissNotice() {
        notice = nil
    }
}
