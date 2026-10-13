import CanopyWire
import Foundation
import Observation

/// A pane by its server, since pane ids are only unique on the server that made them.
public struct PaneRef: Hashable, Sendable {
    public var server: String
    public var pane: String

    public init(server: String, pane: String) {
        self.server = server
        self.pane = pane
    }
}

/// An agent in the Inbox, with its row and the server it runs on.
public struct InboxItem: Identifiable, Equatable {
    public let server: ServerConnection
    public var row: PhoneRow
    public var agent: PhoneAgent

    public init(server: ServerConnection, row: PhoneRow, agent: PhoneAgent) {
        self.server = server
        self.row = row
        self.agent = agent
    }

    public var ref: PaneRef { PaneRef(server: server.id, pane: agent.pane) }
    public var id: PaneRef { ref }

    public static func == (lhs: InboxItem, rhs: InboxItem) -> Bool {
        lhs.server.id == rhs.server.id && lhs.row == rhs.row && lhs.agent == rhs.agent
    }
}

/// The Inbox: agents waiting for the author, and done agents not yet read, from every server.
@MainActor @Observable
public final class InboxModel {
    public struct Sections: Equatable {
        /// Waiting agents, the longest waiting first.
        public var needsYou: [InboxItem] = []
        /// Done agents not yet seen, the newest first.
        public var done: [InboxItem] = []

        /// What the tab's badge counts.
        public var count: Int { needsYou.count + done.count }
        public var isEmpty: Bool { count == 0 }
    }

    public let servers: Servers
    /// Panes whose answer is on its way.
    public private(set) var answering: Set<PaneRef> = []
    /// What went wrong with the last answer or mark read, until dismissed.
    public private(set) var notice: PhoneProblem?
    /// Done agents marked read here, by pane and when they finished, hidden until their server's inbox catches up.
    private var read: [PaneRef: Double] = [:]

    public init(servers: Servers) {
        self.servers = servers
    }

    /// Each paired server's rows as the Inbox shows them, in pairing order.
    private var shown: [(server: ServerConnection, rows: [PhoneRow])] {
        servers.paired.map { server in
            (server, (server.inbox?.rows ?? []).filter { servers.shows($0, from: server) })
        }
    }

    /// Each server's agents in order, with their server's place and their own, so equal times keep that order.
    private var items: [(item: InboxItem, order: (Int, Int))] {
        shown.enumerated().flatMap { place, shown in
            shown.rows.flatMap { row in row.agents.map { (row, $0) } }.enumerated().map { offset, pair in
                (InboxItem(server: shown.server, row: pair.0, agent: pair.1), (place, offset))
            }
        }
    }

    public var sections: Sections {
        let items = items
        let waiting = items.filter { $0.item.agent.state == .waiting }
            .sorted { ($0.item.agent.since, $0.order.0, $0.order.1) < ($1.item.agent.since, $1.order.0, $1.order.1) }
        let done = items.filter {
            $0.item.agent.state == .done && $0.item.agent.unseen && read[$0.item.ref] != $0.item.agent.since
        }
        .sorted { ($1.item.agent.since, $0.order.0, $0.order.1) < ($0.item.agent.since, $1.order.0, $1.order.1) }
        return Sections(needsYou: waiting.map(\.item), done: done.map(\.item))
    }

    public var badgeCount: Int { sections.count }

    public var runningCount: Int {
        shown.flatMap(\.rows).flatMap(\.agents).filter { $0.state == .working || $0.state == .background }.count
    }

    /// The servers out of reach whose last inbox still shows, in pairing order.
    public var staleServers: [ServerConnection] {
        servers.paired.filter { $0.isUnreachable && $0.inbox != nil }
    }

    /// Every server is out of reach, so the Inbox only knows what was true when each last answered.
    public var isStale: Bool {
        let paired = servers.paired
        return !paired.isEmpty && paired.allSatisfy(\.isUnreachable) && paired.contains { $0.inbox != nil }
    }

    /// The oldest of the out of reach servers' last answers, which the whole Inbox is as of.
    public var asOf: Date? { staleServers.compactMap(\.inboxAsOf).min() }

    /// What an empty Inbox says. Out of reach, the phone only knows what was true when the servers last answered.
    public var caughtUpDetail: String {
        if isStale {
            guard let asOf else { return "Nothing was waiting when they last answered." }
            return "Nothing was waiting as of \(asOf.formatted(date: .omitted, time: .shortened))."
        }
        let waiting = "Nothing is waiting for you."
        switch runningCount {
        case 0: return waiting
        case 1: return waiting + "\n1 agent is running."
        default: return waiting + "\n\(runningCount) agents are running."
        }
    }

