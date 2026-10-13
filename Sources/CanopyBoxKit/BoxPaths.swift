import CanopySystem
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Where canopy-box keeps a Canopy home's files on a host, under `~/.canopy/<home id>/`.
public struct BoxPaths: Sendable, Equatable {
    /// The folder holding `.canopy`, normally the user's home.
    public var root: String
    public var homeID: String

    public init(root: String, homeID: String) {
        self.root = root
        self.homeID = homeID
    }

    public var canopy: String { root + "/.canopy" }
    /// This home's folder, which the Mac's files for the host share.
    public var home: String { canopy + "/" + homeID }
    /// canopy-box's own folder, this user's alone.
    public var folder: String { home + "/box" }
    public var socket: String { folder + "/box.sock" }
    public var stateFile: String { folder + "/state.json" }
    public var configFile: String { folder + "/config.json" }
    /// The key phones start the box with, apart from the rest of the Mac's settings.
    public var wakeFile: String { folder + "/wake.json" }
    /// Which EC2 instance the box is, once the instance metadata service has said.
    public var instanceFile: String { folder + "/instance.json" }
    /// Touched while the box should stay on.
    public var busyFile: String { folder + "/busy" }
    /// Hook reports kept while nothing could take them.
    public var pending: String { home + "/pending" }
    /// The Mac's socket, forwarded here while the Mac is connected.
    public var appSocket: String { home + "/app.sock" }
    public var tmuxConf: String { home + "/tmux.conf" }
    public var bin: String { home + "/bin" }

    /// Where the repo's rows go: `~/.canopy/<home id>/worktrees/<repo>`, this home's alone, so a dev build's daemon
    /// and the release app's on one host never take each other's rows. Rows the Mac made before the host upgraded
    /// stay where they are, in the folder every home shares, and come over by `box.adopt`.
    public func worktrees(repo: String) -> String {
        home + "/worktrees/" + repo
    }
}

public enum BoxFiles {
    /// Writes `data` to `path` whole or not at all, readable by this user alone, in a folder only this user can open.
    public static func write(_ data: Data, to path: String) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(folder, 0o700)
        let temporary = path + ".new-\(getpid())-\(UUID().uuidString.prefix(6))"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary]) }
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return fsync(fd) == 0
        }
        _ = close(fd)
        guard written, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
    }
}
