import Foundation

/// What git and gh print when they fail.
enum ToolOutput {
    private static let markers = ["fatal: ", "error: ", "ERROR: "]

    /// The line that says why: git's last `fatal:` or `error:` line, or the last line when there is none. gh's own
    /// `failed to run git` line and git's advice after a remote fails are skipped, and when git only says it could not
    /// read from the remote, the line above it, where ssh or the server says why, is used instead.
    static func reason(_ output: String) -> String? {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("failed to run git:") }
        guard var index = lines.lastIndex(where: isMarked) ?? lines.indices.last else { return nil }
        if withoutPrefix(lines[index]) == "Could not read from remote repository.", index > 0 {
            index -= 1
        }
        return withoutPrefix(lines[index])
    }

    private static func isMarked(_ line: String) -> Bool {
        markers.contains { line.hasPrefix($0) }
    }

    /// gh's and git's own names for a message, which Canopy's messages do not need.
    private static func withoutPrefix(_ line: String) -> String {
        for prefix in ["gh: "] + markers where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }
}
