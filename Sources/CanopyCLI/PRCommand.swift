import ArgumentParser
import CanopyCore
import Foundation

struct PRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pr",
        abstract: "Show a row's pull request, or list the repo's.",
        subcommands: [Show.self, List.self],
        defaultSubcommand: Show.self
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a row's pull request.",
            discussion: """
                Canopy looks up PRs with your gh login for its own and adopted rows, about once a minute and more \
                often right after a push. --refresh asks GitHub now, for example right after gh pr create.
                """
        )

        @Argument(help: "Branch or path. Defaults to the row you are in.")
        var row: String?
        @Option(help: "Repo name or path, when the branch exists in several repos.")
        var repo: String?
        @Flag(help: "Ask GitHub now instead of using the last lookup.")
        var refresh = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.prShow, PRShowParams(target: Client.hint(repo: repo, row: row), refresh: refresh))
            try client.print(result) {
                let shown = try result.decode(PRShowResult.self)
                guard let pr = shown.pr else { return "\(shown.branch) has no pull request." }
                return "#\(pr.number) \(pr.state.rawValue): \(pr.title)\n\(pr.url)"
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the repo's open pull requests, most recently updated first.",
            discussion: """
                Lists the 100 most recently updated, asking GitHub with your gh login. --query keeps the PRs whose \
                number, title, head branch, or author holds each word, and a PR number, #number, or URL looks that PR \
                up even when it is closed. Each PR names the row or worktree that has its branch: show a row with \
                canopy row select, and start one on a PR that has none with canopy row new --pr <number>.
                """
        )

        @Option(help: "Only PRs whose number, title, head branch, or author holds each word, or one PR by number.")
        var query: String?
        @Flag(help: "Include closed and merged PRs.")
        var closed = false
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.prList, PRListParams(target: Client.hint(repo: repo), query: query, closed: closed))
            try client.print(result) {
                let listed = try result.decode([ListedPullRequest].self)
                guard !listed.isEmpty else {
                    return query == nil ? "No \(closed ? "" : "open ")pull requests." : "No pull requests match."
                }
                return Table.render(
                    ["PR", "STATE", "UPDATED", "AUTHOR", "HEAD", "ROW", "TITLE"],
                    listed.map { pr in
                        [
                            "#\(pr.number)", pr.state.rawValue, ShortAge.text(pr.updatedAt), pr.author ?? "-",
                            pr.headBranch + (pr.isFork ? " (fork)" : ""), Table.holder(pr.row, for: pr.headBranch),
                            pr.title,
                        ]
                    }
                )
            }
        }
    }
}
