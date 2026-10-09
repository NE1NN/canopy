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

    private static func listed(_ names: [String]) -> String {
        names.isEmpty ? "" : ": " + names.joined(separator: ", ")
    }

    private static func unique(_ tasks: [String]) -> [String] {
        var seen = Set<String>()
        return tasks.filter { seen.insert($0).inserted }
    }
}
