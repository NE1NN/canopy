import Testing

@testable import CanopyTickets

struct TicketRepoChoiceTests {
    @Test func startsOnTheSavedRepoAndConnectsWithIt() {
        let choice = TicketRepoChoice(saved: "app", registered: ["app", "web"])
        #expect(choice.options == ["app", "web"])
        #expect(choice.connectRepo("app") == "app" && choice.connectRepo("web") == "web")
        #expect(!choice.clears("app") && !choice.clears("web"))
    }

    @Test func noneOverASavedRepoClearsIt() {
        let choice = TicketRepoChoice(saved: "app", registered: ["app"])
        #expect(choice.connectRepo(nil) == nil)
        #expect(choice.clears(nil))
        #expect(!TicketRepoChoice(saved: nil, registered: ["app"]).clears(nil))
    }

    @Test func aSavedNameCanopyHasNoRepoForIsOfferedAndKeptOrCleared() {
        let choice = TicketRepoChoice(saved: "gone", registered: ["app"])
        #expect(choice.options == ["app", "gone"])
        #expect(!choice.isRegistered("gone"))
        #expect(choice.connectRepo("gone") == nil && !choice.clears("gone"))
        #expect(choice.clears(nil))
    }
}

struct TicketRepoLookupTests {
    let repos = [
        (name: "code/app", path: "/u/code/app"), (name: "work/app", path: "/u/work/app"), (name: "web", path: "/u/web"),
    ]

    @Test func anExactNameOrPathWins() {
        #expect(TicketRepoLookup.matches("web", among: repos) == [2])
        #expect(TicketRepoLookup.matches("work/app", among: repos) == [1])
        #expect(TicketRepoLookup.matches("/u/code/app", among: repos) == [0])
    }

    @Test func aNameThatLostOrGrewAParentFolderStillFindsItsRepo() {
        #expect(TicketRepoLookup.matches("app", among: repos) == [0, 1])
        #expect(TicketRepoLookup.matches("app", among: [repos[1]]) == [0])
        #expect(TicketRepoLookup.matches("code/app", among: [(name: "app", path: "/u/code/app")]) == [0])
        #expect(TicketRepoLookup.matches("pp", among: repos).isEmpty)
        #expect(TicketRepoLookup.matches("nope", among: repos).isEmpty)
    }
}
