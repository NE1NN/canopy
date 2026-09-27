import Foundation

public enum PaneEnvironment {
    /// What a macOS login session starts with. Everything else in the app's environment came from whatever
    /// launched it, such as a Claude Code session running a dev build, and must not reach terminals.
    static let inherited: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "LC_CTYPE",
    ]
    /// The login shell's path_helper adds /etc/paths to this, and the user's startup files add the rest.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func build(settings: ShellSettings, context: PaneContext, pane: PaneID) -> [String: String] {
        var environment = settings.baseEnvironment.filter { inherited.contains($0.key) }
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["LANG"] = environment["LANG"] ?? settings.language
        environment["SHELL"] = settings.shell
        environment["PATH"] = ([settings.cliDirectory].compactMap { $0 } + [systemPath]).joined(separator: ":")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Canopy"
        environment["TERM_PROGRAM_VERSION"] = CanopyVersion.current
        environment["CANOPY_HOME"] = settings.home.root.path
        environment["CANOPY_REPO"] = context.repoName
        environment["CANOPY_ROW"] = context.rowName
        environment["CANOPY_ROW_PATH"] = context.rowPath
        environment["CANOPY_ROOT_PATH"] = context.repoPath
        environment["CANOPY_PANE"] = pane.description
        return environment
    }
}
