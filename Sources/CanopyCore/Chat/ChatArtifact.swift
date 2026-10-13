import Foundation

/// An artifact Claude published from the chat, shown as a card.
public struct ChatArtifact: Equatable, Sendable {
    /// The Artifact call that published it.
    public var call: ChatToolCall
    public var title: String
    /// Set once the publish succeeded.
    public var url: URL?
    public var artifactID: String?
    /// The version the result names, or else its place among the conversation's publishes of the URL.
    public var version: Int?
    /// Only the author can open it.
    public var isPrivate = true
    /// What kind of page it is, such as "Design" for one made from that Artifact type.
    public var type = "Page"
    /// The version that replaced it later in the conversation.
    public var replacedBy: Int?
    /// The version as the result named it, kept apart from `version`, which can be counted.
    var reportedVersion: Int?

    /// The key a thumbnail is kept under: one per artifact and version.
    public var thumbnailKey: String? {
        guard let version, let id = artifactID ?? url.map({ ArtifactThumbnails.name(for: $0) }) else { return nil }
        return "\(id)-v\(version)"
    }

    /// Whether `call` publishes a page, as opposed to the tool's other actions, which publish nothing.
    static func publishes(_ call: ChatToolCall) -> Bool {
        guard call.name == "Artifact" else { return false }
        let action = TranscriptParser.Builder.string(call.input["action"]) ?? "publish"
        let isAsset = call.input["asset"] == .bool(true)
        let names = ["file_path", "files", "type_url"]
        return action == "publish" && !isAsset && names.contains { call.input[$0] != nil }
    }

    init(call: ChatToolCall) {
        self.call = call
        let path = TranscriptParser.Builder.string(call.input["file_path"])
        title =
            TranscriptParser.Builder.string(call.input["title"])
            ?? path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "Artifact"
    }

    /// Fills it in from the publish's result: the structured one, or else the text Claude Code returns.
    mutating func published(text: String, structured: JSONValue?) {
        call.result = text
        if case .object(let fields)? = structured, let link = fields["url"]?.text, let url = ArtifactLink(link)?.url {
            self.url = url
            artifactID = fields["artifact_id"]?.text
            if let title = fields["title"]?.text, !title.isEmpty { self.title = title }
            if case .number(let seq)? = fields["seq"] { reportedVersion = Int(seq) }
            if let audience = fields["audience"]?.text { isPrivate = audience == "owner" }
            if let type = fields["type_title"]?.text ?? fields["type"]?.text, !type.isEmpty { self.type = type }
            return
        }
        // "Published <file> at <url> (Version N, version id …)"
        guard let match = text.firstMatch(of: /at (https:\/\/\S+) \(Version (\d+)/),
            let url = ArtifactLink(String(match.1))?.url
        else { return }
        self.url = url
        reportedVersion = Int(match.2)
    }
}

/// Snapshots of artifacts, one file per artifact and version, kept in `CANOPY_HOME/thumbnails/`.
public struct ArtifactThumbnails: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func file(for key: String) -> URL {
        folder.appending(path: key + ".png")
    }

    /// The snapshot of `artifact`, once there is one.
    public func existing(for artifact: ChatArtifact) -> URL? {
        guard let key = artifact.thumbnailKey else { return nil }
        let file = file(for: key)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    public func save(_ png: Data, for key: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: file(for: key), options: .atomic)
    }

    /// A file name for an artifact known only by its URL.
    static func name(for url: URL) -> String {
        url.pathComponents.last ?? "artifact"
    }
}

/// A snapshot a chat wants of a page once it loads, for an artifact's card.
public struct ThumbnailWish: Sendable, Equatable {
    public let key: String
    /// Only the page at this address is snapped, never one it went to instead, such as a sign-in.
    public let url: URL
    public let pane: PaneID
}
