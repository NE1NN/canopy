import Foundation
import Testing

@testable import CanopyCore

struct ActivityReaderTests {
    static var calendar: Calendar { .localGregorian() }

    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func write(_ lines: [String], to folder: URL, day: String, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: folder.appending(path: "\(day).jsonl"), atomically: true, encoding: .utf8)
    }

    func line(_ type: String, at date: Date, data: [String: JSONValue] = [:]) throws -> String {
        try ActivityEvent(date: date, type: type, source: .git, data: data).jsonLine()
    }

    @Test func readsEventsInOrderAcrossDays() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        try write([try line("row.created", at: Self.date(27, 23))], to: folder, day: "2026-09-27")
        try write([try line("row.removed", at: Self.date(28, 1))], to: folder, day: "2026-09-28")

        let events = ActivityReader.events(in: folder, since: Self.date(27, 22), until: nil)

        #expect(events.map(\.type) == ["row.created", "row.removed"])
    }

    @Test func skipsAPartialLastLineAndLinesItCannotRead() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        let lines = [
            try line("row.created", at: Self.date(28, 1)), "not json", #"{"ts": "2026-09-28T01:00:00.000+10:00"}"#,
            try line("row.removed", at: Self.date(28, 2)), #"{"ts":"2026-09-28T03:0"#,
        ]
        try write(lines, to: folder, day: "2026-09-28", trailingNewline: false)

        let events = ActivityReader.events(in: folder, since: Self.date(27, 0), until: nil)

        #expect(events.map(\.type) == ["row.created", "row.removed"])
    }

    @Test func filtersByTimeAndType() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        let lines = [
            try line("row.created", at: Self.date(28, 1)), try line("term.command", at: Self.date(28, 2)),
            try line("row.removed", at: Self.date(28, 3)), try line("row.branch_changed", at: Self.date(28, 4)),
        ]
        try write(lines, to: folder, day: "2026-09-28")
        let read = { (since: Date, until: Date?, types: [String]) in
            ActivityReader.events(in: folder, since: since, until: until, types: types).map(\.type)
        }

        #expect(read(Self.date(28, 2), nil, []) == ["term.command", "row.removed", "row.branch_changed"])
        #expect(read(Self.date(28, 0), Self.date(28, 3), []) == ["row.created", "term.command"])
        #expect(read(Self.date(28, 0), nil, ["row"]) == ["row.created", "row.removed", "row.branch_changed"])
        #expect(read(Self.date(28, 0), nil, ["term.command", "row.removed"]) == ["term.command", "row.removed"])
        #expect(read(Self.date(28, 0), nil, ["row.cr"]).isEmpty)
    }

    @Test func eventsComeOutInTimeOrder() throws {
        let dir = try TempDir()
        let folder = URL(fileURLWithPath: dir.sub("activity"))
        // After moving west, events land in the file of a date that has already passed elsewhere.
        try write([try line("row.removed", at: Self.date(28, 3))], to: folder, day: "2026-09-27")
        try write([try line("row.created", at: Self.date(28, 1))], to: folder, day: "2026-09-28")

        let events = ActivityReader.events(in: folder, since: Self.date(27, 0), until: nil)

        #expect(events.map(\.type) == ["row.created", "row.removed"])
    }

    @Test func aMissingFolderHasNoEvents() throws {
        let dir = try TempDir()

        #expect(
            ActivityReader.events(in: URL(fileURLWithPath: dir.sub("none")), since: .distantPast, until: nil).isEmpty)
    }

    @Test func readsTheTimesPeopleType() throws {
        let now = Self.date(28, 15, 45)
        let parse = { (text: String) in try LogTime.parse(text, now: now) }

        #expect(try parse("30m") == now.addingTimeInterval(-1800))
        #expect(try parse("45s") == now.addingTimeInterval(-45))
        #expect(try parse("2h") == now.addingTimeInterval(-7200))
        #expect(try parse("3d") == Self.calendar.date(byAdding: .day, value: -3, to: now))
        #expect(try parse("1w") == Self.calendar.date(byAdding: .day, value: -7, to: now))
        #expect(try parse("now") == now)
        #expect(try parse("today") == Self.date(28, 0))
        #expect(try parse("yesterday") == Self.date(27, 0))
        #expect(try parse("2026-09-27") == Self.date(27, 0))
        #expect(try parse("2026-09-27T14:30") == Self.date(27, 14, 30))
        #expect(try parse("2026-09-27 14:30:15") == Self.date(27, 14, 30).addingTimeInterval(15))
        #expect(try parse("9:05") == Self.date(28, 9, 5))
        #expect(try parse("2026-09-27T11:15:03Z") == Date(timeIntervalSince1970: 1_790_507_703))
        #expect(try parse("2026-09-27T21:15:03.500+10:00") == Date(timeIntervalSince1970: 1_790_507_703.5))
        // Days that start with the clocks going forward, when midnight or 2:30 never happens.
        let santiago = try #require(TimeZone(identifier: "America/Santiago"))
        let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
        let noMidnight = try LogTime.parse("2026-09-06", now: now, timeZone: santiago)
        #expect(
            Calendar.localGregorian(in: santiago).dateComponents([.day, .hour], from: noMidnight)
                == .init(day: 6, hour: 1))
        let noHalfPastTwo = try LogTime.parse("2026-10-04T02:30", now: now, timeZone: sydney)
        #expect(
            Calendar.localGregorian(in: sydney).dateComponents([.day, .hour], from: noHalfPastTwo)
                == .init(day: 4, hour: 3))
        for text in ["soon", "2026-13-01", "2026-09-31", "25:00", "9:60", "9:5", "30", "-2h"] {
            #expect(throws: LogTimeError.self, "\(text)") { try parse(text) }
        }
    }

    @Test func eachKindOfEventReadsAsOneLine() {
        let date = Self.date(28, 14, 2)
        let summary = { (type: String, data: [String: JSONValue]) in
            ActivityEvent(date: date, type: type, path: "/r/demo", source: .ui, data: data).summary
        }

        #expect(summary("repo.added", [:]) == "/r/demo")
        #expect(summary("row.created", ["class": "canopy"]) == "canopy")
        #expect(summary("row.branch_changed", ["from": "feat/y", "to": .null]) == "feat/y -> detached")
        #expect(
            summary("pr.opened", ["number": 12, "title": "Fix it", "state": "draft", "url": "https://x/12"])
                == "#12 draft: Fix it https://x/12")
        #expect(summary("pr.state_changed", ["number": 12, "from": "open", "to": "merged"]) == "#12 open -> merged")
        #expect(summary("term.opened", ["pane": "p3"]) == "p3")
        #expect(summary("term.exited", ["pane": "p3", "code": 129]) == "p3 exit 129")
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "make\nmake test", "exit": 2, "durationMs": 83_250])
                == "p3 exit 2 in 1m23s: make \u{21b5} make test")
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "ls", "exit": 0, "durationMs": 45]) == "p3 exit 0 in 45ms: ls"
        )
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "printf 'a\tb\u{1b}[31m'", "exit": 0])
                == "p3 exit 0: printf 'a b^[[31m'")
        #expect(
            summary("term.command", ["pane": "p3", "cmd": "ls", "exit": 0, "durationMs": 1240])
                == "p3 exit 0 in 1.2s: ls")
        #expect(
            summary(
                "cli.call",
                [
                    "method": "row.new", "error": "invalid_branch",
                    "params": .object(["branch": "bad name", "target": .object(["cwd": "/"])]),
                ]) == #"row.new {"branch":"bad name"} failed: invalid_branch"#)
        #expect(ActivityEvent(date: date, type: "x", source: .ui).localTime == "2026-09-28 14:02:00")
    }
}
