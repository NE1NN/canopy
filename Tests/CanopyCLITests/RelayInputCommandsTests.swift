import ArgumentParser
import Foundation
import Testing

@testable import CanopyCLI
@testable import CanopyCore

/// The host's relay sends standard input only to the commands `RelayInput.commands` names, so a command that reads it
/// on the Mac and is missing there would read nothing through the relay, and a listed command the CLI does not have
/// would never match.
struct RelayInputCommandsTests {
    static let cliSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/CanopyCLI")

    /// Commands that read standard input but have no use on a host, with why.
    static let localOnly: [String: String] = [
        "RemoteAttachCommand": "a Mac pane's own attach loop, which waits for Return in its terminal"
    ]

    @Test func everyCommandOfTheCLIThatReadsStandardInputIsOneTheRelaySendsItTo() throws {
        let commands = CLICommands.all
        let readers = try StandardInputScan.readers(in: Self.cliSources, commands: Set(commands.map(\.type)))

        #expect(Set(Self.localOnly.keys).isSubset(of: readers), "Each local-only command still reads standard input.")
        let relayed = readers.subtracting(Self.localOnly.keys)
        let words = relayed.compactMap { type in commands.first { $0.type == type }?.words }
        #expect(words.count == relayed.count, "Each reader is a command of the CLI: \(relayed.sorted())")
        #expect(
            Set(words) == Set(RelayInput.commands.map(\.words)),
            "Each command that reads standard input belongs in RelayInput.commands.")
    }

    @Test func eachCommandTheRelaySendsInputToIsACommandOfTheCLI() {
        let all = Set(CLICommands.all.map(\.words))

        for entry in RelayInput.commands {
            #expect(all.contains(entry.words), "\(entry.words)")
        }
        #expect(all.contains(["ticket", "connect"]) && all.contains(["agent-hook"]))
        #expect(!all.contains(["ticket", "conect"]) && !all.contains(["connect"]))
    }

    /// The scan finds what reads standard input wherever it is, however the code reaches it, and however its type's
    /// declaration is laid out.
    @Test func theScanFindsReadersInSubfoldersThroughHelpersAndWrappedDeclarations() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "canopy-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [
            "Prompt.swift": """
            struct Prompt {
                func read() -> String? { readLine() }
            }

            enum Token {
                static func read() -> String? { Prompt().read() }
            }
            """,
            "Ask.swift": """
            struct Ask: ParsableCommand {
                func run() { _ = Prompt().read() }
            }

            struct AskAgain: ParsableCommand {
                func run() { _ = Token.read() }
            }

            struct Quiet: ParsableCommand {
                func run() { print(MyPrompt()) }
            }
            """,
            "Nested/Deeper/Wrapped.swift": """
            struct Wrapped: ParsableCommand,
                Sendable
            {
                struct Inner: ParsableCommand {
                    func run() { _ = FileHandle.standardInput.readDataToEndOfFile() }
                }

                func run() {}
            }
            """,
        ]
        for (path, source) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: url)
        }

        let readers = try StandardInputScan.readers(
            in: folder, commands: ["Ask", "AskAgain", "Quiet", "Wrapped", "Wrapped.Inner"])

        #expect(readers == ["Ask", "AskAgain", "Wrapped.Inner"])
    }
}

/// The CLI's commands, from its root command, by their words and their type paths such as `TicketCommand.Connect`.
enum CLICommands {
    static let all = commands(under: CanopyCLI.self, words: [])

    private static func commands(under command: ParsableCommand.Type, words: [String]) -> [(
        words: [String], type: String
    )] {
        command.configuration.subcommands.flatMap { subcommand in
            let path = words + [subcommand.configuration.commandName ?? subcommand._commandName]
            let type = String(reflecting: subcommand).split(separator: ".").dropFirst().joined(separator: ".")
            return [(path, type)] + commands(under: subcommand, words: path)
        }
    }
}

/// The commands whose code reads standard input, directly or through a helper type that does, as type paths.
/// Types nest by indentation, as swift-format lays them out.
enum StandardInputScan {
    /// What reads standard input itself. `TokenInput` is in another module, so it is named here.
    static let direct = ["STDIN_FILENO", "FileHandle.standardInput", "readLine(", "getchar(", "TokenInput.read"]

    /// Every type in `folder` and the folders in it whose code reads standard input, of those `commands` names, and
    /// `<top level>` for code outside any type.
    static func readers(in folder: URL, commands: Set<String>) throws -> Set<String> {
        let sources = try swiftFiles(in: folder).map { try String(contentsOf: $0, encoding: .utf8) }
        var patterns = try direct.map { try Regex(NSRegularExpression.escapedPattern(for: $0)) }
        var helpers: Set<String> = []
        while true {
            var found: Set<String> = []
            var added: Set<String> = []
            for source in sources {
                for owner in readingTypes(in: source, matching: patterns) {
                    if commands.contains(owner) || owner == topLevel {
                        found.insert(owner)
                    } else if let name = owner.split(separator: ".").last.map(String.init), !helpers.contains(name) {
                        added.insert(name)
                    }
                }
            }
            guard !added.isEmpty else { return found }
            helpers.formUnion(added)
            // A use of the type or of one of its members, such as `Prompt(` or `Prompt.read`.
            patterns += try added.sorted().map { try Regex(#"(?:^|\W)"# + $0 + #"[.(]"#) }
        }
    }

    static let topLevel = "<top level>"

    private static func swiftFiles(in folder: URL) throws -> [URL] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
        return paths.filter { $0.hasSuffix(".swift") }.sorted().map { folder.appending(path: $0) }
    }

    /// A type's declaration, whose `{` may be on a later line when it is long.
    private static var declaration: Regex<(Substring, Substring)> {
        /^\s*(?:(?:public|package|internal|private|fileprivate|final|indirect|nonisolated)\s+)*(?:struct|enum|class|actor|extension)\s+(?!func\b|var\b|let\b|subscript\b|override\b)([\w.]+)/
    }

    /// The type paths, such as `TicketCommand.Connect`, of the code in `source` that matches a pattern.
    private static func readingTypes(in source: String, matching patterns: [Regex<AnyRegexOutput>]) -> [String] {
        var stack: [(indent: Int, path: [String])] = []
        var opening: (indent: Int, path: [String])?
        var found: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let text = line.drop { $0 == " " }
            if let declared = opening {
                if text.contains("{") {
                    stack.append(declared)
                    opening = nil
                }
                continue
            }
            if text.hasPrefix("}") {
                while let last = stack.last, last.indent >= indent { stack.removeLast() }
                continue
            }
            if let match = line.firstMatch(of: declaration) {
                while let last = stack.last, last.indent >= indent { stack.removeLast() }
                let declared = (indent, (stack.last?.path ?? []) + match.1.split(separator: ".").map(String.init))
                if text.contains("{") { stack.append(declared) } else { opening = declared }
                continue
            }
            guard !text.hasPrefix("//"), patterns.contains(where: { text.contains($0) }) else { continue }
            found.append(stack.last.map { $0.path.joined(separator: ".") } ?? topLevel)
        }
        return found
    }
}
