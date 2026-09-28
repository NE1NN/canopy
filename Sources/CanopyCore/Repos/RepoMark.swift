/// What a repo's tile in the sidebar shows: a letter, and one of `hueCount` hues that stays the same across launches.
public struct RepoMark: Equatable, Sendable {
    public static let hueCount = 8

    public let letter: String
    public let hue: Int

    /// `name` is the display name, which can carry parent folders, as in `work/client/app`.
    public init(name: String, path: String) {
        let folder = name.split(separator: "/").last ?? ""
        letter = folder.first(where: { $0.isLetter || $0.isNumber }).map { String($0.uppercased().prefix(1)) } ?? "?"
        hue = Int(Self.stableHash(path) % UInt64(Self.hueCount))
    }

    /// 64-bit FNV-1a over the UTF-8 bytes.
    static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }
}

extension RepoSnapshot {
    public var mark: RepoMark { RepoMark(name: name, path: path) }
}
