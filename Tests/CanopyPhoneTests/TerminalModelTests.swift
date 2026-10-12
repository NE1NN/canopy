import CanopyWire
import Foundation
import Testing

@testable import CanopyPhone

@MainActor
struct TerminalModelTests {
    let mac = FakeMac()

    func serveScreen(scrollback: [String] = ["old 1", "old 2"], lines: [String] = ["$ make test", ""]) {
        mac.on(PhoneMethod.screen) { request in
            let screen = PhoneScreen(pane: "p3", columns: 120, rows: 2, scrollback: scrollback, lines: lines)
            return .result((try? .from(screen)) ?? .null)
        }
        mac.on(PhoneMethod.keys) { .result($0.params ?? .null) }
    }

    func model(sleeper: ManualSleeper = ManualSleeper()) async throws -> (TerminalModel, MacConnection) {
        let connection = try await connected(
            to: mac, inbox: ConversationModelTests.inbox(ConversationModelTests.waiting), sleeper: sleeper)
        let model = TerminalModel(connection: connection, pane: "p3")
        model.start()
        return (model, connection)
    }

    var sentKeys: String {
        mac.requests.filter { $0.method == PhoneMethod.keys }.compactMap {
            try? $0.decodeParams(PhoneKeysParams.self).text
        }
        .joined()
    }

    @Test func theFirstScreenWithItsScrollbackThenScreensReplacingTheVisibleLines() async throws {
        serveScreen()
        let (model, _) = try await model()
        #expect(await eventually { model.lineCount == 4 })
        #expect(model.columns == 120)
        #expect(model.lines.map { $0.map(\.text).joined() } == ["old 1", "old 2", "$ make test", ""])
        let request = try #require(await mac.request(PhoneMethod.screen))
        mac.emit(
            PhoneEvent.screen, subscription: request.id,
            PhoneScreen(pane: "p3", columns: 100, rows: 2, lines: ["412 passed", "$ "]))
        #expect(await eventually { model.lines.last?.first?.text == "$ " })
        #expect(model.lines.map { $0.map(\.text).joined() } == ["old 1", "old 2", "412 passed", "$ "])
        #expect(model.columns == 100)
    }

    @Test func ctrlTurnsTheNextLetterIntoItsControlCharacterOnce() async throws {
        serveScreen()
        let (model, _) = try await model()
        model.ctrl = true
        model.type("c")
        #expect(!model.ctrl)
        model.type("c")
        model.ctrl = true
        model.type("[")
        #expect(await eventually { sentKeys == "\u{03}c\u{1b}" })
    }

    @Test func keysGoInTheOrderTyped() async throws {
        serveScreen()
        let (model, _) = try await model()
        for character in "make test" {
            model.type(String(character))
        }
        model.press(.enter)
        #expect(await eventually { sentKeys == "make test\r" })
    }

    @Test func theKeyBarSendsItsSequences() async throws {
        serveScreen()
        let (model, _) = try await model()
        for key in [TerminalKey.escape, .tab, .up, .down, .left, .right, .enter] {
            model.press(key)
        }
        model.backspace()
        model.type("\n")
        #expect(await eventually { sentKeys == "\u{1b}\t\u{1b}[A\u{1b}[B\u{1b}[D\u{1b}[C\r\u{7f}\r" })
    }

    @Test func aTerminalWatchesAgainAfterTheMacComesBack() async throws {
        serveScreen()
        let (model, connection) = try await model()
        #expect(await eventually { model.lineCount == 4 })
        mac.goAway()
        #expect(await eventually { connection.isUnreachable })
        serveScreen(scrollback: ["old 1", "old 2", "$ make test"], lines: ["412 passed", "$ "])
        mac.comeBack()
        connection.foreground()
        #expect(await eventually { model.lines.last?.first?.text == "$ " })
        #expect(model.lineCount == 5)
        #expect(mac.requests.filter { $0.method == PhoneMethod.screen }.count == 2)
    }

    @Test func aPaneThatClosedSaysSo() async throws {
        mac.on(PhoneMethod.screen) { _ in .error("pane_not_found") }
        let (model, _) = try await model()
        #expect(await eventually { model.problem?.title == "This pane closed." })
    }

    @Test func keysThatFailSayWhy() async throws {
        serveScreen()
        mac.on(PhoneMethod.keys) { _ in .error("pane_not_found") }
        let (model, _) = try await model()
        model.type("x")
        #expect(await eventually { model.problem?.title == "This pane closed." })
    }

    @Test func stoppingUnsubscribes() async throws {
        serveScreen()
        let (model, _) = try await model()
        #expect(await eventually { model.lineCount == 4 })
        let request = try #require(await mac.request(PhoneMethod.screen))
        model.stop()
        let unsubscribe = try #require(await mac.request(PhoneMethod.unsubscribe))
        #expect(try unsubscribe.decodeParams(PhoneUnsubscribeParams.self).subscription == request.id)
    }
}
