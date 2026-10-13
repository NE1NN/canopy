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
    /// What an empty Inbox says. Out of reach, the phone only knows what was true when the Mac last answered.
    public var caughtUpDetail: String {
        if isStale {
            guard let asOf else { return "Nothing was waiting when the Mac last answered." }
            return "Nothing was waiting as of \(asOf.formatted(date: .omitted, time: .shortened))."
        }
        let waiting = "Nothing is waiting for you."
        switch runningCount {
        case 0: return waiting
        case 1: return waiting + "\n1 agent is running."
        default: return waiting + "\n\(runningCount) agents are running."
        }
    }
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

    /// Each item is read once the Mac takes it, so one that fails comes back alone.
    private func markRead(_ items: [PhoneInbox.Item]) async {
        for item in items { read[item.agent.pane] = item.agent.since }
        let client: PhoneClient
        do {
            client = try connection.liveClient()
        } catch {
            unread(items)
            notice = connection.problem(error)
            return
        }
        var problem: PhoneProblem?
        for item in items {
            do {
                _ = try await client.call(
                    PhoneMethod.seen, PhonePaneParams(pane: item.agent.pane), as: PhonePaneParams.self)
            } catch let error as ControlError where error.code == "pane_not_found" {
                // The pane closed, so its agent leaves the inbox anyway.
            } catch {
                unread([item])
                problem = connection.problem(error)
            }
        }
        notice = problem
    }

    private func unread(_ items: [PhoneInbox.Item]) {
        for item in items where read[item.agent.pane] == item.agent.since {
            read[item.agent.pane] = nil
        }
    }

    public func dismissNotice() {
        notice = nil
    }
}
