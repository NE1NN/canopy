import Foundation

/// A pull request as a person types or pastes it: `7`, `#7`, or its URL.
public struct PRReference: Sendable, Equatable {
    public var number: Int
    /// The repo a URL names. Nil for a number, which means origin's repo.
    public var repo: GitHubRepo?

    public init(number: Int, repo: GitHubRepo? = nil) {
        self.number = number
        self.repo = repo
    }

    /// Nil for anything that is not a PR number or a GitHub pull request URL, such as an issue's URL.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Self.number(text.hasPrefix("#") ? String(text.dropFirst()) : text) {
            self.init(number: number)
            return
        }
        guard let url = URLComponents(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
            let host = url.host?.lowercased(), GitHubRepo.hosts.contains(host)
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = Self.number(parts[3]) else { return nil }
        self.init(number: number, repo: GitHubRepo(owner: parts[0], name: parts[1]))
    }

    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let number = Int(text),
            number > 0
        else { return nil }
        return number
    }
}
