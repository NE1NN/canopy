import CryptoKit
import Foundation

/// Names this Mac's Canopy home on hosts, so the release app and a dev build, or two Macs, never share a host's tmux
/// sessions or sockets.
public enum HomeID {
    public static func of(home: CanopyHome, machine: String = HomeID.machineName) -> String {
        hash("\(machine)\n\(home.root.path)")
    }

    public static var machineName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// The first 8 hex digits of the text's SHA-256.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where Canopy's sockets for a host go. A Unix socket's path must fit in 104 bytes, so a home whose path is too long
/// puts them in /tmp/canopy-<uid>/ instead.
public enum HostPaths {
    static let socketPathLimit = 104

    /// ssh makes a control socket as its path, a dot, and 16 characters, then renames it.
    static let controlSocketSuffix = 17

    /// The ssh master's control socket.
    public static func controlSocket(home: CanopyHome, homeID: String, alias: String, uid: uid_t = getuid()) -> String {
        let name = "\(homeID)-\(HomeID.hash(alias))"
        return fitting(home.root.appending(path: "ssh/\(name)").path, else: name, uid: uid, room: controlSocketSuffix)
    }

    /// The socket the app serves a host's relayed CLI calls on.
    public static func hostSocket(home: CanopyHome, homeID: String, alias: String, uid: uid_t = getuid()) -> String {
        let hash = HomeID.hash(alias)
        return fitting(home.root.appending(path: "hosts/\(hash).sock").path, else: "\(homeID)-\(hash).sock", uid: uid)
    }

    /// A pane's end of the forwarded socket, on the host.
    public static func remotePaneSocket(uid: Int, homeID: String, pane: String) -> String {
        "/tmp/canopy-\(uid)/\(homeID)-\(pane).sock"
    }

    /// The tmux server, as `tmux -L` names it.
    public static func tmuxServer(homeID: String) -> String {
        "canopy-\(homeID)"
    }

    public static func shortFolder(uid: uid_t = getuid()) -> String {
        "/tmp/canopy-\(uid)"
    }

    private static func fitting(_ path: String, else name: String, uid: uid_t, room: Int = 0) -> String {
        path.utf8.count + room < socketPathLimit ? path : shortFolder(uid: uid) + "/" + name
    }
}
