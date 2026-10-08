import Foundation
import Observation

/// A web page's ID, such as `w3`. `canopy web` names pages by it.
public struct WebPageID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public var description: String { "w\(number)" }

    public init?(_ text: String) {
        guard text.hasPrefix("w"), let number = Int(text.dropFirst()), number > 0 else { return nil }
        self.number = number
    }
}

/// Where a row shows a web page: its panel on the right of the terminals, or a tab of its own.
public enum WebPlacement: String, Codable, Sendable {
    case panel
    case tab
}

/// A web page in a row. The app keeps its web view, which outlives moves between the panel and a tab.
@MainActor
@Observable
public final class WebPage: Identifiable {
    public let id: WebPageID
    /// Where the page is now, which changes as the author follows links within it.
    public internal(set) var url: URL
    /// The page's last title, shown before it has loaded.
    public internal(set) var title: String
    /// The row it belongs to, for the activity log.
    public internal(set) var context: PaneContext
    /// The address it opened with, which still finds it after it moves on, as to claude.ai's sign-in.
    public let openedURL: URL

    init(id: WebPageID, url: URL, title: String, context: PaneContext) {
        self.id = id
        self.url = url
        self.title = title
        self.context = context
        self.openedURL = url
    }

    /// Whether the page is at `url`, or opened with it.
    func shows(_ url: URL) -> Bool {
        self.url == url || openedURL == url
    }

    /// The title, or the host until the page has one.
    public var displayTitle: String {
        title.isEmpty ? (url.host() ?? url.absoluteString) : title
    }
}

/// A row's panel: one page, shown or hidden.
public struct WebPanel {
    public let page: WebPage
    public var isHidden: Bool
}

/// A page `openPage` showed, and whether it opened just now or was already there.
public struct OpenedPage {
    public let page: WebPage
    public let placement: WebPlacement
    public let isNew: Bool
}
