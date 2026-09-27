import ArgumentParser
import CanopyCore

struct PRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pr",
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
