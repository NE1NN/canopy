import Foundation

public enum RepoNaming {
    /// Folder names, with the parent folder prepended when two repos share a folder name.
    public static func displayNames(for paths: [String]) -> [String: String] {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        var counts: [String: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        var result: [String: String] = [:]
        for (path, name) in zip(paths, names) {
            if counts[name, default: 0] > 1 {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                result[path] = "\(parent)/\(name)"
            } else {
                result[path] = name
            }
        }
        return result
    }

    /// A stable folder name under CANOPY_HOME/worktrees, unique among registered repos.
    public static func dirName(for path: String, taken: Set<String>) -> String {
        let base = URL(fileURLWithPath: path).lastPathComponent
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
