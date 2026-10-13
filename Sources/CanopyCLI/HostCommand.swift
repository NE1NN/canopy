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
        subcommands: [Add.self, List.self, Remove.self, Upgrade.self, WakeKey.self]
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
                            host.alias, host.state.rawValue + (host.box ? ", box" : ""), "\(host.rows.count)",
                            "\(host.panes.count)",
                            host.repos.keys.sorted().joined(separator: ", "),
                        ]
                    })
            }
        }
    }

    struct Upgrade: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hand a host's rows, panes, and agents to canopy-box on it, or take them back with --undo.",
            discussion: """
                canopy-box then keeps the host's rows and agents whether or not this Mac is on, so the iPhone can \
                reach them directly. Nothing running on the host is restarted. It runs as a systemd user service; \
                run `sudo loginctl enable-linger $USER` on the host once, so it starts with the host.
                """)

        @Argument(help: "The host's alias.")
        var alias: String
        @Flag(help: "Go back: this Mac tracks the host again, and canopy-box stops.")
        var undo = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(HostMethod.upgrade, HostUpgradeParams(alias: alias, undo: undo), wait: .forever)
            let upgraded = try result.decode(HostUpgradeResult.self)
            for warning in upgraded.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            try client.print(result) {
                let what =
                    "\(upgraded.rows) \(upgraded.rows == 1 ? "row" : "rows") and \(upgraded.panes) "
                    + (upgraded.panes == 1 ? "pane" : "panes")
                return undo
                    ? "\(alias) is back with this Mac, with \(what)."
                    : "canopy-box now runs \(alias), with \(what)."
            }
        }
    }

    struct WakeKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wake-key",
            abstract: "Give the iPhone a key that starts the host's EC2 instance when it has powered itself off.",
            discussion: """
                Reads an AWS access key id and its secret, one per line, from the terminal or from stdin. Make the key \
                for an IAM user whose only permission is ec2:StartInstances on the host's instance. It stays in this \
                Mac's login Keychain, and canopy-box on the host hands it to paired phones, so needs the host \
                upgraded. Pipe it in with:
                  printf '%s\\n%s\\n' "$KEY_ID" "$SECRET" | canopy host wake-key <host>
                """)

        @Argument(help: "The host's alias.")
        var alias: String
        @Flag(help: "Forget the key here and on the host.")
        var clear = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            var key: BoxWakeKey?
            if !clear {
                let piping = "printf '%s\\n%s\\n' \"$KEY_ID\" \"$SECRET\" | canopy host wake-key \(alias)"
                let id = try SecretPrompt.read(prompt: "Access key id: ", what: "access key id", piping: piping)
                let secret = try SecretPrompt.read(prompt: "Secret access key: ", what: "secret", piping: piping)
                guard !id.isEmpty, !secret.isEmpty else {
                    client.fail(
                        ControlError(code: "bad_params", message: "The access key id and the secret are both needed."))
                }
                key = BoxWakeKey(accessKeyID: id, secretAccessKey: secret)
            }
            let result = client.call(HostMethod.wakeKey, HostWakeKeyParams(alias: alias, key: key))
            let set = try result.decode(HostWakeKeyResult.self)
            try client.print(result) {
                switch (set.isSet, set.sent) {
                case (true, true): "\(alias)'s wake key is set. Paired phones get it when they next connect."
                case (true, false): "\(alias)'s wake key is set. canopy-box gets it when \(alias) next connects."
                case (false, true): "\(alias) has no wake key now."
                case (false, false): "\(alias) has no wake key now. canopy-box forgets it when \(alias) next connects."
                }
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
