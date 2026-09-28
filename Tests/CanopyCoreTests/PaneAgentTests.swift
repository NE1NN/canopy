import Foundation
import Testing

@testable import CanopyCore

struct PaneAgentTests {
    let start = Date(timeIntervalSince1970: 1_000)

    func time(_ seconds: Double) -> Date {
        start.addingTimeInterval(seconds)
    }

    func hook(
        _ state: AgentState?, session: String = "s1", event: String = "Stop", at seconds: Double,
        question: Bool = false, takesOver: Bool = false, releases: Bool = false
    ) -> AgentReport {
        AgentReport(
            state: state, session: session, event: event, at: time(seconds), question: question,
            takesOver: takesOver, releases: releases)
    }

    @Test func aTurnGoesFromWorkingToDoneAndTheAuthorSeesIt() {
        var agent = PaneAgent()
        #expect(agent.state == .none)
        #expect(agent.dot == nil)

        let started = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        #expect(started == AgentChange(from: .none, to: .working, via: "UserPromptSubmit", session: "s1"))
        #expect(agent.dot == .working)
        #expect(started?.alerts == false)

        let finished = agent.apply(hook(.done, at: 2), now: time(2))
        #expect(finished == AgentChange(from: .working, to: .done, via: "Stop", session: "s1"))
        #expect(finished?.alerts == true)
        #expect(agent.unseen)
        #expect(agent.dot == .done)

        let firstLook = agent.seen()
        let secondLook = agent.seen()
        #expect(firstLook)
        #expect(!secondLook)
        #expect(agent.state == .done)
        #expect(agent.dot == nil)
    }

