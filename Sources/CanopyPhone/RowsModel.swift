import CanopyWire
import Foundation
import Observation

/// Every row by repo and plugin, with PRs from `phone.rows` and live agents from the inbox laid over them.
@MainActor @Observable
public final class RowsModel {
    public let connection: MacConnection
    public private(set) var result: PhoneRowsResult?
    public private(set) var isLoading = false
    public private(set) var problem: PhoneProblem?
    private var isStarted = false
    /// Counts starts, so the observer of an earlier start ends rather than runs next to the new one.
    private var starts = 0

    public init(connection: MacConnection) {
        self.connection = connection
    }

    public var sections: [PhoneRowsResult.Section] {
        guard let result else { return [] }
        let live = Dictionary(
            (connection.inbox?.rows ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return result.sections.map { section in
            var section = section
            section.rows = section.rows.map { row in
                var row = row
                if let agents = live[row.path]?.agents { row.agents = agents }
                return row
            }
            return section
        }
    }

    /// Fetches the rows on each connection, and again whenever the inbox gains or loses a row.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        starts += 1
        let start = starts
        observe(
            { [connection] in
                RowsKey(generation: connection.generation, paths: Set(connection.inbox?.rows.map(\.path) ?? []))
            },
            while: { [weak self] in self?.isStarted == true && self?.starts == start }
        ) { [weak self] key in
            guard let self, connection.isConnected, key.paths != self.paths || key.generation != fetchedGeneration
            else { return }
            Task { await self.refresh() }
        }
    }

    public func stop() {
        isStarted = false
    }

    private var paths: Set<String> {
        Set(result?.sections.flatMap { $0.rows.map(\.path) } ?? [])
    }

    private var fetchedGeneration = 0
    /// Counts refreshes, so only the latest one's answer lands when several are on their way.
    private var refreshes = 0

    public func refresh() async {
        refreshes += 1
        let refresh = refreshes
        isLoading = true
        defer { if refresh == refreshes { isLoading = false } }
        do {
            let generation = connection.generation
            let rows = try await connection.liveClient().call(PhoneMethod.rows, as: PhoneRowsResult.self)
            guard refresh == refreshes else { return }
            result = rows
            fetchedGeneration = generation
            problem = nil
        } catch {
            guard refresh == refreshes else { return }
            problem = connection.problem(error)
        }
    }
}

private struct RowsKey: Equatable {
    var generation: Int
    var paths: Set<String>
}
