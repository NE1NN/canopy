import Foundation

public enum BranchSlug {
    public static func slug(for branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// Picks `<parent>/<slug>`, adding -2, -3, ... until the folder does not exist.
    public static func folder(for branch: String, in parent: URL, exists: (URL) -> Bool) -> URL {
        let base = slug(for: branch)
        var candidate = parent.appending(path: base)
        var suffix = 2
        while exists(candidate) {
            candidate = parent.appending(path: "\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
