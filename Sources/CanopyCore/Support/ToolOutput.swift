import Foundation

/// What git and gh print when they fail.
enum ToolOutput {
    /// The last line of `output`, which is where both put the reason, without their own name for the message.
    /// git rewrites progress lines with a carriage return, so those end lines too.
    static func reason(_ output: String) -> String? {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        guard let line = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["gh: ", "fatal: ", "error: "] where trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed
    }
}
