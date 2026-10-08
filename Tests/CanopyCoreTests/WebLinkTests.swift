import Foundation
import Testing

@testable import CanopyCore

struct WebLinkTests {
    @Test func readsArtifactLinks() {
        for text in [
            "https://claude.ai/artifact/a1B2-c3_d4", "https://claude.ai/artifact/a1B2-c3_d4/",
            "https://claude.ai/artifact/a1B2?ref=x", "https://claude.ai/artifact/a1B2#top",
            "https://www.claude.ai/artifact/a1B2", "HTTPS://Claude.AI/artifact/a1B2",
            " https://claude.ai/artifact/a1B2 ",
            "https://claude.ai/code/artifact/0b7f3a52-3c1e-4d0a-9a43-2f1e5b6c7d8e",
            "https://claude.ai/code/artifact/0B7F3A52-3C1E-4D0A-9A43-2F1E5B6C7D8E/?tab=1",
        ] {
            #expect(ArtifactLink(text) != nil, "\(text)")
        }
    }

    @Test func keepsTheLinkAsGiven() throws {
        let link = try #require(ArtifactLink("https://claude.ai/artifact/a1B2?ref=x#top"))
        #expect(link.url.absoluteString == "https://claude.ai/artifact/a1B2?ref=x#top")
    }

    @Test func refusesEverythingElse() {
        for text in [
            "", "claude.ai/artifact/a1B2", "http://claude.ai/artifact/a1B2", "https://claude.ai/artifact/",
            "https://claude.ai/artifact", "https://claude.ai/artifacts/a1B2", "https://claude.ai/artifact/a1B2/more",
            "https://claude.ai//artifact/a1B2", "https://claude.ai/artifact/a%20b", "https://claude.ai/chat/a1B2",
            "https://claude.ai/code/artifact/not-a-uuid", "https://claude.ai/code/artifact/a1B2",
            "https://evil.com/artifact/a1B2", "https://claude.ai.evil.com/artifact/a1B2",
            "https://api.claude.ai/artifact/a1B2", "https://user@claude.ai/artifact/a1B2",
            "https://claude.ai:8443/artifact/a1B2", "ftp://claude.ai/artifact/a1B2",
        ] {
            #expect(ArtifactLink(text) == nil, "\(text)")
        }
    }

    @Test func webAddressesAreHTTPOrHTTPSWithAHost() {
        #expect(WebAddress.parse("http://localhost:5173/x")?.absoluteString == "http://localhost:5173/x")
        #expect(WebAddress.parse(" https://example.com ")?.absoluteString == "https://example.com")
        for text in [
            "", "example.com", "file:///etc/hosts", "javascript:alert(1)", "https://", "http:///x", "mailto:a@b.c",
        ] {
            #expect(WebAddress.parse(text) == nil, "\(text)")
        }
    }

    @Test func terminalLinksRouteByKind() {
        #expect(
            TerminalLink("https://claude.ai/artifact/a1B2")
                == .artifact(URL(string: "https://claude.ai/artifact/a1B2")!))
        #expect(
            TerminalLink("https://github.com/acme/app/pull/7")
                == .browser(URL(string: "https://github.com/acme/app/pull/7")!))
        #expect(TerminalLink("http://localhost:3000") == .browser(URL(string: "http://localhost:3000")!))
        // SwiftTerm hands over paths it found in the text, which open with their app as before.
        #expect(TerminalLink("Sources/App.swift:12") == .path("Sources/App.swift:12"))
        #expect(TerminalLink("~/notes.md") == .path("~/notes.md"))
        for text in ["file:///etc/hosts", "javascript:alert(1)", "x-apple-reminder://a", "ssh://host", ""] {
            #expect(TerminalLink(text) == .refused, "\(text)")
        }
    }
}
