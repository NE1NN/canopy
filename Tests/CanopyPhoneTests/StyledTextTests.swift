import Testing

@testable import CanopyPhone

struct StyledTextTests {
    @Test func plainTextIsOneRun() {
        #expect(StyledText.runs("hello world") == [StyledRun(text: "hello world", style: TerminalStyle())])
        #expect(StyledText.runs("") == [])
    }

    @Test func boldAndColoredRuns() {
        let runs = StyledText.runs("\u{1b}[0;1;34m⏺\u{1b}[0m The phone \u{1b}[0;33mQUESTION:\u{1b}[0m")
        #expect(
            runs == [
                StyledRun(text: "⏺", style: TerminalStyle(foreground: .ansi(4), bold: true)),
                StyledRun(text: " The phone ", style: TerminalStyle()),
                StyledRun(text: "QUESTION:", style: TerminalStyle(foreground: .ansi(3))),
            ])
    }

    @Test func brightExtendedAndTrueColors() {
        let runs = StyledText.runs("\u{1b}[0;91;102ma\u{1b}[0;38;5;208;48;5;17mb\u{1b}[0;38;2;10;20;30mc")
        #expect(runs.map(\.style.foreground) == [.ansi(9), .ansi(208), .rgb(10, 20, 30)])
        #expect(runs.map(\.style.background) == [.ansi(10), .ansi(17), nil])
    }

    @Test func everyStyleAndItsReset() {
        let on = StyledText.runs("\u{1b}[1;2;3;4;7;9mx")
        #expect(
            on.first?.style
                == TerminalStyle(bold: true, dim: true, italic: true, underline: true, inverse: true, crossedOut: true))
        let off = StyledText.runs("\u{1b}[1;2;3;4;7;9;31;41m\u{1b}[22;23;24;27;29;39;49mx")
        #expect(off.first?.style == TerminalStyle())
        #expect(StyledText.runs("\u{1b}[31ma\u{1b}[mb").map(\.style.foreground) == [.ansi(1), nil])
    }

    @Test func sameStylesJoinAndOtherSequencesAreDropped() {
        #expect(
            StyledText.runs("\u{1b}[31ma\u{1b}[31mb\u{1b}[2Kc") == [
                StyledRun(text: "abc", style: TerminalStyle(foreground: .ansi(1)))
            ])
    }

    @Test func aSequenceCutOffAtTheEndIsDropped() {
        #expect(StyledText.runs("abc\u{1b}[0;3") == [StyledRun(text: "abc", style: TerminalStyle())])
        #expect(StyledText.runs("abc\u{1b}") == [StyledRun(text: "abc", style: TerminalStyle())])
        #expect(StyledText.runs("\u{1b}[38;5ma").first?.style == TerminalStyle())
    }
}
