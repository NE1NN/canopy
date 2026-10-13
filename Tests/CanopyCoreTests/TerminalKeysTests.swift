import Foundation
import Testing

@testable import CanopyCore

struct TerminalKeysTests {
    typealias Press = TerminalKeys.Press

    @Test func commandReturnAndEnterAreOptionReturn() {
        let optionReturn = Press(key: .return, modifiers: [.option])
        #expect(TerminalKeys.substitute(for: Press(key: .return, modifiers: [.command])) == optionReturn)
        #expect(TerminalKeys.substitute(for: Press(key: .keypadEnter, modifiers: [.command])) == optionReturn)
    }

    @Test func otherKeysAndModifiersStayAsTheyAre() {
        let kept: [Press] = [
            Press(key: .return, modifiers: []), Press(key: .return, modifiers: [.option]),
            Press(key: .return, modifiers: [.shift]), Press(key: .return, modifiers: [.command, .shift]),
            Press(key: .return, modifiers: [.command, .option]), Press(key: .return, modifiers: [.command, .control]),
            Press(key: .keypadEnter, modifiers: []), Press(key: .other, modifiers: [.command]),
        ]
        for press in kept {
            #expect(TerminalKeys.substitute(for: press) == nil, "\(press)")
        }
    }
}
