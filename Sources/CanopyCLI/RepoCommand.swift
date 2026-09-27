import ArgumentParser
import CanopyCore

struct RepoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Register and list repositories.",
        subcommands: [Add.self, List.self, Remove.self]
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
