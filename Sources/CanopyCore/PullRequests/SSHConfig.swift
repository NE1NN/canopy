import Foundation

/// What ssh would do for a host, for remotes that use an alias from ~/.ssh/config.
public enum SSHConfig {
    /// The host an SSH alias connects to. Blocks while ssh reads its config, so call it through `onOwnThread`.
    /// `ssh -G` only prints the settings it would use; it never connects.
    public static func hostName(
        for alias: String, configFile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard !alias.isEmpty, !alias.hasPrefix("-") else { return nil }
        let arguments = (configFile.map { ["-F", $0] } ?? []) + ["-G", "--", alias]
        guard
            let result = try? Subprocess.run(
                "/usr/bin/ssh", arguments, environment: environment, directory: nil, timeout: .seconds(5)),
            result.status == 0, !result.timedOut
        else { return nil }
        let prefix = "hostname "
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}
