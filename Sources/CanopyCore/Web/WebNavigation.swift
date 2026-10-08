import Foundation

/// Where a page's navigations go. A page stays on its own site, and links the author clicks to other sites open in
/// the browser.
public enum WebNavigation {
    public enum Decision: Equatable, Sendable {
        case allow
        case openInBrowser
        case refuse
    }

    public enum WindowDecision: Equatable, Sendable {
        /// A small sheet, as for Google's sign-in, which closes when the page closes it.
        case popUp
        /// A link with a target of its own, on the page's site, loads in the page itself.
        case loadInPage
        case openInBrowser
        case refuse
    }

    /// The host a page opened on, without `www.`, so claude.ai and www.claude.ai are one site.
    public static func site(of url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A navigation of the page's main frame. Navigations to other sites that the author did not click, such as
    /// sign-in redirects, stay in the page.
    public static func decide(_ url: URL, site: String, isLinkClick: Bool) -> Decision {
        if url.absoluteString == "about:blank" { return .allow }
        guard WebAddress.isWeb(url) else { return .refuse }
        return isLinkClick && !isWithin(url, site: site) ? .openInBrowser : .allow
    }

    /// A page asking for a new window, with the URL it names, if any.
    public static func decideNewWindow(_ url: URL?, site: String, isLinkClick: Bool) -> WindowDecision {
        if let url, url.absoluteString != "about:blank", !WebAddress.isWeb(url) { return .refuse }
        guard isLinkClick, let url else { return .popUp }
        return isWithin(url, site: site) ? .loadInPage : .openInBrowser
    }

    static func isWithin(_ url: URL, site: String) -> Bool {
        let host = Self.site(of: url)
        return host == site || host.hasSuffix("." + site)
    }
}

/// Safari's user agent, which Google's sign-in accepts where it refuses ones it reads as embedded web views.
public enum SafariUserAgent {
    /// What WebKit puts after its own part of the user agent, from the installed Safari's version.
    public static func applicationName(safariVersion: String?) -> String {
        let version = safariVersion.flatMap { $0.wholeMatch(of: /\d+(\.\d+)*/) != nil ? $0 : nil } ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }
}

/// The web panel's width, which is the same for every row.
public enum WebPanelWidth {
    public static let standard = 480.0
    public static let minimum = 320.0

    /// At least the minimum, and at most two thirds of the width beside the row's plugin panel, if any.
    public static func clamp(_ width: Double, available: Double) -> Double {
        min(max(width, minimum), max(minimum, available * 2 / 3))
    }
}
