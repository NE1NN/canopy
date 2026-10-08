/// Where `row new` makes its row.
public enum RowTarget {
    /// The `--on` value for this Mac. No host may have this name.
    public static let local = "local"

    /// The host for `row new --on`, or nil for this Mac. Without `--on`, a run through a host's relay stays on that
    /// host, as the agent asking works there.
    public static func host(on: String?, environment: [String: String]) -> String? {
        guard let on else { return RelayRun.host(in: environment) }
        return on == local ? nil : on
    }
}
