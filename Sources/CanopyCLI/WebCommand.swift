import ArgumentParser
import CanopyCore

struct WebCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "web",
        abstract: "Show web pages, such as claude.ai artifacts, in a row.",
        discussion: """
            A row shows a page in its panel on the right of the terminals, or in a tab of its own. The author moves pages \
            between the two, and new pages open where the author last moved one.
            """,
        subcommands: [Open.self, List.self, Close.self]
    )

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a page in the row you are in.",
            discussion: """
                A page the row shows already is shown where it is. A new page replaces the panel's page, or opens in a \
                new tab. The row stays as it is in the sidebar, so this never takes the author away from another row.
                """
        )

        @Argument(help: "An http or https URL.")
        var url: String
        @Flag(help: "Open it in a tab, whatever the author last chose.")
        var tab = false
        @Flag(help: "Open it in the panel, whatever the author last chose.")
        var panel = false
        @OptionGroup var rowOptions: TermCommand.RowOptions
        @OptionGroup var output: OutputOptions

        func validate() throws {
            if tab && panel { throw ValidationError("Pass --tab or --panel, not both.") }
        }

        func run() async throws {
            let client = Client(json: output.json)
            let placement: WebPlacement? = tab ? .tab : panel ? .panel : nil
            let result = client.call(
                WebMethod.open, WebOpenParams(target: rowOptions.hint, url: url, placement: placement))
            try client.print(result) {
                let opened = try result.decode(WebOpenResult.self)
                let place = opened.placement == .panel ? "the panel" : "a tab"
                return "Showing \(opened.page) in \(place) of \(opened.row)."
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the pages in the row you are in, or in every row.")

        @OptionGroup var rowOptions: TermCommand.RowOptions
        @Flag(help: "List pages in every row.")
        var all = false
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(WebMethod.list, WebListParams(target: rowOptions.hint, all: all))
            try client.print(result) {
                let pages = try result.decode([WebPageInfo].self)
                guard !pages.isEmpty else { return "No pages." }
                return Table.render(
                    ["ID", "WHERE", "ROW", "TITLE", "URL"],
                    pages.map { [$0.page, $0.placement.rawValue, $0.row, $0.title, $0.url] })
            }
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close a page.")

        @Argument(help: "Page ID, such as w3.")
        var id: String
        @OptionGroup var output: OutputOptions

        func run() async throws {
            let client = Client(json: output.json)
            let result = client.call(WebMethod.close, WebCloseParams(page: id), launchIfNeeded: false)
            try client.print(result) { "Closed \(id)." }
        }
    }
}
