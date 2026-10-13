import CanopyTestSupport
import Foundation
import Testing

@testable import CanopyCore

/// Installing canopy-box on the fake host, which is this Mac, with the macOS build of canopy-box.
struct BoxInstallTests {
    final class Marker {}

    /// The canopy-box this test bundle's target builds beside it.
    static let program: String? = {
        var folder = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = folder.appending(path: "canopy-box").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }()

    struct Host {
        let dir: TempDir
        let fake: FakeHost
        let connection: HostConnection
        let homeID = "b0b0b0b0"

        /// With `systemd`, the host has a `systemctl` that answers for the user's manager and runs the unit's
        /// ExecStart in the background, logging what it was asked.
        init(systemd: Bool = false) throws {
            dir = try TempDir(in: "/tmp")
            fake = try FakeHost(in: dir)
            if systemd {
                let bin = fake.home + "/.fake-ssh-bin"
                try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
                let script = #"""
                    #!/bin/sh
                    echo "$*" >> "$HOME/systemctl.log"
                    case "$2" in
                    restart|start)
                        u="$HOME/.config/systemd/user/$3.service"
                        cmd=$(sed -n 's/^ExecStart=//p' "$u" | sed "s|%h|$HOME|")
                        [ "$2" = restart ] && pkill -f "canopy-box serve --home-id ${3#canopy-box-}" 2>/dev/null; sleep 0.3
                        nohup $cmd </dev/null >/dev/null 2>&1 &
                        echo $! > "$HOME/systemd.pid" ;;
                    disable)
                        [ -f "$HOME/systemd.pid" ] && kill "$(cat "$HOME/systemd.pid")" ;;
                    esac
                    exit 0
                    """#
                try script.write(toFile: bin + "/systemctl", atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/systemctl")
            }
            let environment = fake.environment
            connection = HostConnection(
                alias: fake.alias, entry: HostEntry(), ssh: fake.ssh,
                launcher: SubprocessHostLauncher(environment: { environment }),
                activity: ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity"))))
        }

        var binaries: BoxBinaries { BoxBinaries(folder: nil, override: BoxInstallTests.program) }

        func isLive() async throws -> Bool {
            try await connection.run(
                ["sh", "-c", #""$HOME/.canopy/$0/bin/canopy-box" status --home-id "$0""#, homeID],
                timeout: .seconds(20)
            ).status == 0
        }

        func stop() async {
            try? await BoxInstall.stop(on: connection, homeID: homeID)
            await connection.stop()
        }
    }

    @Test func anInstallStartsTheDaemonAndCopiesOnlyWhenTheHashDiffers() async throws {
        let host = try Host()
        let first = try await BoxInstall.install(on: host.connection, homeID: host.homeID, binaries: host.binaries)
        #expect(first.updated)
        #expect(!first.systemd)
        #expect(await eventually { (try? await host.isLive()) == true })
        let installed = host.fake.home + "/.canopy/\(host.homeID)/bin/canopy-box"
        #expect(FileManager.default.contents(atPath: installed) == FileManager.default.contents(atPath: Self.program!))
        let left = try FileManager.default.contentsOfDirectory(
            atPath: (installed as NSString).deletingLastPathComponent)
        #expect(left == ["canopy-box"])
        let second = try await BoxInstall.install(on: host.connection, homeID: host.homeID, binaries: host.binaries)
        #expect(!second.updated)
        #expect(await eventually { (try? await host.isLive()) == true })
        try await BoxInstall.stop(on: host.connection, homeID: host.homeID)
        #expect(try await !host.isLive())
        await host.connection.stop()
    }

    @Test func withSystemdTheUnitRestartsAlwaysAndStartsWithTheUsersManager() async throws {
        let host = try Host(systemd: true)
        let report = try await BoxInstall.install(on: host.connection, homeID: host.homeID, binaries: host.binaries)
        #expect(report.systemd)
        let unit = try String(
            contentsOfFile: host.fake.home + "/.config/systemd/user/canopy-box-\(host.homeID).service", encoding: .utf8)
        #expect(unit.contains("Restart=always"))
        #expect(unit.contains("RestartSec=2"))
        #expect(unit.contains("ExecStart=%h/.canopy/\(host.homeID)/bin/canopy-box serve --home-id \(host.homeID)"))
        #expect(unit.contains("WantedBy=default.target"))
        let log = try String(contentsOfFile: host.fake.home + "/systemctl.log", encoding: .utf8)
        #expect(log.contains("--user enable canopy-box-\(host.homeID)"))
        #expect(log.contains("--user restart canopy-box-\(host.homeID)"))
        #expect(try await host.isLive())
        await host.stop()
        #expect(
            !FileManager.default.fileExists(
                atPath: host.fake.home + "/.config/systemd/user/canopy-box-\(host.homeID).service"))
    }

    @Test func aHostWithNoBinaryForItSaysSo() async throws {
        let host = try Host()
        await #expect(throws: WorkspaceError.self) {
            try await BoxInstall.install(
                on: host.connection, homeID: host.homeID, binaries: BoxBinaries(folder: host.dir.sub("none")))
        }
        await host.connection.stop()
    }
}
