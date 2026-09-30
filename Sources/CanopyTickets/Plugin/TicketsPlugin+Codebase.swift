import CanopyCore
import Foundation

extension TicketsPlugin {
    /// Where config.json's `repo` is now: resolved at each write, so a repo moved or registered again is found.
    func codebase(_ context: PluginContext) async -> TicketCodebase {
        guard let name = TicketSettings.repo(in: await context.config) else { return .notSet }
        guard let repo = await context.repo(named: name) else { return .notRegistered(name: name) }
        if repo.isMissing { return .missing(name: repo.name, path: repo.path) }
        return .repo(name: repo.name, path: repo.path, defaultBranch: await context.defaultBranch(ofRepo: repo.path))
    }

    /// Writes AGENTS.md and CLAUDE.md into each row's folder, each only when it changes.
    func writeAgentFiles(into rows: [PluginRow], context: PluginContext) async {
        guard !rows.isEmpty else { return }
        let codebase = await codebase(context)
        for row in rows {
            _ = try? TicketAgentFiles.write(codebase, into: row.path)
        }
    }
}
