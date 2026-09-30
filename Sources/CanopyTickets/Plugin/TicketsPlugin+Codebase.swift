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

extension TicketsPlugin {
    /// Saves the repo's name as config.json's `repo`, or takes it out, and rewrites every row's agent files. The plugin
    /// keeps running, so panels and refreshes carry on.
    func setRepo(_ params: TicketSetRepoParams, context: PluginContext) async throws -> TicketRepoResult {
        guard await context.state.isOn else { throw TicketError.off(url: Self.configuredURL(await context.config)) }
        var name: String?
        if let repo = params.repo { name = try await registeredName(repo, context: context) }
        try await context.setConfig("repo", to: name.map(JSONValue.string))
        connection?.settings.repo = name
        await writeAgentFiles(into: await context.state.rows, context: context)
        return await repoResult(context)
    }

    func repoResult(_ context: PluginContext) async -> TicketRepoResult {
        let registered = await context.repos().map(\.name)
        let name = TicketSettings.repo(in: await context.config)
        switch await codebase(context) {
        case .notSet, .notRegistered:
            return TicketRepoResult(repo: name, path: nil, defaultBranch: nil, registered: registered)
        case .missing(let name, let path):
            return TicketRepoResult(repo: name, path: path, defaultBranch: nil, missing: true, registered: registered)
        case .repo(let name, let path, let branch):
            return TicketRepoResult(repo: name, path: path, defaultBranch: branch, registered: registered)
        }
    }

    /// The name of the registered repo a name or path names, as `canopy row new --repo` finds it.
    func registeredName(_ text: String, context: PluginContext) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let repo = await context.repo(named: text) { return repo.name }
        throw TicketError.repoNotFound(text, registered: await context.repos().map(\.name))
    }
}
