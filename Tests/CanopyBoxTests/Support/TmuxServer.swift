import CanopySystem
import CanopyTestSupport
import Foundation

@testable import CanopyBoxKit

/// A tmux server of a test's own: its own socket folder and name, killed when the test lets go of it, so tests never
/// meet the author's tmux or each other's.
final class TmuxServer: Sendable {
    let folder: String
    let tmux: Tmux

    /// `pauses` holds tmux back after a command of that name has run, by seconds, through a stand-in `tmux` first on
    /// PATH, so a test can land work in the gap. With `logsCalls`, the stand-in writes each call's words to `calls`.
    init(config: String? = nil, pauses: [String: Double] = [:], logsCalls: Bool = false) throws {
        folder = "/tmp/cbx-\(getuid())-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var environment = GitFixture.environment
        environment["TMUX_TMPDIR"] = folder
        environment["TMUX"] = nil
        environment["SHELL"] = "/bin/sh"
        if !pauses.isEmpty || logsCalls {
            let real = Tmux.find("tmux", path: environment["PATH"]) ?? "/usr/bin/tmux"
            let cases = pauses.map { "        \($0.key)) pause=\($0.value) ;;" }.joined(separator: "\n")
            let script = """
                #!/bin/sh
                \(logsCalls ? "echo \"$*\" >> '\(folder)/calls'" : "")
                pause=0
                for word in "$@"; do
                    case "$word" in
                \(cases)
                    esac
                done
                '\(real)' "$@"
                status=$?
                sleep "$pause"
                exit $status

                """
            try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
            try script.write(toFile: folder + "/bin/tmux", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder + "/bin/tmux")
            environment["PATH"] = folder + "/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        tmux = Tmux(server: "t\(UUID().uuidString.prefix(6))", config: config, environment: environment)
    }

    /// Each call's words, with `logsCalls`.
    var calls: [String] {
        let logged = FileManager.default.contents(atPath: folder + "/calls") ?? Data()
        return String(decoding: logged, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    deinit {
        let tmux = tmux
        _ = try? Subprocess.run(
            tmux.executable, tmux.baseArguments + ["kill-server"], environment: tmux.environment, directory: nil,
            timeout: .seconds(10))
        try? FileManager.default.removeItem(atPath: folder)
    }
}
