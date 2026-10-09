import Testing

@testable import CanopyCore

struct BackgroundWorkTests {
    @Test func theTextNamesTheWork() {
        #expect(
            BackgroundWork.summary(["npm test"])
                == "Turn ended, waiting on background work: npm test. The agent wakes when it finishes.")
        #expect(
            BackgroundWork.summary(["npm test", "bun dev", "npm test"])
                == "Turn ended, waiting on background work: npm test, bun dev. The agent wakes as each finishes.")
        #expect(
            BackgroundWork.summary([]) == "Turn ended, waiting on background work. The agent wakes when it finishes.")
        #expect(BackgroundWork.label(["npm test"]) == "Agent waiting on background work: npm test")
        #expect(BackgroundWork.label([]) == "Agent waiting on background work")
    }
}
