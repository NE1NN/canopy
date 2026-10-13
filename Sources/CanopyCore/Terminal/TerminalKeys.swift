import Foundation

/// Keys Canopy changes before the emulator sees them.
public enum TerminalKeys {
    public enum Key: Sendable {
        case `return`, keypadEnter, other
    }

    public enum Modifier: Sendable {
        case shift, control, option, command
    }

    public struct Press: Sendable, Equatable {
        public var key: Key
        public var modifiers: Set<Modifier>

        public init(key: Key, modifiers: Set<Modifier>) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    /// The key to press instead of `press`, or nil to keep it.
    /// ⌘Return and ⌘Enter type ⌥Return, which with Option as Meta is a newline in Claude Code's prompt and in zsh's
    /// command line. The emulator sends nothing for ⌘Return, and Return with the kitty keyboard protocol's super
    /// modifier would not do: Claude Code submits on it, and tmux, which remote panes run in, has no Command key.
    public static func substitute(for press: Press) -> Press? {
        guard press.key == .return || press.key == .keypadEnter, press.modifiers == [.command] else { return nil }
        return Press(key: .return, modifiers: [.option])
    }
}
