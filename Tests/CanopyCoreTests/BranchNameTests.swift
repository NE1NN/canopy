import Testing

@testable import CanopyCore

struct BranchNameTests {
    /// Names that break each of git's rules, and some that keep them.
    static let names = [
        "feat/x", "fix/login-redirect", "v1.2", "café", "a@b", "12", "#12", "feat/x.y", "UPPER/Case",
        "", " ", "a b", "a\tb", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a..b", ".a", "a/.b", "a.",
        "a.lock", "a/b.lock/c", "/a", "a/", "a//b", "@", "a@{b", "a\u{7F}b", "a\u{01}b", "-a", "HEAD", "feat/HEAD",
    ]

    /// The check `row new` makes with git, plus the names Canopy refuses itself.
    @Test(arguments: names) func agreesWithGit(_ name: String) async {
        let git = await Fixture.git.succeeds(["check-ref-format", "refs/heads/\(name)"])
        let expected = git && !name.hasPrefix("-") && !["HEAD", "@", ""].contains(name)
        #expect(BranchName.isValid(name) == expected, "\(name)")
    }
}
