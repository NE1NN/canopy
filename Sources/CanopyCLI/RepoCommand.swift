import ArgumentParser
import CanopyCore

struct RepoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Register, clone, and list repositories.",
        subcommands: [Add.self, Clone.self, List.self, Remove.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register a repository. Any worktree of it works.")

        @Argument(help: "Path to the repository or one of its worktrees.")
        var path: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(ControlMethod.repoAdd, RepoAddParams(path: Client.absolutePath(path)))
            try client.print(result) {
                let repo = try result.decode(RepoInfo.self)
                return "Added \(repo.name) (\(repo.path))."
            }
        }
    }

    struct Clone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clone a repository and register it.",
            discussion: """
                owner/repo and GitHub URLs clone with gh, which uses your login and preferred protocol. \
                Other URLs clone with git, and so do GitHub URLs when gh is missing or logged out. \
                The clone goes in CANOPY_HOME/repos/<owner>/<name> unless --into names a folder. \
                A folder that already holds the repo is registered as it is.
                """
        )

        @Argument(help: "owner/repo, or a URL git can clone.")
        var source: String
        @Option(help: ArgumentHelp("The folder to clone into.", valueName: "dir"))
        var into: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let params = RepoCloneParams(
                source: Client.absolutePathIfRelative(source), into: into.map(Client.absolutePath))
            let result = client.call(ControlMethod.repoClone, params)
            try client.print(result) {
                let repo = try result.decode(RepoInfo.self)
                return "Added \(repo.name) (\(repo.path))."
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered repositories.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(ControlMethod.repoList, JSONValue.null)
            try client.print(result) {
                let repos = try result.decode([RepoInfo].self)
                return Table.render(
                    ["NAME", "ROWS", "OTHER", "PATH"],
                    repos.map {
                        [$0.name, "\($0.rows)", "\($0.external)", $0.missing ? "\($0.path) (missing)" : $0.path]
                    }
                )
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Unregister a repository. Files are not touched."
        )

        @Argument(help: "Repo name or path.")
        var repo: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.repoRemove,
                RepoRemoveParams(repo: Client.absolutePathIfRelative(repo))
            )
            try client.print(result) { "Removed \(try result.decode(RepoInfo.self).name) from Canopy." }
        }
    }
}
