import Foundation

/// Keys Canopy changes before the emulator sees them.
public enum TerminalKeys {
    public enum Key: Sendable {
        case `return`, keypadEnter, other
    }

    public enum Modifier: Sendable {
        case shift, control, option, command
    }

    /// The modifiers to press `key` with instead, or nil to keep the key as it is.
    /// ⌘Return types what ⌥Return types, a newline in Claude Code's prompt and in zsh's command line. The emulator sends
    /// nothing for ⌘Return, and Return with the kitty keyboard protocol's super modifier would not do: Claude Code
    /// submits on it, and tmux, which remote panes run in, has no Command key to carry.
    public static func substituteModifiers(key: Key, modifiers: Set<Modifier>) -> Set<Modifier>? {
        guard key == .return || key == .keypadEnter, modifiers == [.command] else { return nil }
        return [.option]
    }
}
