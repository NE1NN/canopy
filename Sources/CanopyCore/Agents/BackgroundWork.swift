/// How Canopy names the work a background agent waits on, in tooltips and accessibility labels.
public enum BackgroundWork {
    /// The tooltip: "Turn ended, waiting on background work: npm test. The agent wakes when it finishes."
    public static func summary(_ tasks: [String]) -> String {
        let names = unique(tasks)
        let wakes = names.count > 1 ? "The agent wakes as each finishes." : "The agent wakes when it finishes."
        return "Turn ended, waiting on background work\(listed(names)). \(wakes)"
    }

    /// The short form, for a row's accessibility label: "Agent waiting on background work: npm test".
    public static func label(_ tasks: [String]) -> String {
        "Agent waiting on background work" + listed(unique(tasks))
    }

    /// The first few names, and how many more, so a folded header over many rows keeps a short tooltip.
    private static func listed(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(shownNames).joined(separator: ", ")
        let more = names.count - shownNames
        return ": " + shown + (more > 0 ? ", and \(more) more" : "")
    }

    static let shownNames = 3

    private static func unique(_ tasks: [String]) -> [String] {
        var seen = Set<String>()
        return tasks.filter { seen.insert($0).inserted }
    }
}
