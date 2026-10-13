import Foundation

/// One hunk of a file change: where it starts and its lines, each starting with " ", "-", or "+".
public struct ChatHunk: Equatable, Sendable {
    public var oldStart: Int
    public var newStart: Int
    public var lines: [String]

    public init(oldStart: Int, newStart: Int, lines: [String]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

/// A file change, for a diff card: from an edit's result once it ran, or from its input while it waits.
public struct ChatEdit: Equatable, Sendable {
    public var file: String
    public var hunks: [ChatHunk]

    public var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("+") }.count } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("-") }.count } }

    /// From a tool's structured result, which carries `structuredPatch`.
    public init?(result: JSONValue?) {
        guard let fields = result?.fields, case .array(let patches)? = fields["structuredPatch"] else { return nil }
        file = fields["filePath"]?.text ?? ""
        // A new file's result has an empty patch; its content is the change.
        if patches.isEmpty {
            guard fields["type"]?.text == "create", let content = fields["content"]?.text else { return nil }
            hunks = [
                ChatHunk(
                    oldStart: 0, newStart: 1,
                    lines: content.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 })
            ]
            return
        }
        hunks = patches.compactMap { patch in
            guard let fields = patch.fields, case .array(let lines)? = fields["lines"] else { return nil }
            return ChatHunk(
                oldStart: fields["oldStart"]?.integer ?? 0, newStart: fields["newStart"]?.integer ?? 0,
                lines: lines.compactMap(\.text))
        }
    }

    /// What an edit, a multi-edit, or a write would change, read from its input.
    public init?(proposed tool: String, input: [String: JSONValue]) {
        guard let file = input["file_path"]?.text ?? input["notebook_path"]?.text else { return nil }
        func lines(_ text: String?, _ mark: String) -> [String] {
            (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { mark + $0 }
        }
        switch tool {
        case "Edit":
            hunks = [
                ChatHunk(
                    oldStart: 0, newStart: 0,
                    lines: lines(input["old_string"]?.text, "-") + lines(input["new_string"]?.text, "+"))
            ]
        case "MultiEdit":
            guard case .array(let edits)? = input["edits"] else { return nil }
            hunks = edits.compactMap(\.fields).map {
                ChatHunk(
                    oldStart: 0, newStart: 0,
                    lines: lines($0["old_string"]?.text, "-") + lines($0["new_string"]?.text, "+"))
            }
        case "NotebookEdit":
            hunks = [ChatHunk(oldStart: 0, newStart: 0, lines: lines(input["new_source"]?.text, "+"))]
        case "Write":
            hunks = [ChatHunk(oldStart: 0, newStart: 1, lines: lines(input["content"]?.text, "+"))]
        default:
            return nil
        }
        self.file = file
    }

    static let tools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
}