    public var hasInbox: Bool { servers.paired.contains { $0.inbox != nil } }

    /// The line above the Inbox, on how the servers are: connected, connecting, or which are out of reach.
    public struct ConnectionLine: Equatable, Sendable {
        public enum State: Sendable { case connected, connecting, unreachable }
        public var state: State
        public var text: String
    }

    public var connectionLine: ConnectionLine {
        let paired = servers.paired
        let unreachable = paired.filter(\.isUnreachable)
        if !unreachable.isEmpty {
            if unreachable.count == paired.count, let asOf {
                return ConnectionLine(
                    state: .unreachable, text: "As of \(asOf.formatted(date: .omitted, time: .shortened))")
            }
            return ConnectionLine(state: .unreachable, text: "Can't reach \(Self.names(unreachable))")
        }
        let connecting = paired.filter { !$0.isConnected }
        if !connecting.isEmpty {
            return ConnectionLine(state: .connecting, text: "Connecting to \(Self.names(connecting))")
        }
        return ConnectionLine(state: .connected, text: "\(Self.names(paired)) connected")
    }

    /// Names up to two servers, and counts more, to fit on one line.
    private static func names(_ servers: [ServerConnection]) -> String {
        servers.count > 2 ? "\(servers.count) servers" : Servers.names(servers)
    }

    /// One banner for the servers out of reach: the server's own problem, or for several, their names. Servers in
    /// `apart` have a card of their own, as a box the phone can wake does.
    public func staleBanner(apart: Set<String> = []) -> PhoneProblem? {
        let stale = staleServers.filter { !apart.contains($0.id) }
        if stale.count == 1, case .unreachable(let problem) = stale[0].status { return problem }
        guard stale.count > 1 else { return nil }
        return PhoneProblem(title: "Can't reach \(Servers.names(stale)).", detail: PhoneProblem.checkTailscale)
    }

    /// The small label after a row's name: its plugin's item, or its repo when the inbox spans several.
    public func label(for row: PhoneRow) -> String? {
        if let plugin = row.plugin { return plugin }
        let repos = Set(shown.flatMap(\.rows).compactMap(\.repo))
        return repos.count > 1 ? row.repo : nil
    }

    /// Allow or Deny for a permission prompt, straight from the list.
    public func answer(_ item: InboxItem, allow: Bool) async {
        guard let prompt = item.agent.prompt else { return }
        let ref = item.ref
        answering.insert(ref)
        defer { answering.remove(ref) }
        do {
            _ = try await item.server.liveClient().call(
                PhoneMethod.answer,
                PhoneAnswerParams(pane: item.agent.pane, prompt: prompt.id, answer: PhoneAnswer(allow: allow)),
                as: PhonePaneParams.self)
            notice = nil
        } catch {
            notice = item.server.problem(error)
        }
    }

    /// Marks a done agent read, here and on its server, as opening it does.
    public func markRead(_ item: InboxItem) async {
        await markRead([item])
    }

    /// Every done item from a server in reach. One out of reach could not take them.
    public func markAllRead() async {
        await markRead(sections.done.filter { !$0.server.isUnreachable })
    }

    /// Each item is read once its server takes it, so one that fails comes back alone.
    private func markRead(_ items: [InboxItem]) async {
        for item in items { read[item.ref] = item.agent.since }
        var problem: PhoneProblem?
        for server in servers.paired {
            let theirs = items.filter { $0.server.id == server.id }
            guard !theirs.isEmpty else { continue }
            let client: PhoneClient
            do {
                client = try server.liveClient()
            } catch {
                unread(theirs)
                problem = server.problem(error)
                continue
            }
            for item in theirs {
                do {
                    _ = try await client.call(
                        PhoneMethod.seen, PhonePaneParams(pane: item.agent.pane), as: PhonePaneParams.self)
                } catch let error as ControlError where error.code == "pane_not_found" {
                    // The pane closed, so its agent leaves the inbox anyway.
                } catch {
                    unread([item])
                    problem = server.problem(error)
                }
            }
        }
        notice = problem
    }

    private func unread(_ items: [InboxItem]) {
        for item in items where read[item.ref] == item.agent.since {
            read[item.ref] = nil
        }
    }

    public func dismissNotice() {
        notice = nil
    }
}
