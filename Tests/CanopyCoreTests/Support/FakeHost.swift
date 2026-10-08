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

    /// With `linkedHome`, the host's HOME reaches its folder through a symbolic link, as /var does on a Mac.
    init(in dir: TempDir, alias: String = "box", down: Bool = false, path: String? = nil, linkedHome: Bool = false)
        throws
    {
        self.alias = alias
        let folder = dir.sub("host-\(alias)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if linkedHome {
            home = dir.sub("link-\(alias)")
            try FileManager.default.createSymbolicLink(atPath: home, withDestinationPath: folder)
        } else {
            home = folder
        }
        ssh = SSHCommand(executable: Self.script, controlPath: dir.sub("cm-\(alias)"), alias: alias)
        var environment = Fixture.environment
        environment["FAKE_SSH_HOME"] = home
        if down { environment["FAKE_SSH_DOWN"] = "1" }
        if let path { environment["FAKE_SSH_PATH"] = path }
        self.environment = environment
    }

    var git: GitRunner {
        GitRunner.remote(ssh, environment: environment)
    }
}
