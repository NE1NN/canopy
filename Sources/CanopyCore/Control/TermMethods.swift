public enum TermMethod {
    public static let list = "term.list"
    public static let new = "term.new"
    public static let send = "term.send"
    public static let read = "term.read"
    public static let close = "term.close"
}

/// One terminal as `canopy term list` shows it.
public struct TermInfo: Codable, Sendable, Equatable {
    public var pane: String
    public var repo: String
    public var row: String
    public var rowPath: String
    public var tab: String
    public var title: String
    public var folder: String
    /// The program in the foreground, such as `claude`, or the shell when it is idle.
    public var foreground: String?
    public var exited: Int32?
}

public struct TermListParams: Codable, Sendable {
    public var target: TargetHint
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

public struct TermNewParams: Codable, Sendable {
    public var target: TargetHint
    /// Adds the pane to the tab with this name, opening it if the row has none.
    public var tab: String?
    public var newTab: Bool
    public var run: String?
    public var title: String?

    public init(
        target: TargetHint = TargetHint(), tab: String? = nil, newTab: Bool = false, run: String? = nil,
        title: String? = nil
    ) {
        self.target = target
        self.tab = tab
        self.newTab = newTab
        self.run = run
        self.title = title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        tab = try container.decodeIfPresent(String.self, forKey: .tab)
        newTab = try container.decodeIfPresent(Bool.self, forKey: .newTab) ?? false
        run = try container.decodeIfPresent(String.self, forKey: .run)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

public struct TermNewResult: Codable, Sendable, Equatable {
    public var pane: String
    public var tab: String
}

public struct TermSendParams: Codable, Sendable {
    public var pane: String
    public var text: String
    public var enter: Bool

    public init(pane: String, text: String, enter: Bool = false) {
        self.pane = pane
        self.text = text
        self.enter = enter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        text = try container.decode(String.self, forKey: .text)
        enter = try container.decodeIfPresent(Bool.self, forKey: .enter) ?? false
    }
}

public struct TermReadParams: Codable, Sendable {
    public var pane: String
    /// The last this many lines, scrollback included. Nil reads the visible screen.
    public var lines: Int?

    public init(pane: String, lines: Int? = nil) {
        self.pane = pane
        self.lines = lines
    }
}

public struct TermReadResult: Codable, Sendable, Equatable {
    public var text: String
}

public struct TermCloseParams: Codable, Sendable {
    public var pane: String
    public var force: Bool

    public init(pane: String, force: Bool = false) {
        self.pane = pane
        self.force = force
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}
