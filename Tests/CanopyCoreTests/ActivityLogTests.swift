import Foundation
import Testing

@testable import CanopyCore

/// The lines of every activity file in `folder`, oldest file first.
func activityLines(_ folder: URL) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return files.sorted().flatMap { file in
        ((try? String(contentsOf: folder.appending(path: file), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

func activityEvents(_ folder: URL) -> [ActivityEvent] {
    activityLines(folder).compactMap { try? JSONDecoder().decode(ActivityEvent.self, from: Data($0.utf8)) }
}

struct ActivityLogTests {
    @Test func writesOneLineInTheSpecsFieldOrder() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        log.record(
            ActivityType.rowCreated, repo: "demo", row: "fix/login", path: "/w/fix-login", source: .cli,
            data: ["class": "canopy"])
        await log.flush()

        let line = try #require(activityLines(log.folder).first)
        #expect(activityLines(log.folder).count == 1)
        let keys = ["ts", "type", "repo", "row", "path", "source", "data"].map { "\"\($0)\":" }
        let positions = try keys.map { key in try #require(line.range(of: key)).lowerBound }
        #expect(positions == positions.sorted())
        #expect(line.contains(#""source":"cli","data":{"class":"canopy"}}"#))
        let event = try #require(activityEvents(log.folder).first)
        #expect(event.ts.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}([+-]\d\d:\d\d|Z)/) != nil)
        #expect(event.date != nil)
        #expect(event.type == "row.created" && event.repo == "demo" && event.row == "fix/login")
    }

    @Test func leavesOutWhatAnEventIsNotAbout() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        log.record(ActivityType.cliCall, data: ["method": "term.send"])
        await log.flush()

        let line = try #require(activityLines(log.folder).first)
        #expect(!line.contains("\"repo\"") && !line.contains("\"row\"") && !line.contains("\"path\""))
    }

    @Test func filesAreNamedByLocalDateAndPrivate() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))
        let date = try #require(
            Calendar.localGregorian().date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 23)))

        log.record(ActivityType.repoAdded, repo: "demo", at: date)
        log.record(ActivityType.repoRemoved, repo: "demo", at: date.addingTimeInterval(3600))
        await log.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: log.folder.path).sorted()
        #expect(files == ["2026-09-27.jsonl", "2026-09-28.jsonl"])
        let file = try FileManager.default.attributesOfItem(atPath: log.folder.appending(path: files[0]).path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: log.folder.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func sourceIsTheUIUnlessACallerSaysOtherwise() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        log.record(ActivityType.repoAdded)
        await ActivitySource.$current.withValue(.cli) {
            log.record(ActivityType.repoAdded)
            // Work a CLI request starts later, such as setup finishing, keeps its source.
            await Task { log.record(ActivityType.repoAdded) }.value
        }
        await log.flush()

        #expect(activityEvents(log.folder).map(\.source) == [.ui, .cli, .cli])
    }

    @MainActor
    @Test func keepsTheOrderEventsWereRecordedIn() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")))

        for number in 0..<200 {
            log.record(ActivityType.termOpened, data: ["pane": .string("p\(number)")])
        }
        await log.flush()

        #expect(activityEvents(log.folder).map(\.data["pane"]) == (0..<200).map { .string("p\($0)") })
    }

    @Test func commandsAreLeftOutWhenCommandLoggingIsOff() async throws {
        let dir = try TempDir()
        let log = ActivityLog(folder: URL(fileURLWithPath: dir.sub("activity")), logsCommands: false)

        log.record(ActivityType.termCommand, data: ["cmd": "export TOKEN=secret"])
        log.record(ActivityType.termExited, data: ["pane": "p1", "code": 0])
        await log.flush()

        #expect(activityEvents(log.folder).map(\.type) == ["term.exited"])
    }

    @Test func commandLoggingIsOnUnlessConfigTurnsItOff() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("config.json"))
        #expect(GlobalConfig.load(from: url).logCommands)

        try #"{"logCommands": false}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(!GlobalConfig.load(from: url).logCommands)
        #expect(GlobalConfig.load(from: url).minPaneColumns == 80)
    }
}
