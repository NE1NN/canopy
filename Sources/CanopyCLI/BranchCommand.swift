import ArgumentParser
import CanopyCore
import Foundation

struct BranchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branch",
        abstract: "List a repo's branches.",
        subcommands: [List.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the repo's local and origin branches, newest commit first.",
            discussion: """
                Fetches origin first, so a branch pushed a moment ago is listed. --no-fetch lists what the repo \
                already has. Each branch says where it is (local, origin, or both), how the local branch compares \
                with origin's, and the row or worktree that has it checked out. Start a row on one with \
                canopy row new <branch> --existing.
                """
        )

        @Option(help: "Only branches whose name holds each word.")
        var query: String?
        @Flag(name: .customLong("no-fetch"), help: "List what the repo already has, without fetching origin.")
        var noFetch = false
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.branchList,
                BranchListParams(target: Client.hint(repo: repo), query: query, fetch: !noFetch))
            let listing = try result.decode(BranchListing.self)
            for warning in listing.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(try .from(listing.branches)) {
                guard !listing.branches.isEmpty else { return "No branches match." }
                return Table.render(
                    ["BRANCH", "WHERE", "COMMITTED", "ROW"],
                    listing.branches.map { branch in
                        [branch.name, branch.label, ShortAge.text(branch.committedAt), Table.holder(branch.row)]
                    }
                )
            }
        }
    }
}
