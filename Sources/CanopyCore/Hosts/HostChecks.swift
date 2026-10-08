import Foundation

/// What a host has, as `host add` checks it.
public struct HostFacts: Sendable, Equatable {
    public var os: String
    public var home: String
    public var git: Bool
    /// What `tmux -V` printed, or empty without tmux.
    public var tmux: String
    public var python3: Bool
    public var uid: Int
    /// sshd's MaxSessions as its config sets it: how many sessions one connection holds, each pane taking one. Nil when
    /// the config cannot be read.
    public var maxSessions: Int? = 10
}

public enum HostChecks {
    /// Prints one `key=value` line for each fact.
    public static let factsCommand = [
        "sh", "-c",
        #"echo "os=$(uname -s)"; echo "home=$HOME"; echo "git=$(command -v git)"; "#
            + #"echo "tmux=$(tmux -V 2>/dev/null)"; echo "python3=$(command -v python3)"; echo "uid=$(id -u)"; "#
            // sshd takes a setting's first value, Ubuntu's config includes sshd_config.d before its own lines, and
            // lines after a Match apply only to some connections.
            + #"echo "maxsessions=$(if [ -r /etc/ssh/sshd_config ]; then "#
            + #"for f in /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config; do [ -r "$f" ] && "#
            + #"awk 'tolower($1) == "match" { exit } tolower($1) == "maxsessions" { print $2; exit }' "$f"; "#
            + #"done | head -n 1; else echo unknown; fi)""#,
    ]

    public static func parse(_ output: String) -> HostFacts {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        // Unset means sshd's default. A config that cannot be read says "unknown".
        let maxSessions: Int? =
            switch values["maxsessions"] {
            case nil, "": 10
            case let text?: Int(text)
            }
        return HostFacts(
            os: values["os"] ?? "", home: values["home"] ?? "", git: !(values["git"] ?? "").isEmpty,
            tmux: values["tmux"] ?? "", python3: !(values["python3"] ?? "").isEmpty, uid: Int(values["uid"] ?? "") ?? 0,
            maxSessions: maxSessions)
    }

    /// What may need the author, though the host can be used.
    public static func warnings(_ facts: HostFacts, alias: String) -> [String] {
        guard let maxSessions = facts.maxSessions, maxSessions < 20 else { return [] }
        return [
            "\(alias) allows \(maxSessions) ssh sessions per connection (sshd's MaxSessions), and each pane holds "
                + "one, so only about \(max(maxSessions - 2, 1)) panes can be open there at once. To open more, put "
                + "`MaxSessions 100` in /etc/ssh/sshd_config.d/canopy.conf on the host and restart ssh."
        ]
    }

    /// What the host lacks, each as a phrase for "the host needs …".
    public static func problems(_ facts: HostFacts) -> [String] {
        var missing: [String] = []
        if facts.os != "Linux" { missing.append("Linux (it runs \(facts.os.isEmpty ? "something else" : facts.os))") }
        if !facts.git { missing.append("git") }
        if !isRecentTmux(facts.tmux) {
            missing.append(facts.tmux.isEmpty ? "tmux 3.0 or later" : "tmux 3.0 or later (it has \(facts.tmux))")
        }
        if !facts.python3 { missing.append("python3") }
        return missing
    }

    /// tmux 3.0 brought `new-session -e`, which panes need for their variables.
    static func isRecentTmux(_ version: String) -> Bool {
        guard let range = version.range(of: #"\d+"#, options: .regularExpression), let major = Int(version[range])
        else { return false }
        return major >= 3
    }

    /// A path as the host means it, with `~` as its home and no trailing slash.
    public static func resolve(_ path: String, home: String) -> String {
        var resolved = path
        if resolved == "~" {
            resolved = home
        } else if resolved.hasPrefix("~/") {
            resolved = home + resolved.dropFirst()
        }
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }
}
