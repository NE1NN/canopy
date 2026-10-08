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

    /// With `linkedHome`, the host's HOME reaches its folder through a symbolic link, as /var does on a Mac. With
    /// `listsPorts`, the host has an `ss`, `scripts/fake-ss`, which lists this Mac's listening sockets.
    init(
        in dir: TempDir, alias: String = "box", down: Bool = false, path: String? = nil, linkedHome: Bool = false,
        listsPorts: Bool = false
    ) throws {
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
        if listsPorts {
            let bin = dir.sub("ss-bin-\(alias)")
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            // A link to a file that has run before, since this Mac's security scanner can hold a new file's first run.
            try FileManager.default.createSymbolicLink(
                atPath: bin + "/ss",
                withDestinationPath: (Self.script as NSString).deletingLastPathComponent + "/fake-ss")
            environment["FAKE_SSH_PATH"] = bin + ":" + (path ?? environment["PATH"] ?? "/usr/bin:/bin")
        }
        self.environment = environment
    }

    var git: GitRunner {
        GitRunner.remote(ssh, environment: environment)
    }
}
