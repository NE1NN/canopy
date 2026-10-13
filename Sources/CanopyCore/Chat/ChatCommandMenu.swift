import Foundation

/// One entry of the `/` menu.
public struct ChatMenuItem: Equatable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var argumentHint: String
    public var isSkill: Bool
    /// Needs Claude Code's full screen, so it runs in a terminal.
    public var opensInTerminal: Bool

    public var id: String { name }
}

/// What the `/` menu offers for what the author typed after the slash: commands, then skills.
public enum ChatCommandMenu {
    /// Full-screen pickers headless Claude Code 2.1.296 answers with "isn't available in this environment".
    static let fullScreen: Set<String> = ["rewind", "hooks", "login", "logout", "doctor", "terminal-setup", "ide"]

    public static func items(commands: [ClaudeCommand], terminal: [String], typed: String) -> [ChatMenuItem] {
        let needsTerminal = fullScreen.union(terminal)
        let query = typed.lowercased()
        let items = commands.filter { query.isEmpty || $0.name.lowercased().contains(query) }.map { command in
            // Skills come from the author's or a project's folder, or a plugin, which Claude Code notes.
            let isSkill =
                command.name.contains(":") || command.description.hasSuffix("(user)")
                || command.description.hasSuffix("(project)")
            return ChatMenuItem(
                name: command.name, description: command.description, argumentHint: command.argumentHint,
                isSkill: isSkill, opensInTerminal: needsTerminal.contains(command.name))
        }
        // Names that start with what was typed come first, then commands before skills.
        return items.sorted {
            let (a, b) = ($0.name.lowercased().hasPrefix(query), $1.name.lowercased().hasPrefix(query))
            if a != b { return a }
            if $0.isSkill != $1.isSkill { return !$0.isSkill }
            return $0.name < $1.name
        }
    }
}
