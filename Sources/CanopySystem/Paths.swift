import Foundation

public enum Paths {
    /// Resolves symlinks with realpath(3). Foundation's resolvingSymlinksInPath strips "/private",
    /// which would make paths from git and from FSEvents disagree. For a path that does not exist yet,
    /// the deepest existing folder is resolved and the rest appended, so it still compares equal later.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if let resolved = realpath(expanded, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (expanded as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != expanded else { return expanded }
        let last = (expanded as NSString).lastPathComponent
        if last == "." { return canonical(parent) }
        if last == ".." { return (canonical(parent) as NSString).deletingLastPathComponent }
        return (canonical(parent) as NSString).appendingPathComponent(last)
    }

    public static func isInside(_ path: String, _ root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(prefix)
    }

    public static var homeDirectory: String {
        canonical(NSHomeDirectory())
    }
}
