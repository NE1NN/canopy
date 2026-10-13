import CanopyWire
import Foundation
import Observation

/// Every row, by host in pairing order, then by repo and plugin.
@MainActor @Observable
public final class RowsModel {
    /// One server's rows.
    public struct Host: Identifiable {
        public let server: ServerConnection
        public var sections: [PhoneRowsResult.Section]
        public var problem: PhoneProblem?
        public var isLoading: Bool

        public var id: String { server.id }
    }

    public let servers: Servers
    private var byServer: [String: ServerRows] = [:]
    private var isStarted = false
    private var starts = 0

    public init(servers: Servers) {
        self.servers = servers
    }

    public var hosts: [Host] {
        servers.paired.map { server in
            let rows = byServer[server.id]
            return Host(
                server: server, sections: rows?.sections ?? [], problem: rows?.problem,
                isLoading: rows?.isLoading ?? false)
        }
    }

    public var isLoading: Bool { byServer.values.contains(where: \.isLoading) }

    /// Fetches each server's rows on each of its connections, and for a server paired later once it is.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        starts += 1
        let start = starts
        observe(
            { [servers] in servers.paired.map(\.id) },
            while: { [weak self] in self?.isStarted == true && self?.starts == start }
        ) { [weak self] ids in
            self?.follow(ids)
        }
    }

    public func stop() {
        isStarted = false
        for rows in byServer.values { rows.stop() }
    }

    /// Makes rows for servers that have none, started while this is, and drops those of servers gone or forgotten.
    private func follow(_ ids: [String]) {
        for (id, rows) in byServer where !ids.contains(id) {
            rows.stop()
            byServer[id] = nil
        }
        for id in ids where byServer[id] == nil {
            guard let server = servers.connection(id: id) else { continue }
            byServer[id] = ServerRows(server: server, servers: servers)
        }
        if isStarted {
            for rows in byServer.values { rows.start() }
        }
    }

    public func refresh() async {
        follow(servers.paired.map(\.id))
        await withTaskGroup(of: Void.self) { group in
            for rows in byServer.values {
                group.addTask { await rows.refresh() }
            }
        }
    }
}

/// One server's rows by repo and plugin, with PRs from `phone.rows` and live agents from its inbox laid over them.
@MainActor @Observable
final class ServerRows {
    let server: ServerConnection
    private let servers: Servers
    private(set) var result: PhoneRowsResult?
    private(set) var isLoading = false
    private(set) var problem: PhoneProblem?
    private var isStarted = false
    /// Counts starts, so the observer of an earlier start ends rather than runs next to the new one.
    private var starts = 0

    init(server: ServerConnection, servers: Servers) {
        self.server = server
        self.servers = servers
    }

    /// The rows as the phone shows them: not the Mac's copies of a paired box's rows, and no section left empty by that.
    var sections: [PhoneRowsResult.Section] {
        guard let result else { return [] }
        let live = Dictionary(
            (server.inbox?.rows ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return result.sections.compactMap { section in
            var section = section
            section.rows = section.rows.filter { servers.shows($0, from: server) }.map { row in
                var row = row
                if let agents = live[row.path]?.agents { row.agents = agents }
                return row
            }
            return section.rows.isEmpty ? nil : section
        }
    }

    /// Fetches the rows on each connection, and again whenever the inbox gains or loses a row.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        starts += 1
        let start = starts
        observe(
            { [server] in
                RowsKey(generation: server.generation, paths: Set(server.inbox?.rows.map(\.path) ?? []))
            },
            while: { [weak self] in self?.isStarted == true && self?.starts == start }
        ) { [weak self] key in
            guard let self, server.isConnected, key.paths != self.paths || key.generation != fetchedGeneration
            else { return }
            Task { await self.refresh() }
        }
    }

    func stop() {
        isStarted = false
    }

    private var paths: Set<String> {
        Set(result?.sections.flatMap { $0.rows.map(\.path) } ?? [])
    }

    private var fetchedGeneration = 0
    /// Counts refreshes, so only the latest one's answer lands when several are on their way.
    private var refreshes = 0

    func refresh() async {
        refreshes += 1
        let refresh = refreshes
        isLoading = true
        defer { if refresh == refreshes { isLoading = false } }
        do {
            let generation = server.generation
            let rows = try await server.liveClient().call(PhoneMethod.rows, as: PhoneRowsResult.self)
            guard refresh == refreshes else { return }
            result = rows
            fetchedGeneration = generation
            problem = nil
        } catch {
            guard refresh == refreshes else { return }
            problem = server.problem(error)
        }
    }
}

private struct RowsKey: Equatable {
    var generation: Int
    var paths: Set<String>
}
