import ArgumentParser
import CanopyCore
import Foundation

struct GroupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        abstract: "Gather a repo's rows into named groups that fold away in the sidebar.",
        discussion: """
            A group belongs to one repo and only arranges the sidebar: deleting one never touches a worktree. \
            Names are matched ignoring case. Put rows in a group with `canopy row move --group` or \
            `canopy row new --group`.
            """,
        subcommands: [List.self, New.self, Rename.self, Remove.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List groups and their rows, in every repo or in one.")

        @Option(help: "Only this repo (name or path).")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(GroupMethod.list, GroupListParams(repo: repo.map(Client.absolutePathIfRelative)))
            try client.print(result) {
                let groups = try result.decode([GroupInfo].self)
                return Table.render(
                    ["GROUP", "REPO", "ROWS"],
                    groups.map { group in
                        [
                            group.name, group.repo,
                            group.rows.isEmpty ? "-" : group.rows.map(\.displayName).joined(separator: ", "),
                        ]
                    }
                )
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create an empty group after the repo's other groups.")

        @Argument(help: "The group's name, unique in its repo ignoring case.")
        var name: String
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(GroupMethod.new, GroupParams(target: Client.hint(repo: repo), name: name))
            try client.print(result) {
                let group = try result.decode(GroupInfo.self)
                return "Created group \(group.name) in \(group.repo)."
            }
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a group.")

        @Argument(help: "The group's current name.")
        var name: String
        @Argument(help: "Its new name.")
        var newName: String
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                GroupMethod.rename, GroupRenameParams(target: Client.hint(repo: repo), name: name, newName: newName))
            try client.print(result) {
                let group = try result.decode(GroupInfo.self)
                return "Renamed \(name.trimmingCharacters(in: .whitespacesAndNewlines)) to \(group.name)."
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Delete a group. Its rows move to the end of the ungrouped rows, and no worktree is touched."
        )

        @Argument(help: "The group's name.")
        var name: String
        @Option(help: "Repo name or path. Defaults to the repo you are in.")
        var repo: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(GroupMethod.remove, GroupParams(target: Client.hint(repo: repo), name: name))
            try client.print(result) {
                let group = try result.decode(GroupInfo.self)
                switch group.rows.count {
                case 0: return "Deleted group \(group.name)."
                case 1: return "Deleted group \(group.name). Its row is ungrouped."
                default: return "Deleted group \(group.name). Its \(group.rows.count) rows are ungrouped."
                }
            }
        }
    }
}
