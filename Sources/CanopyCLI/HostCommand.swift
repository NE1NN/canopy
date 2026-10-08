import ArgumentParser
import CanopyCore
import Foundation

struct HostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Add, list, and remove hosts that remote rows live on.",
        discussion: """
            A host is an ssh alias from ~/.ssh/config. Remote rows of a registered repo live in that repo's clone on \
            the host, and their terminals run in tmux there, so programs keep running while this Mac sleeps.
            """,
        subcommands: [Add.self, List.self, Remove.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Check a host, install Canopy's files and hooks on it, and save it. Run it again to update a host.",
            discussion: """
                The host needs Linux, git, tmux 3.0 or later, and python3. Each --repo names a registered repo and \
                its clone on the host, such as --repo solis-v1=~/Projects/solis-v1. --wake runs on this Mac when \
                the host cannot be reached, such as a command that starts it. Panes detach after --idle-detach \
                minutes with nothing running and nothing typed, 30 by default, so the host can power itself off; 0 \
                never detaches.

                Programs on the host can then run canopy, which drives this Mac's Canopy as a local agent can, so \
                add only a host whose account you trust as you trust this Mac.
                """
        )

        @Argument(help: "The host's alias in ~/.ssh/config.")
        var alias: String
        @Option(help: ArgumentHelp("A registered repo and its clone on the host.", valueName: "repo=path"))
        var repo: [String] = []
        @Option(help: ArgumentHelp("A command that starts the host.", valueName: "command"))
        var wake: String?
        @Option(help: ArgumentHelp("Minutes before quiet panes detach.", valueName: "minutes"))
        var idleDetach: Int?
        @OptionGroup var output: OutputOptions

        func validate() throws {
            for pair in repo where !pair.contains("=") {
                throw ValidationError("--repo takes <repo>=<path on the host>, not \(pair).")
            }
        }

        func run() async throws {
            var repos: [String: String] = [:]
            for pair in repo {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                repos[parts[0]] = parts.count > 1 ? parts[1] : ""
            }
            let client = Client(json: output.json)
            let params = HostAddParams(alias: alias, repos: repos, wake: wake, idleDetachMinutes: idleDetach)
            let result = client.call(HostMethod.add, params)
            if let host = try? result.decode(HostInfo.self) {
                for warning in host.warnings {
                    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
                }
            }
            try client.print(result) {
                let host = try result.decode(HostInfo.self)
                let clones = host.repos.sorted { $0.key < $1.key }.map { "\($0.key) at \($0.value)" }
                return "Added \(host.alias)"
                    + (clones.isEmpty ? "." : ", with \(clones.joined(separator: ", ")).")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List hosts with their state, repos, and rows.")

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let listing = try client.call(HostMethod.list, JSONValue.null).decode(HostListing.self)
            for warning in listing.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(try .from(listing.hosts)) {
                let hosts = listing.hosts
                guard !hosts.isEmpty else {
                    return "No hosts. Add one with `canopy host add <alias> --repo <repo>=<path>`."
                }
                return Table.render(
                    ["HOST", "STATE", "ROWS", "PANES", "REPOS"],
                    hosts.map { host in
                        [
                            host.alias, host.state.rawValue, "\(host.rows.count)", "\(host.panes.count)",
                            host.repos.keys.sorted().joined(separator: ", "),
                        ]
                    })
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm", abstract: "Forget a host without rows. Its files on the host stay.")

        @Argument(help: "The host's alias.")
        var alias: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(HostMethod.remove, HostRemoveParams(alias: alias))
            try client.print(result) { "Removed \(alias)." }
        }
    }
}
