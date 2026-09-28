import Testing

@testable import CanopyCore

struct PRReferenceTests {
    @Test func readsNumbers() {
        for text in ["7", "#7", " #7 ", "007"] {
            #expect(PRReference(text) == PRReference(number: 7), "\(text)")
        }
    }

    @Test func readsPullRequestURLs() {
        for text in [
            "https://github.com/acme/app/pull/7", "https://github.com/acme/app/pull/7/files",
            "https://github.com/acme/app/pull/7?diff=split", "https://github.com/acme/app/pull/7#discussion_r1",
            "http://www.github.com/acme/app/pull/7/", " HTTPS://GitHub.com/acme/app/pull/7 ",
        ] {
            let reference = PRReference(text)
            #expect(reference?.number == 7, "\(text)")
            #expect(reference?.repo == GitHubRepo(owner: "acme", name: "app"), "\(text)")
        }
    }

    @Test func refusesAnythingElse() {
        for text in [
            "", "#", "0", "-3", "7a", "#7 8", "feat/x", "https://github.com/acme/app/issues/7",
            "https://github.com/acme/pull/7", "https://gitlab.com/acme/app/pull/7",
            "https://github.com/acme/app/pull/x",
            "https://github.com/acme/app/pull/0", "99999999999999999999",
        ] {
            #expect(PRReference(text) == nil, "\(text)")
        }
    }
}
