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
}

public enum HostChecks {
    /// Prints one `key=value` line for each fact.
    public static let factsCommand = [
        "sh", "-c",
        #"echo "os=$(uname -s)"; echo "home=$HOME"; echo "git=$(command -v git)"; "#
            + #"echo "tmux=$(tmux -V 2>/dev/null)"; echo "python3=$(command -v python3)"; echo "uid=$(id -u)""#,
    ]

    public static func parse(_ output: String) -> HostFacts {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return HostFacts(
            os: values["os"] ?? "", home: values["home"] ?? "", git: !(values["git"] ?? "").isEmpty,
            tmux: values["tmux"] ?? "", python3: !(values["python3"] ?? "").isEmpty, uid: Int(values["uid"] ?? "") ?? 0)
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
