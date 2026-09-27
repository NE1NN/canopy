import Foundation

/// The screen side of a terminal: it interprets what the process writes and draws it.
/// The app implements it with SwiftTerm.
@MainActor
public protocol TerminalEmulator: AnyObject {
    /// The size in cells the emulator shows.
    var size: TerminalSize { get }
    /// Called with what the user types or pastes.
    var onInput: ((Data) -> Void)? { get set }
    /// Called when the size in cells changes.
    var onResize: ((TerminalSize) -> Void)? { get set }
    /// Called when the running program sets the title.
    var onTitle: ((String) -> Void)? { get set }
    /// Shows what the process wrote.
    func feed(_ data: Data)
}

@MainActor
public protocol TerminalEngine {
    func makeEmulator(size: TerminalSize) -> any TerminalEmulator
}

public enum PaneCommand: Sendable, Equatable {
    /// The user's interactive login shell.
    case shell
    /// A POSIX sh script, run by the user's shell. Setup and teardown use it.
    case script(String)
}

/// A title a program set, and the process group in the foreground when it set it.
public struct ProgramTitle: Sendable, Equatable {
    public var text: String
    public var group: pid_t?

    public init(text: String, group: pid_t?) {
        self.text = text
        self.group = group
    }
}

public enum PaneTitle {
    /// A program's title holds while the process group that set it is in the foreground, so a finished `claude`
    /// does not leave its title behind. Otherwise the foreground process names the pane.
    public static func resolve(_ title: ProgramTitle?, foreground: ForegroundProcess?) -> String {
        if let title, !title.text.isEmpty, foreground == nil || title.group == foreground?.pid {
            return title.text
        }
        return foreground?.name ?? ""
    }
}

public enum TabNaming {
    static let base = "Terminal"

    /// "Terminal", then "Terminal 2", "Terminal 3", and so on, skipping names the row's tabs already use.
    public static func next(after existing: [String]) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }
}

public enum BusyTerminals {
    /// For the quit confirmation, such as "3 terminals are running processes: claude, bun. Quitting stops them."
    public static func quitWarning(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) {
            unique.append(name)
        }
        let list = unique.joined(separator: ", ")
        return names.count == 1
            ? "1 terminal is running a process: \(list). Quitting stops it."
            : "\(names.count) terminals are running processes: \(list). Quitting stops them."
    }
}
