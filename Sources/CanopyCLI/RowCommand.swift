import ArgumentParser
import CanopyCore
import Foundation

struct RowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "row",
        abstract: "Create, remove, and list rows (worktrees).",
        subcommands: [List.self, New.self, Remove.self, Select.self, Adopt.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List rows in every repo, or in one.")

        @Option(help: "Only this repo (name or path).")
        var repo: String?
        @Flag(help: "Include worktrees made by other tools.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.rowList,
                RowListParams(repo: repo.map(Client.absolutePathIfRelative), all: all)
            )
            try client.print(result) {
                let rows = try result.decode([Row].self)
                return Table.render(
                    ["BRANCH", "CLASS", "PATH"],
                    rows.map { row in
                        let rowClass = row.externalTag.map { "\(row.rowClass.rawValue):\($0.rawValue)" }
                        return [row.displayName, rowClass ?? row.rowClass.rawValue, row.path]
                    }
                )
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a row: a branch and a worktree under the Canopy folder.",
            discussion: """
                An existing local branch is checked out, after a fast-forward if it is only behind origin. A branch \
                that only exists on origin is tracked. Anything else is created from --from, which defaults to \
                origin's default branch, unless --existing asks to fail instead. A branch with commits of its own \
                is never reset.

                --pr checks out a pull request's branch, including one from a fork, named and tracked the way \
                gh pr checkout does it.

                The repo's setup commands from .canopy/config.json then run in the row's Setup tab, and this \
                waits for them. If setup fails, the row stays, --run is skipped, and this exits 1.
                """
        )

        @Argument(help: "Branch name, for example feat/login.")
        var branch: String?
        @Option(help: "Start from a pull request: its number, #number, or URL.")
        var pr: String?
        @Option(name: .customLong("branch"), help: ArgumentHelp("With --pr, the local branch name.", valueName: "name"))
        var localBranch: String?
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @Option(name: .customLong("from"), help: "Start point for a new branch.")
        var base: String?
        @Flag(help: "Fail instead of creating a branch that is neither local nor on origin.")
        var existing = false
        @Option(name: .customLong("run"), help: "Command to type into a new terminal once setup succeeds.")
        var command: String?
        @Flag(name: .customLong("no-setup"), help: "Skip the repo's setup commands.")
        var noSetup = false
        @Flag(help: "Switch the Canopy window to the new row.")
        var select = false
        @OptionGroup var output: OutputOptions

        func validate() throws {
            guard pr != nil else {
                if branch == nil { throw ValidationError("Pass a branch name, or --pr.") }
                if localBranch != nil {
                    throw ValidationError("--branch is only for --pr. Pass the branch as the argument.")
                }
                if existing, base != nil {
                    throw ValidationError("--from only applies to new branches, and --existing never creates one.")
                }
                return
            }
            if branch != nil {
                throw ValidationError(
                    "--pr cannot be used with a branch argument. Name the local branch with --branch.")
            }
            if base != nil { throw ValidationError("--from only applies to new branches, and --pr uses the PR's.") }
            if existing { throw ValidationError("--existing is for a branch name. --pr always uses the PR's branch.") }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.rowNew,
                RowNewParams(
                    target: Client.hint(repo: repo), branch: branch ?? localBranch, pr: pr, base: base,
                    existing: existing, select: select, setup: !noSetup, run: command)
            )
            let created = try result.decode(RowNewResult.self)
            for warning in created.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(result) { summary(of: created) }
            if created.setup.status == .failed {
                fflush(stdout)
                FileHandle.standardError.write(Data("error: \(created.setup.message ?? "Setup failed.")\n".utf8))
                throw ExitCode(1)
            }
        }

        private func summary(of created: RowNewResult) -> String {
            let name = created.row.displayName
            let path = created.row.path
            var lines: [String]
            if let pr = created.pr {
                lines = ["Checked out PR #\(pr.number) as \(name) in \(path).", "\(pr.title): \(pr.url)"]
            } else {
                switch created.source {
                case .local: lines = ["Checked out \(name) in \(path)."]
                case .origin: lines = ["Checked out \(name), tracking origin/\(name), in \(path)."]
                case .new: lines = ["Created new branch \(name) from \(created.base ?? "HEAD") in \(path)."]
                }
            }
            lines += created.notes
            switch created.setup.status {
            case .succeeded: lines.append("Setup finished.")
            case .skipped: lines.append("Skipped setup.")
            case .none, .failed: break
            }
            if let pane = created.pane, let command {
                lines.append("Running \(command) in \(pane).")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a row's worktree, or hide an adopted row.",
            discussion: """
                The repo's teardown commands from .canopy/config.json run first in the row's Teardown tab, \
                then the row's terminals close and the worktree is removed.
                """
        )

        @Argument(help: "Branch or path. Defaults to the row you are in.")
        var row: String?
        @Option(help: "Repo name or path, when the branch exists in several repos.")
        var repo: String?
        @Flag(help: "Remove even with uncommitted changes or a failing teardown.")
        var force = false
        @Flag(help: "Also delete the branch.")
        var deleteBranch = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.rowRemove,
                RowRemoveParams(target: Client.hint(repo: repo, row: row), force: force, deleteBranch: deleteBranch)
            )
            let removed = try result.decode(RowRemoveResult.self)
            for warning in removed.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(result) { "Removed \(removed.row.displayName)." }
        }
    }

    struct Select: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a row in the Canopy window.")

        @Argument(help: "Branch or path. Defaults to the row you are in.")
        var row: String?
        @Option(help: "Repo name or path, when the branch exists in several repos.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ControlMethod.rowSelect, RowRefParams(target: Client.hint(repo: repo, row: row)))
            try client.print(result) { "Selected \(try result.decode(Row.self).displayName)." }
        }
    }

    struct Adopt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a worktree made by another tool as a regular row."
        )

        @Argument(help: "Path to the worktree.")
        var path: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(ControlMethod.rowAdopt, RowAdoptParams(path: Client.absolutePath(path)))
            try client.print(result) { "Adopted \(try result.decode(Row.self).displayName)." }
        }
    }
}
