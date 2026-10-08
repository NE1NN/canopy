import Foundation

extension CanopyHome {
    /// Remote rows' stand-in folders, at remote/<host>/<repo>/<slug>.
    public var remoteRoot: URL { root.appending(path: "remote") }
}

/// A row whose worktree is on a host, as last seen. Its stand-in folder on this Mac is its path everywhere a row path
/// is used, since the remote path means nothing here and two hosts can hold the same one.
public struct RemoteRowEntry: Codable, Sendable, Equatable {
    public static let markerName = "remote.json"

    /// The host's ssh alias.
    public var host: String
    /// The worktree's absolute path on the host.
    public var path: String
    public var standIn: String
    public var branch: String?
    public var head: String?
    /// The host no longer has the worktree.
    public var missing: Bool

    public init(
        host: String, path: String, standIn: String, branch: String?, head: String?, missing: Bool = false
    ) {
        self.host = host
        self.path = path
        self.standIn = standIn
        self.branch = branch
        self.head = head
        self.missing = missing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        path = try container.decode(String.self, forKey: .path)
        standIn = try container.decode(String.self, forKey: .standIn)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        head = try container.decodeIfPresent(String.self, forKey: .head)
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    }

    /// Makes the stand-in folder, for this user alone, with `remote.json` naming the host and the remote path.
    /// Safe to repeat, so a folder deleted outside Canopy comes back.
    public func makeStandIn() throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: standIn, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn)
        let marker = try JSONEncoder.sorted.encode(["host": host, "path": path])
        let url = URL(fileURLWithPath: standIn).appending(path: Self.markerName)
        if (try? Data(contentsOf: url)) != marker {
            try marker.write(to: url, options: .atomic)
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension Row {
    public init(remote: RemoteRowEntry, repoPath: String) {
        self.init(
            repoPath: repoPath, path: remote.standIn, branch: remote.branch, head: remote.head, rowClass: .remote,
            isMissing: remote.missing)
        host = remote.host
        remotePath = remote.path
    }
}
