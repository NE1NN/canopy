import ArgumentParser
import CanopyCore
import Foundation

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Open chats, which run Claude Code in a tab of their own.",
        discussion: "Drive one with the term commands: term send, term wait, and term read take a chat's pane.",
        subcommands: [New.self]
    )

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a chat in the row you are in, and optionally send it a first message.",
            discussion: "It opens at the end of the row's tabs and never changes which row is selected."
        )

        @OptionGroup var rowOptions: TermCommand.RowOptions
        @Option(help: "First message to send.")
        var prompt: String?
        @Option(help: "Model, such as opus, sonnet, or haiku. Defaults to the one last picked in a chat.")
        var model: String?
        @Option(help: "Permission mode: default, acceptEdits, plan, auto, or bypassPermissions.")
        var mode: String?
        @Option(help: "Go on with this Claude Code session.")
        var resume: String?
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(
                ChatMethod.new,
                ChatNewParams(target: rowOptions.hint, prompt: prompt, model: model, mode: mode, resume: resume))
            try client.print(result) {
                let opened = try result.decode(ChatNewResult.self)
                return "Opened chat \(opened.pane) in tab \(opened.tab)."
            }
        }
    }
}
