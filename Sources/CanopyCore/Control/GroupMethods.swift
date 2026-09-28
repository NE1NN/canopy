import Foundation

public enum GroupMethod {
    public static let list = "group.list"
    public static let new = "group.new"
    public static let rename = "group.rename"
    public static let remove = "group.remove"
}

public struct GroupListParams: Codable, Sendable {
    /// Limits the list to one repo. Lists every repo's groups when nil.
    public var repo: String?

    public init(repo: String? = nil) {
        self.repo = repo
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
    }
}

/// A group of the resolved repo, for `group.new` and `group.remove`.
public struct GroupParams: Codable, Sendable {
    public var target: TargetHint
    public var name: String

    public init(target: TargetHint = TargetHint(), name: String) {
        self.target = target
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        name = try container.decode(String.self, forKey: .name)
    }
}

public struct GroupRenameParams: Codable, Sendable {
    public var target: TargetHint
    public var name: String
    public var newName: String

    public init(target: TargetHint = TargetHint(), name: String, newName: String) {
        self.target = target
        self.name = name
        self.newName = newName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        name = try container.decode(String.self, forKey: .name)
        newName = try container.decode(String.self, forKey: .newName)
    }
}

/// Exactly one of `group`, `noGroup`, `before`, and `after` says where the row goes.
public struct RowMoveParams: Codable, Sendable {
    public var target: TargetHint
    /// The end of this group.
    public var group: String?
    /// The end of the ungrouped rows.
    public var noGroup: Bool
    /// Just before this row of the same repo, a branch or a path.
    public var before: String?
    /// Just after this row of the same repo, a branch or a path.
    public var after: String?

    public init(
        target: TargetHint = TargetHint(), group: String? = nil, noGroup: Bool = false, before: String? = nil,
        after: String? = nil
    ) {
        self.target = target
        self.group = group
        self.noGroup = noGroup
        self.before = before
        self.after = after
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        group = try container.decodeIfPresent(String.self, forKey: .group)
        noGroup = try container.decodeIfPresent(Bool.self, forKey: .noGroup) ?? false
        before = try container.decodeIfPresent(String.self, forKey: .before)
        after = try container.decodeIfPresent(String.self, forKey: .after)
    }

    /// How many destinations were given, which must be one.
    public var destinationCount: Int {
        [group != nil, noGroup, before != nil, after != nil].filter { $0 }.count
    }
}

public struct RowMoveResult: Codable, Sendable {
    public var row: Row
    /// False when the row was already where it was asked to go.
    public var moved: Bool
    /// The group the row was in before, nil if it was ungrouped.
    public var from: String?
}
