import Foundation
import Testing

@testable import CanopyCore

struct TerminalKeysTests {
    @Test func commandReturnIsOptionReturn() {
        #expect(TerminalKeys.substituteModifiers(key: .return, modifiers: [.command]) == [.option])
        #expect(TerminalKeys.substituteModifiers(key: .keypadEnter, modifiers: [.command]) == [.option])
    }

    @Test func otherKeysAndModifiersStayAsTheyAre() {
        #expect(TerminalKeys.substituteModifiers(key: .return, modifiers: []) == nil)
        #expect(TerminalKeys.substituteModifiers(key: .return, modifiers: [.option]) == nil)
        #expect(TerminalKeys.substituteModifiers(key: .return, modifiers: [.shift]) == nil)
        #expect(TerminalKeys.substituteModifiers(key: .return, modifiers: [.command, .shift]) == nil)
        #expect(TerminalKeys.substituteModifiers(key: .return, modifiers: [.command, .option]) == nil)
        #expect(TerminalKeys.substituteModifiers(key: .return, modifiers: [.command, .control]) == nil)
        #expect(TerminalKeys.substituteModifiers(key: .other, modifiers: [.command]) == nil)
    }
}
