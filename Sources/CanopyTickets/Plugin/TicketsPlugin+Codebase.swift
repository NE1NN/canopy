import CanopyCore
import Foundation

/// How config.json's `repo` finds its repo among the registered ones.
public enum TicketRepoLookup {
    /// The repos `saved` names: the one it names exactly, as `canopy row new --repo` finds it, or else those whose path
    /// ends in it. Display names grow a parent folder while two registered repos share a folder name, and lose it once
    /// only one is left, so `web-app` still finds `code/web-app`, and `code/web-app` still finds `web-app`.
    public static func matches(_ saved: String, among repos: [(name: String, path: String)]) -> [Int] {
        if let exact = repos.firstIndex(where: { TargetResolver.names(saved, repoNamed: $0.name, at: $0.path) }) {
            return [exact]
        }
        let suffix = "/" + saved
        return repos.indices.filter { repos[$0].path.hasSuffix(suffix) }
    }
}

extension TicketsPlugin {
    /// Where config.json's `repo` is now: resolved at each write, so a repo moved or registered again is found.
    func codebase(_ context: PluginContext) async -> TicketCodebase {
        guard let saved = TicketSettings.repo(in: await context.config) else { return .notSet }
        let repos = await context.repos()
        let found = TicketRepoLookup.matches(saved, among: repos.map { ($0.name, $0.path) })
        guard found.count < 2 else { return .ambiguous(name: saved, matches: found.map { repos[$0].name }) }
        guard let index = found.first else { return .notRegistered(name: saved) }
        let repo = repos[index]
        if repo.isMissing { return .missing(name: repo.name, path: repo.path) }
        return .repo(name: repo.name, path: repo.path, defaultBranch: await context.defaultBranch(ofRepo: repo.path))
    }

    /// Writes AGENTS.md and CLAUDE.md into each row's folder, each only when it changes. What it found is dropped if the
    /// plugin restarted or `repo` changed while it looked, since whatever changed it writes them again.
    func writeAgentFiles(into rows: [PluginRow], context: PluginContext) async {
        guard !rows.isEmpty else { return }
        let generation = self.generation
        let saved = TicketSettings.repo(in: await context.config)
        let codebase = await codebase(context)
        guard generation == self.generation, TicketSettings.repo(in: await context.config) == saved else { return }
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
        await writeAgentFiles(into: await context.state.rows, context: context)
        return await repoResult(context)
    }

    func repoResult(_ context: PluginContext) async -> TicketRepoResult {
        let registered = await context.repos().map(\.name)
        let saved = TicketSettings.repo(in: await context.config)
        switch await codebase(context) {
        case .notSet, .notRegistered:
            return TicketRepoResult(repo: saved, path: nil, defaultBranch: nil, registered: registered)
        case .ambiguous(_, let matches):
            return TicketRepoResult(
                repo: saved, path: nil, defaultBranch: nil, matches: matches, registered: registered)
        case .missing(_, let path):
            return TicketRepoResult(repo: saved, path: path, defaultBranch: nil, missing: true, registered: registered)
        case .repo(_, let path, let branch):
            return TicketRepoResult(repo: saved, path: path, defaultBranch: branch, registered: registered)
        }
    }

    /// The name of the registered repo a name or path names, as `canopy row new --repo` finds it.
    func registeredName(_ text: String, context: PluginContext) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let repo = await context.repo(named: text) { return repo.name }
        throw TicketError.repoNotFound(text, registered: await context.repos().map(\.name))
    }
}
