import Foundation

/// How Canopy starts terminal processes: which shell, and the environment they start from.
public struct ShellSettings: Sendable, Equatable {
    /// Shells that can run the POSIX sh scripts Canopy writes for setup and teardown.
    static let posixShells: Set<String> = ["zsh", "bash", "sh", "ksh", "dash"]

    public var shell: String
    /// The app's own environment. Terminals only get what a macOS login session starts with.
    public var baseEnvironment: [String: String]
    /// The folder holding the bundled `canopy`, put on PATH so agents in a terminal can run it.
    public var cliDirectory: String?
    public var home: CanopyHome
    /// LANG for terminals when the app has none, as Terminal sets it.
    public var language: String
    /// Whether zsh terminals start through Canopy's shim, which reports the commands they run. Off with
    /// "logCommands": false in config.json.
    public var logsCommands: Bool

    public init(
        shell: String,
        baseEnvironment: [String: String],
        cliDirectory: String?,
        home: CanopyHome,
        language: String = "en_US.UTF-8",
        logsCommands: Bool = false
    ) {
        self.shell = shell
        self.baseEnvironment = baseEnvironment
        self.cliDirectory = cliDirectory
        self.home = home
        self.language = language
        self.logsCommands = logsCommands
    }

    public static func current(home: CanopyHome, cliDirectory: String?, logsCommands: Bool) -> ShellSettings {
        ShellSettings(
            shell: LoginShell.path(),
            baseEnvironment: ProcessInfo.processInfo.environment,
            cliDirectory: cliDirectory,
            home: home,
            language: LoginShell.language(for: Locale.current.identifier) {
                FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)")
            },
            logsCommands: logsCommands
        )
    }

    /// Whether interactive shells report the commands they run. Only zsh has a shim.
    var reportsCommands: Bool {
        logsCommands && Self.name(of: shell) == "zsh"
    }

    /// An interactive login shell, started the way Terminal starts one: argv[0] is "-zsh". zsh starts through
    /// Canopy's shim while commands are logged, and signs its reports with `commandToken`.
    public func interactiveShell(
        environment: [String: String], directory: String, commandToken: String? = nil
    ) -> TerminalLaunch {
        var environment = environment
        // Written again if it went missing: zsh pointed at a folder without it would skip the user's startup files.
        if reportsCommands, let commandToken, let folder = try? ZshIntegration.install(in: home) {
            environment["ZDOTDIR"] = folder
            environment["CANOPY_COMMAND_TOKEN"] = commandToken
        }
        return TerminalLaunch(
            executable: shell, arguments: ["-" + Self.name(of: shell)], environment: environment, directory: directory)
    }

    /// Runs a POSIX sh script in an interactive login shell, so it finds the same tools a terminal does.
    /// Shells that cannot run sh scripts, such as fish, hand it to zsh.
    public func script(_ script: String, environment: [String: String], directory: String) -> TerminalLaunch {
        let runner = Self.posixShells.contains(Self.name(of: shell)) ? shell : "/bin/zsh"
        return TerminalLaunch(
            executable: runner,
            arguments: [Self.name(of: runner), "-i", "-l", "-c", script],
            environment: environment,
            directory: directory
        )
    }

    static func name(of shell: String) -> String {
        (shell as NSString).lastPathComponent
    }
}

public enum LoginShell {
    /// The shell in the user's account record, which Terminal also uses. An app's $SHELL can be stale.
    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, access(shell, X_OK) == 0 { return shell }
        }
        if let shell = environment["SHELL"], access(shell, X_OK) == 0 { return shell }
        return "/bin/zsh"
    }

    /// "en_AU" and "en_AU@rg=auzzzz" become "en_AU.UTF-8" when macOS has that locale, and "en_US.UTF-8" if not.
    public static func language(for localeIdentifier: String, exists: (String) -> Bool) -> String {
        let base = localeIdentifier.split(separator: "@").first.map(String.init) ?? localeIdentifier
        let candidate = base.replacingOccurrences(of: "-", with: "_") + ".UTF-8"
        return exists(candidate) ? candidate : "en_US.UTF-8"
    }
}
