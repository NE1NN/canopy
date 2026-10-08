import Foundation

/// A claude.ai artifact's link, which opens inside Canopy instead of in the browser: `https://claude.ai/artifact/<id>`
/// or `https://claude.ai/code/artifact/<uuid>`, with an optional trailing slash, query, and fragment.
public struct ArtifactLink: Sendable, Equatable {
    public let url: URL

    static let hosts: Set<String> = ["claude.ai", "www.claude.ai"]

    public init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url)
    }

    public init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil, parts.port == nil,
            let host = parts.host?.lowercased(), Self.hosts.contains(host)
        else { return nil }
        var path = parts.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.count == 3, segments[1] == "artifact", Self.isID(segments[2]) {
            self.url = url
        } else if segments.count == 4, segments[1] == "code", segments[2] == "artifact",
            UUID(uuidString: segments[3]) != nil
        {
            self.url = url
        } else {
            return nil
        }
    }

    private static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// An http or https URL with a host, the only kind of page Canopy shows or hands to the browser.
public enum WebAddress {
    public static func parse(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), isWeb(url) else {
            return nil
        }
        return url
    }

    public static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host() ?? "").isEmpty
    }
}

/// Where a link ⌘-clicked in a terminal goes.
public enum TerminalLink: Equatable, Sendable {
    /// Into the terminal's row.
    case artifact(URL)
    case browser(URL)
    /// A file path SwiftTerm found in the text, which opens with its app as it always has.
    case path(String)
    /// Any other scheme, since text a program prints could hold links of any kind.
    case refused

    public init(_ link: String) {
        if let artifact = ArtifactLink(link) {
            self = .artifact(artifact.url)
        } else if let url = WebAddress.parse(link) {
            self = .browser(url)
        } else if !link.isEmpty, !Self.namesScheme(link) {
            self = .path(link)
        } else {
            self = .refused
        }
    }

    /// Whether the text starts with a scheme, such as `mailto:`. `App.swift:12` is a path and a line, not a scheme.
    private static func namesScheme(_ text: String) -> Bool {
        guard let match = text.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.\-]*:(.*)$/) else { return false }
        return match.1.wholeMatch(of: /\d+(:\d+)?/) == nil
    }
}
