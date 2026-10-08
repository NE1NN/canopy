import Foundation
import Testing

@testable import CanopyCore

struct WebNavigationTests {
    func url(_ text: String) -> URL { URL(string: text)! }

    @Test func aPagesSiteIsItsHostWithoutWWW() {
        #expect(WebNavigation.site(of: url("https://www.claude.ai/artifact/a")) == "claude.ai")
        #expect(WebNavigation.site(of: url("https://Claude.AI/artifact/a")) == "claude.ai")
        #expect(WebNavigation.site(of: url("http://localhost:5173/")) == "localhost")
    }

    @Test func navigationsWithinTheSiteStay() {
        for link in [
            "https://claude.ai/login", "https://www.claude.ai/artifact/b", "https://api.claude.ai/x",
            "http://claude.ai/redirect",
        ] {
            #expect(WebNavigation.decide(url(link), site: "claude.ai", isLinkClick: true) == .allow, "\(link)")
        }
    }

    @Test func linksTheAuthorClicksToOtherSitesGoToTheBrowser() {
        #expect(
            WebNavigation.decide(url("https://github.com/acme"), site: "claude.ai", isLinkClick: true) == .openInBrowser
        )
        #expect(
            WebNavigation.decide(url("https://notclaude.ai/x"), site: "claude.ai", isLinkClick: true) == .openInBrowser)
    }

    @Test func redirectsAndScriptsToOtherSitesStaySoSignInWorks() {
        #expect(
            WebNavigation.decide(url("https://accounts.google.com/o/oauth2"), site: "claude.ai", isLinkClick: false)
                == .allow)
    }

    @Test func otherSchemesAreRefused() {
        for link in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi", "mailto:a@b.c", "x-app://open"] {
            #expect(WebNavigation.decide(url(link), site: "claude.ai", isLinkClick: true) == .refuse, "\(link)")
            #expect(WebNavigation.decide(url(link), site: "claude.ai", isLinkClick: false) == .refuse, "\(link)")
        }
        #expect(WebNavigation.decide(url("about:blank"), site: "claude.ai", isLinkClick: false) == .allow)
    }

    @Test func newWindowsFromScriptsArePopUpsAndFromClicksAreLinks() {
        // Google sign-in opens its window from a script.
        #expect(
            WebNavigation.decideNewWindow(
                url("https://accounts.google.com/o/oauth2"), site: "claude.ai", isLinkClick: false) == .popUp)
        #expect(WebNavigation.decideNewWindow(nil, site: "claude.ai", isLinkClick: false) == .popUp)
        #expect(
            WebNavigation.decideNewWindow(url("https://claude.ai/artifact/b"), site: "claude.ai", isLinkClick: true)
                == .loadInPage)
        #expect(
            WebNavigation.decideNewWindow(url("https://example.com"), site: "claude.ai", isLinkClick: true)
                == .openInBrowser)
        #expect(
            WebNavigation.decideNewWindow(url("file:///etc/hosts"), site: "claude.ai", isLinkClick: true) == .refuse)
    }

    @Test func theUserAgentIsSafarisOwn() {
        #expect(SafariUserAgent.applicationName(safariVersion: "26.6.2") == "Version/26.6.2 Safari/605.1.15")
        #expect(SafariUserAgent.applicationName(safariVersion: nil) == "Version/26.0 Safari/605.1.15")
        #expect(SafariUserAgent.applicationName(safariVersion: "26 beta; x") == "Version/26.0 Safari/605.1.15")
    }

    @Test func thePanelKeepsBetweenItsLimits() {
        #expect(WebPanelWidth.standard == 480)
        #expect(WebPanelWidth.clamp(480, available: 1200) == 480)
        #expect(WebPanelWidth.clamp(100, available: 1200) == 320)
        #expect(WebPanelWidth.clamp(1100, available: 1200) == 800)
        // A narrow window still gets the least width, so the page stays usable.
        #expect(WebPanelWidth.clamp(480, available: 400) == 320)
    }
}
