import Foundation
import Testing

@testable import CanopyCore

/// The host's relay sends standard input only to the commands `RelayInput.commands` names, so a command that reads it
/// on the Mac and is missing there would read nothing through the relay.
struct RelayInputTests {
    static let cliSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/CanopyCLI")

    /// The CLI's commands that read standard input, by their type, and their words.
    static let readers: [String: [String]] = [
        "AgentHookCommand": ["agent-hook"],
        "TicketCommand.Connect": ["ticket", "connect"],
    ]

    /// Commands that read standard input but have no use on a host, with why.
    static let localOnly: [String: String] = [
        "RemoteAttachCommand": "a Mac pane's own attach loop, which waits for Return in its terminal"
    ]

    @Test func everyCommandOfTheCLIThatReadsStandardInputIsOneTheRelaySendsItTo() throws {
        let found = try Self.commandsReadingStandardInput()

        #expect(
            found == Set(Self.readers.keys).union(Self.localOnly.keys),
            "Each command that reads standard input belongs in RelayInput.commands, and in this test's readers.")
        #expect(Set(RelayInput.commands.map(\.words)) == Set(Self.readers.values))
        for (type, words) in Self.readers {
            #expect(RelayInput.reading(words) != nil, "\(type)")
        }
    }

    @Test func aCommandsWordsAreMatchedPastOptionsAndOthersReadNothing() {
        #expect(RelayInput.reading(["agent-hook"]) == .hookReport)
        #expect(RelayInput.reading(["ticket", "connect", "https://t.example", "--repo", "app"]) == .firstLine)
        #expect(RelayInput.reading(["ticket", "--json", "connect"]) == .firstLine)
        #expect(RelayInput.reading(["ticket", "list"]) == nil)
        #expect(RelayInput.reading(["term", "send", "p1", "agent-hook"]) == nil)
        #expect(RelayInput.reading([]) == nil)
    }

    /// The commands whose code reads standard input, directly or through a helper type that does, as type paths
    /// such as `TicketCommand.Connect`. Types nest by indentation, as swift-format lays them out.
    static func commandsReadingStandardInput() throws -> Set<String> {
        var patterns = ["STDIN_FILENO", "FileHandle.standardInput", "readLine(", "TokenInput.read", "getchar("]
        let files = try FileManager.default.contentsOfDirectory(atPath: cliSources.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        let sources = try files.map { try String(contentsOf: cliSources.appending(path: $0), encoding: .utf8) }
        var commands: Set<String> = []
        var helpers: Set<String> = []
        while true {
            for source in sources {
                for (owner, isCommand) in readingTypes(in: source, patterns: patterns) {
                    if isCommand { commands.insert(owner) } else { helpers.insert(owner) }
                }
            }
            let added = helpers.map { $0 + "." }.filter { !patterns.contains($0) }
            guard !added.isEmpty else { return commands }
            patterns += added
        }
    }

    private static var declaration: Regex<(Substring, Substring, Substring, Substring, Substring)> {
        /^(\s*)(?:public |private |fileprivate )?(?:final )?(struct|enum|class|actor|extension) (\w+)([^{]*)\{/
    }

    private static func readingTypes(in source: String, patterns: [String]) -> [(String, Bool)] {
        var stack: [(indent: Int, name: String, isCommand: Bool)] = []
        var found: [(String, Bool)] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let text = line.drop { $0 == " " }
            if text.hasPrefix("}") {
                while let last = stack.last, last.indent >= indent { stack.removeLast() }
                continue
            }
            if let match = String(line).firstMatch(of: declaration) {
                while let last = stack.last, last.indent >= indent { stack.removeLast() }
                let isCommand = match.4.contains("ParsableCommand")
                stack.append((indent, String(match.3), isCommand))
                continue
            }
            guard !text.hasPrefix("//"), patterns.contains(where: { text.contains($0) }) else { continue }
            // Code outside any type is reported as a command of its own, so it shows in the failure.
            guard let innermost = stack.last else {
                found.append(("<top level>", true))
                continue
            }
            found.append((stack.map(\.name).joined(separator: "."), innermost.isCommand))
        }
        return found
    }
}
