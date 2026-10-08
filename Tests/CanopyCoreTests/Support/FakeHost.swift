import Foundation

@testable import CanopyCore

/// A host played by this Mac through `scripts/fake-ssh`: remote commands run here, with HOME set to a folder of the
/// test's own, so nothing reaches a real host.
struct FakeHost {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "scripts/fake-ssh").path

    let alias: String
    /// The host's home folder.
    let home: String
    let ssh: SSHCommand
    let environment: [String: String]

    init(in dir: TempDir, alias: String = "box", down: Bool = false) throws {
        self.alias = alias
        home = dir.sub("host-\(alias)")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        ssh = SSHCommand(executable: Self.script, controlPath: dir.sub("cm-\(alias)"), alias: alias)
        var environment = Fixture.environment
        environment["FAKE_SSH_HOME"] = home
        if down { environment["FAKE_SSH_DOWN"] = "1" }
        self.environment = environment
    }

    var git: GitRunner {
        GitRunner.remote(ssh, environment: environment)
    }
}
