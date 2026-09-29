import Testing

@testable import CanopyCore

struct SearchTextTests {
    @Test func everyWordMustAppearInSomeField() {
        let fields = ["#12", "Keep the page after logging in", "fix/login-redirect", "alice"]

        #expect(SearchText("login").matches(fields))
        #expect(SearchText("PAGE Alice").matches(fields))
        #expect(SearchText("  redirect   keep ").matches(fields))
        #expect(SearchText("#12").matches(fields))
        #expect(!SearchText("login bob").matches(fields))
    }

    @Test func noWordsMatchEverything() {
        #expect(SearchText("").matches([]))
        #expect(SearchText(" \t").matches(["x"]))
        #expect(SearchText(nil).isEmpty)
        #expect(!SearchText("x").isEmpty)
    }
}
