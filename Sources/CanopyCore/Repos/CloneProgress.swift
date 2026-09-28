import Foundation

/// How far a clone has got, read from the progress lines git writes to stderr with `--progress`.
public struct CloneProgress: Sendable, Equatable {
    /// What git is doing, such as "Receiving objects" or "Resolving deltas".
    public var phase: String
    /// From 0 to 100, for this phase, as git wrote it.
    public var percent: Int

    public var fraction: Double { Double(percent) / 100 }

    public init(phase: String, percent: Int) {
        self.phase = phase
        self.percent = percent
    }

    /// The last complete progress line so far. git rewrites a line with `\r` as it goes, and gh passes git's through.
    public static func latest(in output: Data) -> CloneProgress? {
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for line in lines.reversed() {
            if let progress = parse(line) { return progress }
        }
        return nil
    }

    /// Reads `[remote: ]<phase>: <spaces><percent>% ...`.
    private static func parse(_ line: Substring) -> CloneProgress? {
        var text = line
        if text.hasPrefix("remote: ") { text = text.dropFirst("remote: ".count) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let phase = text[..<colon]
        let rest = text[text.index(after: colon)...].drop(while: { $0 == " " })
        guard let percent = rest.firstIndex(of: "%"), let value = Int(rest[..<percent]), (0...100).contains(value),
            !phase.isEmpty
        else { return nil }
        return CloneProgress(phase: String(phase), percent: value)
    }
}
