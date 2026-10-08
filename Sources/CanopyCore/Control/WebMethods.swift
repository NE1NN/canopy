import Foundation

public enum WebMethod {
    public static let open = "web.open"
    public static let list = "web.list"
    public static let close = "web.close"
}

public struct WebOpenParams: Codable, Sendable {
    public var target: TargetHint
    public var url: String
    /// The panel or a tab for this page alone. Nil opens it where the author last moved a page.
    public var placement: WebPlacement?

    public init(target: TargetHint = TargetHint(), url: String, placement: WebPlacement? = nil) {
        self.target = target
        self.url = url
        self.placement = placement
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        url = try container.decode(String.self, forKey: .url)
        placement = try container.decodeIfPresent(WebPlacement.self, forKey: .placement)
    }
}

public struct WebOpenResult: Codable, Sendable, Equatable {
    public var page: String
    public var placement: WebPlacement
    public var row: String
}

/// One page as `canopy web list` shows it.
public struct WebPageInfo: Codable, Sendable, Equatable {
    public var page: String
    public var url: String
    /// The page's title, or its host before it has loaded.
    public var title: String
    public var placement: WebPlacement
    /// Left out for a plugin's row, which names its plugin instead.
    public var repo: String?
    public var plugin: String?
    public var row: String
    public var rowPath: String
}

public struct WebListParams: Codable, Sendable {
    public var target: TargetHint
    /// Every row's pages, as when no row resolves.
    public var all: Bool

    public init(target: TargetHint = TargetHint(), all: Bool = false) {
        self.target = target
        self.all = all
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        all = try container.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }
}

public struct WebCloseParams: Codable, Sendable {
    public var page: String

    public init(page: String) {
        self.page = page
    }
}
