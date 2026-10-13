import CanopySystem
import CanopyTestSupport
import Foundation

@testable import CanopyBoxKit

/// A tmux server of a test's own: its own socket folder and name, killed when the test lets go of it, so tests never
/// meet the author's tmux or each other's.
final class TmuxServer: Sendable {
    let folder: String
    let tmux: Tmux

    init(config: String? = nil) throws {
        folder = "/tmp/cbx-\(getuid())-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var environment = GitFixture.environment
        environment["TMUX_TMPDIR"] = folder
        environment["TMUX"] = nil
        environment["SHELL"] = "/bin/sh"
        tmux = Tmux(server: "t\(UUID().uuidString.prefix(6))", config: config, environment: environment)
    }

    deinit {
        let tmux = tmux
        _ = try? Subprocess.run(
            tmux.executable, tmux.baseArguments + ["kill-server"], environment: tmux.environment, directory: nil,
            timeout: .seconds(10))
        try? FileManager.default.removeItem(atPath: folder)
    }
}
