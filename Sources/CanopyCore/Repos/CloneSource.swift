import Foundation

/// What `canopy repo clone` was given: a GitHub `owner/repo`, or a URL git can clone, which may be on GitHub too.
public struct CloneSource: Sendable, Equatable {
    /// As given, trimmed.
    public let text: String
    /// Set for `owner/repo` and for URLs on GitHub.
    public let github: GitHubRepo?
    /// Set for everything but `owner/repo`.
    public let url: String?
    /// The folder the repo's own folder goes in. Nil when a URL names no folder above the repo and no host.
    public let owner: String?
    public let name: String

    public init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text
        // Anything starting with a dash would reach gh or git as an option.
        guard !text.isEmpty, !text.hasPrefix("-") else { throw WorkspaceError.invalidCloneSource(text) }
        if let location = Self.locate(text) {
            let parts = location.path.split(separator: "/").map(String.init)
            var name = parts.last ?? ""
            if name.hasSuffix(".git") { name.removeLast(4) }
            let owner = parts.count > 1 ? parts[parts.count - 2] : location.host
            guard Self.isFolderName(name), owner.map(Self.isFolderName) ?? true else {
                throw WorkspaceError.invalidCloneSource(text)
            }
            github = GitHubRepo(remoteURL: text)
            url = text
            self.owner = github?.owner ?? owner
            self.name = github?.name ?? name
        } else {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, Self.isGitHubOwner(parts[0]), Self.isGitHubRepoName(parts[1]),
                let github = GitHubRepo(remoteURL: "https://github.com/\(text)")
            else { throw WorkspaceError.invalidCloneSource(text) }
            self.github = github
            url = nil
            owner = github.owner
            name = github.name
        }
    }

    /// What `gh repo clone` is given: the URL as typed, so its protocol is kept, or `owner/repo`, so gh picks one.
    /// Nil when the repo is not on GitHub.
    public var ghArgument: String? {
        github.map { url ?? $0.nameWithOwner }
    }

    /// CANOPY_HOME/repos/<owner>/<name>.
    public func defaultFolder(in home: CanopyHome) throws -> String {
        guard let owner else { throw WorkspaceError.cloneNeedsFolder(text) }
        return home.reposRoot.appending(path: owner).appending(path: name).path
    }

    /// Whether a checkout whose origin is `origin` holds this repo. `gitHubRepo` is the GitHub repo behind `origin`,
    /// found the way PR lookups find it, so SSH host aliases count. GitHub repos match by owner and name in any case.
    public func isSameRepo(asOrigin origin: String, gitHubRepo: GitHubRepo?) -> Bool {
        if let github {
            guard let gitHubRepo else { return false }
            return github.owner.lowercased() == gitHubRepo.owner.lowercased()
                && github.name.lowercased() == gitHubRepo.name.lowercased()
        }
        guard let url else { return false }
        return Self.normalized(url) == Self.normalized(origin)
    }

    /// Local paths resolved, and other URLs without trailing slashes or `.git`.
    static func normalized(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://") { text.removeFirst("file://".count) }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        if text.hasPrefix("/") { return Paths.canonical(text) }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text
    }

    /// The host and path of `scheme://[user@]host[:port]/path`, `[user@]host:path`, or a local `/path`.
    private static func locate(_ text: String) -> (host: String?, path: String)? {
        if text.hasPrefix("/") { return (nil, text) }
        if let separator = text.range(of: "://") {
            let rest = text[separator.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var host = rest[..<slash]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
            return (host.isEmpty ? nil : String(host), String(rest[slash...]))
        }
        // A colon after a slash is part of a path, like acme/a:b.
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex, !text[..<colon].contains("/") else {
            return nil
        }
        var host = text[..<colon]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        return (String(host), String(text[text.index(after: colon)...]))
    }

    /// A single folder that stays inside its parent.
    private static func isFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// Letters, digits, and hyphens, not starting with a hyphen, as GitHub allows.
    private static func isGitHubOwner(_ owner: String) -> Bool {
        guard let first = owner.unicodeScalars.first, first != "-" else { return false }
        return owner.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// Letters, digits, dots, hyphens, and underscores, as GitHub allows.
    private static func isGitHubRepoName(_ name: String) -> Bool {
        isFolderName(name)
            && name.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
            }
    }
}
