import Foundation

extension Workspace {
    /// Records a remote row the host now has: makes its stand-in folder, saves it with its repo, and places it at the
    /// end of `group` or of the ungrouped rows.
    func addRemoteRow(_ entry: RemoteRowEntry, repoPath: String, joining group: String? = nil) async throws {
        let index = try entryIndex(repoPath: repoPath)
        try entry.makeStandIn()
        state.repos[index].remote.removeAll { $0.standIn == entry.standIn }
        state.repos[index].remote.append(entry)
        state.repos[index].place(entry.standIn, joining: group)
        try save()
        await refresh(repoPath: repoPath)
    }

    public func remoteRow(standIn: String) -> RemoteRowEntry? {
        state.repos.lazy.flatMap(\.remote).first { $0.standIn == standIn }
    }

    public func remoteRow(host: String, path: String) -> RemoteRowEntry? {
        state.repos.lazy.flatMap(\.remote).first { $0.host == host && $0.path == path }
    }

    /// The repo's remote rows as the sidebar shows them.
    func remoteRows(of entry: RepoEntry) -> [Row] {
        entry.remote.map { Row(remote: $0, repoPath: entry.path) }
    }
}
