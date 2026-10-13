/// Where a Canopy home's things are on a host, and what a pane there gets, for the Mac and canopy-box alike.
public enum HostLayout {
    /// The home's tmux server, as `tmux -L` names it.
    public static func tmuxServer(homeID: String) -> String {
        "canopy-\(homeID)"
    }

    /// The host's end of the Mac's forwarded relay socket, under the host user's `home`.
    public static func relaySocket(home: String, homeID: String) -> String {
        "\(home)/.canopy/\(homeID)/app.sock"
    }

    /// The home's `canopy` on the host.
    public static func relayCLI(home: String, homeID: String) -> String {
        "\(home)/.canopy/\(homeID)/bin/canopy"
    }

    /// What a pane's shell on a host gets, as a pane on the Mac would, with the host's paths, and this home's `canopy`
    /// on the host and the socket it relays through. No CANOPY_HOME or ZDOTDIR: those name folders on the Mac.
    public static func paneEnvironment(
        pane: String, rowName: String, repoName: String, host: String, rowPath: String, clone: String,
        hostHome: String, homeID: String
    ) -> [String: String] {
        [
            "CANOPY_PANE": pane, "CANOPY_ROW": rowName, "CANOPY_REPO": repoName, "CANOPY_HOST": host,
            "CANOPY_ROW_PATH": rowPath, "CANOPY_ROOT_PATH": clone,
            "CANOPY_SOCKET": relaySocket(home: hostHome, homeID: homeID),
            "CANOPY_CLI": relayCLI(home: hostHome, homeID: homeID), "CANOPY_HOME_ID": homeID,
            "TERM_PROGRAM": "Canopy", "TERM_PROGRAM_VERSION": CanopyVersion.current, "COLORTERM": "truecolor",
        ]
    }
}
