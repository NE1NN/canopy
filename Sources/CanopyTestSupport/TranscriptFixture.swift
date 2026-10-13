import Foundation

/// Transcripts recorded from Claude Code 2.1.296 with Haiku in a throwaway folder (`tools`, `prompts`), and lines
/// written by hand for what those runs did not produce (`edges`). Paths and names are scrubbed.
public enum TranscriptFixture {
    public struct Missing: Error {
        public var name: String
    }

    public static func url(_ name: String) throws -> URL {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Transcripts")
        else { throw Missing(name: name) }
        return url
    }
}
