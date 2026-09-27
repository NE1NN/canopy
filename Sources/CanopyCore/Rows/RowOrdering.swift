public enum RowOrdering {
    /// Keeps the saved order for rows that still exist and appends newly seen rows in discovery order.
    public static func reconcile(order: [String], present: [String]) -> [String] {
        let presentSet = Set(present)
        var seen = Set<String>()
        var result: [String] = []
        for path in order + present where presentSet.contains(path) && !seen.contains(path) {
            result.append(path)
            seen.insert(path)
        }
        return result
    }
}
