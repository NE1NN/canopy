import CryptoKit
import Foundation

/// Claude Code's user settings on a host, read and written through its master, where Canopy's hooks go at `host add`.
/// The file is where Claude Code looks on the host: `settings.json` in `$CLAUDE_CONFIG_DIR`, else in `~/.claude`.
public enum HostClaudeSettings {
    /// The file as named on the host, and what it holds, or nil when it does not exist yet.
    public struct Contents: Equatable, Sendable {
        public var path: String
        public var data: Data?
    }

    /// Prints the file's path and its contents, base64-encoded, as one JSON object, with null contents when there is
    /// no file.
    public static let readCommand = ["python3", "-c", program, "read"]

    /// Writes `data` over the file through a temporary file and a rename, unless it no longer holds `original`, and
    /// then prints `changed`. A linked file is written where the link points, so the link stays. A file keeps its
    /// mode, and a new one gets 0644, as `canopy hooks install` gives one here. Contents travel base64-encoded.
    public static func writeCommand(replacing original: Data?, with data: Data) -> [String] {
        ["python3", "-c", program, "write", original.map(digest) ?? "", data.base64EncodedString()]
    }

    /// What `readCommand` printed.
    public static func contents(from output: String) -> Contents? {
        struct Read: Decodable {
            let path: String
            let content: String?
        }
        guard let read = try? JSONDecoder().decode(Read.self, from: Data(output.utf8)) else { return nil }
        guard let content = read.content else { return Contents(path: read.path, data: nil) }
        guard let data = Data(base64Encoded: content) else { return nil }
        return Contents(path: read.path, data: data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let program = """
        import base64, hashlib, json, os, stat, sys
        path = os.path.join(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"), "settings.json")
        target = os.path.realpath(path)
        try:
            with open(target, "rb") as file:
                current = file.read()
        except FileNotFoundError:
            current = None
        except OSError as error:
            sys.exit("Could not read %s: %s" % (path, error.strerror))
        if sys.argv[1] == "read":
            content = None if current is None else base64.b64encode(current).decode("ascii")
            print(json.dumps({"path": path, "content": content}))
            sys.exit()
        if ("" if current is None else hashlib.sha256(current).hexdigest()) != sys.argv[2]:
            print("changed")
            sys.exit()
        try:
            mode = stat.S_IMODE(os.stat(target).st_mode)
        except FileNotFoundError:
            mode = 0o644
        folder = os.path.dirname(target)
        temporary = os.path.join(folder, "." + os.path.basename(target) + ".canopy-" + str(os.getpid()))
        try:
            os.makedirs(folder, exist_ok=True)
            with open(temporary, "wb") as file:
                file.write(base64.b64decode(sys.argv[3]))
            os.chmod(temporary, mode)
            os.replace(temporary, target)
        except OSError as error:
            try:
                os.remove(temporary)
            except OSError:
                pass
            sys.exit("Could not write %s: %s" % (path, error.strerror))
        """
}