    @Test func seeingAWaitingPaneChangesNothing() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.waiting, event: "PermissionRequest", at: 1), now: time(1))
        let saw = agent.seen()
        #expect(!saw)
        #expect(agent.dot == .waiting)
    }

    @Test func theSameStateAgainChangesNothingExceptARepeatDone() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.waiting, event: "PermissionRequest", at: 1), now: time(1))
        #expect(agent.apply(hook(.waiting, event: "Notification", at: 2), now: time(2)) == nil)

        _ = agent.apply(hook(.done, at: 3), now: time(3))
        _ = agent.seen()
        let again = agent.apply(AgentReport(state: .done), now: time(4))
        #expect(again == AgentChange(from: .done, to: .done, via: "term.state", session: nil))
        #expect(agent.unseen)
    }

    @Test func aReportFromAHookThatStartedBeforeTheLastChangeIsStale() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        _ = agent.apply(hook(.done, at: 5), now: time(5))
        // A tool call's hook that started before the turn ended arrives late.
        #expect(agent.apply(hook(.working, event: "PostToolUse", at: 4), now: time(6)) == nil)
        #expect(agent.state == .done)

        // A report without a start time takes the time it arrives.
        #expect(agent.apply(AgentReport(state: .working), now: time(7)) != nil)
    }

    @Test func aPaneListensToTheFirstSessionUntilItEnds() {
        var agent = PaneAgent()
        _ = agent.apply(hook(nil, event: "SessionStart", at: 1), now: time(1))
        #expect(agent.session == "s1")
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 2), now: time(2))

        // A `claude -p` run inside the pane reports its own turn.
        #expect(agent.apply(hook(nil, session: "nested", event: "SessionStart", at: 3), now: time(3)) == nil)
        #expect(agent.apply(hook(.done, session: "nested", at: 4), now: time(4)) == nil)
        #expect(
            agent.apply(
                hook(AgentState.none, session: "nested", event: "SessionEnd", at: 5, releases: true), now: time(5))
                == nil)
        #expect(agent.state == .working)
        #expect(agent.session == "s1")

        let ended = agent.apply(hook(AgentState.none, event: "SessionEnd", at: 6, releases: true), now: time(6))
        #expect(ended == AgentChange(from: .working, to: .none, via: "SessionEnd", session: "s1"))
        #expect(agent.session == nil)

        _ = agent.apply(hook(.working, session: "s2", event: "UserPromptSubmit", at: 7), now: time(7))
        #expect(agent.session == "s2")
        #expect(agent.state == .working)
    }

    @Test func aSessionEndReleasesThePaneEvenWithNoStateToClear() {
        var agent = PaneAgent()
        _ = agent.apply(hook(nil, event: "SessionStart", at: 1), now: time(1))
        #expect(agent.apply(hook(AgentState.none, event: "SessionEnd", at: 2, releases: true), now: time(2)) == nil)
        #expect(agent.session == nil)
    }

    @Test func switchingConversationsInsideClaudeMovesThePane() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        _ = agent.apply(hook(nil, session: "s2", event: "SessionStart", at: 2, takesOver: true), now: time(2))
        #expect(agent.session == "s2")
        #expect(agent.apply(hook(.done, session: "s1", at: 3), now: time(3)) == nil)
        #expect(agent.apply(hook(.done, session: "s2", at: 4), now: time(4)) != nil)
    }

    @Test func reportsWithoutASessionAlwaysCount() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        #expect(agent.apply(AgentReport(state: AgentState.none), now: time(2)) != nil)
        #expect(agent.session == "s1")
    }

    @Test func escapeOrControlCInterruptsAWorkingPane() {
        for key in [Data([0x1B]), Data([0x03]), Data("\u{1b}[27u".utf8), Data("\u{1b}[99;5u".utf8)] {
            var agent = PaneAgent()
            _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
            #expect(agent.typed(Data("a".utf8), at: time(2)) == nil)
            // An arrow key starts with Escape but is not one.
            #expect(agent.typed(Data("\u{1b}[A".utf8), at: time(2)) == nil)
            #expect(agent.typed(key, at: time(3)) == AgentChange(from: .working, to: .none, via: "key", session: nil))
        }
    }

    @Test func keysAnswerAPromptButNotAQuestion() {
        var prompt = PaneAgent()
        _ = prompt.apply(hook(.waiting, event: "PermissionRequest", at: 1), now: time(1))
        #expect(prompt.typed(Data("\u{1b}[B".utf8), at: time(2)) == nil)
        #expect(prompt.typed(Data("\r".utf8), at: time(3)) == AgentChange(from: .waiting, to: .working, via: "key"))

        var dismissed = PaneAgent()
        _ = dismissed.apply(hook(.waiting, event: "PreToolUse", at: 1), now: time(1))
        #expect(dismissed.typed(Data([0x1B]), at: time(2))?.to == AgentState.none)

        var question = PaneAgent()
        _ = question.apply(hook(.waiting, at: 1, question: true), now: time(1))
        #expect(question.typed(Data("yes\r".utf8), at: time(2)) == nil)
        #expect(question.typed(Data([0x1B]), at: time(3)) == nil)
        #expect(question.state == .waiting)
        #expect(question.apply(hook(.working, event: "UserPromptSubmit", at: 4), now: time(4)) != nil)
    }

    @Test func aKeyChangeMakesEarlierHooksStale() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 1), now: time(1))
        _ = agent.typed(Data([0x03]), at: time(3))
        #expect(agent.apply(hook(.working, event: "PostToolUse", at: 2), now: time(4)) == nil)
        #expect(agent.state == .none)
        // A turn that goes on after the key reports working again.
        #expect(agent.apply(hook(.working, event: "PostToolUse", at: 5), now: time(5)) != nil)
    }

    @Test func anExitClearsTheStateAndReleasesTheSession() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.done, at: 1), now: time(1))
        #expect(agent.ended(at: time(2)) == AgentChange(from: .done, to: .none, via: "exit", session: nil))
        #expect(agent.session == nil)
        #expect(!agent.unseen)
        #expect(agent.ended(at: time(3)) == nil)
    }

    @Test func aStateIsFreshUntilThePaneGetsInput() {
        var agent = PaneAgent()
        _ = agent.apply(hook(.done, at: 1), now: time(2))
        #expect(agent.isFresh)
        _ = agent.typed(Data("next step\r".utf8), at: time(3))
        #expect(!agent.isFresh)
        _ = agent.apply(hook(.working, event: "UserPromptSubmit", at: 4), now: time(4))
        _ = agent.apply(hook(.done, at: 5), now: time(5))
        #expect(agent.isFresh)
    }

    @Test func theMostUrgentDotWins() {
        #expect([AgentDot.working, .done, .waiting].max() == .waiting)
        #expect([AgentDot.working, .done].max() == .done)
    }

    @Test func eachStateHasAnActivityType() {
        #expect(ActivityType.agent(.working) == "agent.working")
        #expect(ActivityType.agent(.waiting) == "agent.waiting")
        #expect(ActivityType.agent(.done) == "agent.done")
        #expect(ActivityType.agent(.none) == "agent.cleared")
    }
}
