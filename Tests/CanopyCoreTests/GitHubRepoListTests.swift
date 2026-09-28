import Foundation
import Testing

@testable import CanopyCore

struct GitHubRepoListTests {
    let repos = ["acme/web-app", "acme/api", "NE1NN/canopy", "other/app"].map {
        GitHubRepoSummary(nameWithOwner: $0, description: nil, isPrivate: false, pushedAt: nil)
    }

    func names(_ typed: String) -> [String] {
        GitHubRepoSummary.filter(repos, by: typed).map(\.nameWithOwner)
    }

    @Test func showsEverythingUntilSomethingIsTyped() {
        #expect(names("  ") == ["acme/web-app", "acme/api", "NE1NN/canopy", "other/app"])
    }

    @Test func keepsReposWhoseNameHoldsTheTextInAnyCase() {
        #expect(names("APP") == ["acme/web-app", "other/app"])
        #expect(names("ne1nn/") == ["NE1NN/canopy"])
    }

    @Test func matchesAPastedGitHubURLByItsRepo() {
        #expect(names("git@github.com:ne1nn/canopy.git") == ["NE1NN/canopy"])
        #expect(names("https://github.com/acme/api") == ["acme/api"])
    }

    @Test func saysHowToFixGH() {
        #expect(
            GHFailure.ghMissing.repoListNote
                == "Install gh to see your repos here: `brew install gh`, then `gh auth login`. You can still paste a URL."
        )
        #expect(
            GHFailure.notLoggedIn.repoListNote
                == "Run `gh auth login` to see your repos here. You can still paste a URL.")
        #expect(GHFailure.failed("HTTP 502").repoListNote == "Your repos did not load: HTTP 502")
    }
}
