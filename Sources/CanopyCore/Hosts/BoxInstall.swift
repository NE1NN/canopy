import CryptoKit
import Foundation

/// The `canopy-box` binaries the app carries, one per Linux architecture, or one named by CANOPY_BOX_BINARY, which only
/// tests and end-to-end runs set.
public struct BoxBinaries: Sendable, Equatable {
    public var folder: String?
    public var override: String?

    public init(folder: String?, override: String? = nil) {
        self.folder = folder
        self.override = override
    }

    /// The app bundle's `Contents/Resources/box`.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> BoxBinaries {
        BoxBinaries(
            folder: Bundle.main.resourcePath.map { $0 + "/box" },
            override: environment["CANOPY_BOX_BINARY"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The binary for a host whose `uname -m` says `arch`, or nil when the app has none for it.
    public func binary(forArch arch: String) -> String? {
        if let override { return FileManager.default.isExecutableFile(atPath: override) ? override : nil }
        let name: String? =
            switch arch {
            case "x86_64", "amd64": "x86_64"
            case "aarch64", "arm64": "aarch64"
            default: nil
            }
        guard let name, let folder else { return nil }
        let path = folder + "/" + name + "/canopy-box"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

public struct BoxInstallReport: Sendable, Equatable {
    /// The host's binary was replaced, and the daemon restarted.
    public var updated: Bool
    /// systemd's user manager runs the daemon, rather than a detached process.
    public var systemd: Bool
    /// Whether the user's services start at boot without a login, when the host can say.
    public var lingering: Bool?
}

/// Puts `canopy-box` on a host and keeps it running for one home: as a systemd user service where the user's manager
/// answers, or else as a detached process. The binary goes up through the master and replaces the host's by a rename,
/// so a running daemon never sees half a file, and only when it differs, so its SHA-256 is its version.
public enum BoxInstall {
    public static func install(on connection: HostConnection, homeID: String, binaries: BoxBinaries) async throws
        -> BoxInstallReport
    {
        let alias = connection.alias
        let facts = try await run(factsCommand(homeID: homeID), on: connection)
        let lines = Dictionary(
            facts.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                return parts.isEmpty ? nil : (parts[0], parts.count > 1 ? parts[1] : "")
            }, uniquingKeysWith: { first, _ in first })
        let arch = lines["arch"] ?? ""
        guard let binary = binaries.binary(forArch: arch), let data = FileManager.default.contents(atPath: binary)
        else {
            throw WorkspaceError.hostCommandFailed(
                alias,
                reason:
                    "This Canopy has no canopy-box for \(arch.isEmpty ? "the host" : arch). Build it with `make box`.")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let updated = lines["hash"] != hash
        if updated {
            let result = try await connection.run(uploadCommand(homeID: homeID), timeout: .seconds(600), stdin: data)
            try check(result, alias: alias)
        }
        let systemd = lines["systemd"] != nil
        _ = try await run(startCommand(homeID: homeID, restart: updated, systemd: systemd), on: connection)
        let linger = lines["linger"].map { $0.trimmingCharacters(in: .whitespaces) }
        return BoxInstallReport(
            updated: updated, systemd: systemd, lingering: linger == "yes" ? true : linger == "no" ? false : nil)
    }

    /// Stops the daemon and takes away its service, leaving its binary and files.
    public static func stop(on connection: HostConnection, homeID: String) async throws {
        _ = try await run(stopCommand(homeID: homeID), on: connection)
    }

    /// The systemd unit: restarted always, two seconds after it stops, and started with the user's manager.
    static func unit(homeID: String) -> String {
        """
        # Written by Canopy. Changes here are replaced when Canopy updates it.
        [Unit]
        Description=Canopy on this host, for home \(homeID)

        [Service]
        ExecStart=%h/.canopy/\(homeID)/bin/canopy-box serve --home-id \(homeID)
        Restart=always
        RestartSec=2

        [Install]
        WantedBy=default.target

        """
    }

    /// Prints the host's architecture, the hash of this home's binary if it has one, `systemd` when the user's manager
    /// answers, and whether the user lingers.
    static func factsCommand(homeID: String) -> [String] {
        let script = #"""
            h=$0; b="$HOME/.canopy/$h/bin/canopy-box"
            printf 'arch %s\n' "$(uname -m)"
            if [ -x "$b" ]; then
                printf 'hash %s\n' "$( (sha256sum "$b" 2>/dev/null || shasum -a 256 "$b" 2>/dev/null) | cut -d' ' -f1)"
            fi
            if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
                echo systemd
            fi
            if command -v loginctl >/dev/null 2>&1; then
                printf 'linger %s\n' "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
            fi
            true
            """#
        return ["sh", "-c", script, homeID]
    }

    /// Writes standard input to a temporary file beside the binary, then renames it into place.
    static func uploadCommand(homeID: String) -> [String] {
        let script = #"""
            d="$HOME/.canopy/$0/bin"; mkdir -p "$d" && t="$d/.canopy-box.new-$$" \
                && cat > "$t" && chmod 755 "$t" && mv -f "$t" "$d/canopy-box" || { rm -f "$t"; exit 1; }
            """#
        return ["sh", "-c", script, homeID]
    }

    /// Starts the daemon, or restarts it after an update, and waits up to 30 seconds for it to answer, as a freshly
    /// written binary's first run can be held by a security scanner.
    static func startCommand(homeID: String, restart: Bool, systemd: Bool) -> [String] {
        let script = #"""
            h=$0 restart=$1 systemd=$2 unit=$3
            b="$HOME/.canopy/$h/bin/canopy-box" pid="$HOME/.canopy/$h/box/pid"
            if [ "$systemd" = 1 ]; then
                d="$HOME/.config/systemd/user"; mkdir -p "$d"
                printf %s "$unit" | base64 -d > "$d/canopy-box-$h.service.new" \
                    && mv -f "$d/canopy-box-$h.service.new" "$d/canopy-box-$h.service" || exit 1
                systemctl --user daemon-reload && systemctl --user enable "canopy-box-$h" >/dev/null 2>&1 || exit 1
                if [ "$restart" = 1 ]; then systemctl --user restart "canopy-box-$h"
                else systemctl --user start "canopy-box-$h"; fi || exit 1
            else
                if [ "$restart" = 1 ] && [ -f "$pid" ]; then
                    kill "$(cat "$pid")" 2>/dev/null
                    i=0; while [ $i -lt 30 ] && "$b" status --home-id "$h"; do sleep 0.1; i=$((i + 1)); done
                fi
                if ! "$b" status --home-id "$h"; then
                    mkdir -p "$HOME/.canopy/$h/box"
                    if command -v setsid >/dev/null 2>&1; then
                        setsid nohup "$b" serve --home-id "$h" </dev/null >/dev/null 2>&1 &
                    else
                        nohup "$b" serve --home-id "$h" </dev/null >/dev/null 2>&1 &
                    fi
                    echo $! > "$pid"
                fi
            fi
            i=0; while [ $i -lt 300 ]; do "$b" status --home-id "$h" && exit 0; sleep 0.1; i=$((i + 1)); done
            echo "canopy-box did not start on this host." >&2; exit 1
            """#
        return [
            "sh", "-c", script, homeID, restart ? "1" : "0", systemd ? "1" : "0",
            Data(unit(homeID: homeID).utf8).base64EncodedString(),
        ]
    }

    static func stopCommand(homeID: String) -> [String] {
        let script = #"""
            h=$0; b="$HOME/.canopy/$h/bin/canopy-box" pid="$HOME/.canopy/$h/box/pid"
            u="$HOME/.config/systemd/user/canopy-box-$h.service"
            if [ -f "$u" ] && command -v systemctl >/dev/null 2>&1; then
                systemctl --user disable --now "canopy-box-$h" >/dev/null 2>&1
                rm -f "$u"; systemctl --user daemon-reload >/dev/null 2>&1
            fi
            if [ -f "$pid" ]; then kill "$(cat "$pid")" 2>/dev/null; rm -f "$pid"; fi
            i=0; while [ $i -lt 50 ] && [ -x "$b" ] && "$b" status --home-id "$h"; do sleep 0.1; i=$((i + 1)); done
            true
            """#
        return ["sh", "-c", script, homeID]
    }

    private static func run(_ command: [String], on connection: HostConnection) async throws -> String {
        let result = try await connection.run(command, timeout: .seconds(60))
        try check(result, alias: connection.alias)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private static func check(_ result: SubprocessResult, alias: String) throws {
        let errors = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 255 || result.timedOut {
            throw WorkspaceError.hostUnreachable(alias, reason: errors.isEmpty ? "ssh failed." : errors)
        }
        guard result.status == 0 else {
            throw WorkspaceError.hostCommandFailed(alias, reason: errors.isEmpty ? "exit \(result.status)" : errors)
        }
    }
}
