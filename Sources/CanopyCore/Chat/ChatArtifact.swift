import Foundation
import Synchronization

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

    /// The key a thumbnail is kept under: one per artifact and version. Only a version the result named has one, since
    /// a counted one changes as older pages load.
    public var thumbnailKey: String? {
        guard let reportedVersion, let id = artifactID ?? url.map({ ArtifactThumbnails.name(for: $0) }) else {
            return nil
        }
        return "\(id)-v\(reportedVersion)"
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
            // It names a file, so only letters, digits, - and _ count, as in the URL's own ID.
            artifactID = fields["artifact_id"]?.text.flatMap { ArtifactLink.isID($0) ? $0 : nil }
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

/// Snapshots of artifacts, one file per artifact and version, kept in `CANOPY_HOME/thumbnails/`. Which ones exist is read
/// from the folder once and kept up to date as snapshots are saved, so drawing a chat's rows reads no disk.
public final class ArtifactThumbnails: Sendable {
    public let folder: URL
    private let saved = Mutex<Set<String>?>(nil)

    public init(folder: URL) {
        self.folder = folder
    }

    public func file(for key: String) -> URL {
        folder.appending(path: key + ".png")
    }

    /// The snapshot of `artifact`, once there is one.
    public func existing(for artifact: ChatArtifact) -> URL? {
        guard let key = artifact.thumbnailKey, has(key) else { return nil }
        return file(for: key)
    }

    public func has(_ key: String) -> Bool {
        saved.withLock { saved in
            if saved == nil {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                saved = Set(names.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
            }
            return saved?.contains(key) == true
        }
    }

    public func save(_ png: Data, for key: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: file(for: key), options: .atomic)
        _ = has(key)
        saved.withLock { _ = $0?.insert(key) }
    }

    /// A file name for an artifact known only by its URL, whose last part is its checked ID.
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
