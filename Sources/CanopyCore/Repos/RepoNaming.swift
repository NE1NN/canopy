import Foundation

public enum RepoNaming {
    /// Folder names. Repos that share a folder name each get as many parent folders as it takes to tell them apart.
    public static func displayNames(for paths: [String]) -> [String: String] {
        let folders = paths.map { URL(fileURLWithPath: $0).pathComponents.filter { $0 != "/" } }
        var result: [String: String] = [:]
        for group in Dictionary(grouping: paths.indices, by: { folders[$0].last ?? "" }).values {
            var depth = 1
            func name(_ index: Int) -> String { folders[index].suffix(depth).joined(separator: "/") }
            while Set(group.map(name)).count < group.count, group.contains(where: { folders[$0].count > depth }) {
                depth += 1
            }
            for index in group {
                result[paths[index]] = name(index)
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
