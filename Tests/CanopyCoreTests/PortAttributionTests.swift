import Foundation
import Testing

@testable import CanopyCore

/// A made-up process tree: each pid's parent and working folder.
struct FakeProcesses {
    var parents: [pid_t: pid_t] = [:]
    var folders: [pid_t: String] = [:]

    func assign(_ ports: [ListeningPort], rows: [String], shells: [String: [pid_t]] = [:]) -> [PortGroup] {
        PortAttribution.assign(
            ports, rows: rows, shells: shells, parent: { parents[$0] }, folder: { folders[$0] })
    }
}

struct PortAttributionTests {
    func port(_ number: UInt16, _ pid: pid_t) -> ListeningPort {
        ListeningPort(port: number, pid: pid, process: "p\(pid)")
    }

    @Test func aProcessStartedInARowsTerminalBelongsToThatRow() {
        // node (300) runs under bun (200) under row a's shell (100), but works in row b's folder.
        let table = FakeProcesses(parents: [300: 200, 200: 100, 100: 1], folders: [300: "/w/b/web"])

        let groups = table.assign([port(3000, 300)], rows: ["/w/a", "/w/b"], shells: ["/w/a": [100]])

        #expect(groups == [PortGroup(rowPath: "/w/a", ports: [port(3000, 300)])])
    }

    @Test func aShellListeningItselfBelongsToItsRow() {
        let table = FakeProcesses(parents: [100: 1])

        let groups = table.assign([port(8080, 100)], rows: ["/w/a"], shells: ["/w/a": [100]])

        #expect(groups.map(\.rowPath) == ["/w/a"])
    }

    @Test func otherwiseTheDeepestRowFolderWins() {
        let table = FakeProcesses(
            parents: [500: 1, 501: 1, 502: 1],
            folders: [500: "/r/main/.claude/worktrees/x/web", 501: "/r/main/src", 502: "/r/main"])

        let groups = table.assign(
            [port(4000, 500), port(4001, 501), port(4002, 502)], rows: ["/r/main", "/r/main/.claude/worktrees/x"])

        #expect(
            groups == [
                PortGroup(rowPath: "/r/main", ports: [port(4001, 501), port(4002, 502)]),
                PortGroup(rowPath: "/r/main/.claude/worktrees/x", ports: [port(4000, 500)]),
            ])
    }

    @Test func portsOutsideEveryRowAreLeftOut() {
        // A folder that only shares a prefix with a row is not inside it.
        let table = FakeProcesses(parents: [600: 1, 601: 1], folders: [600: "/elsewhere", 601: "/w/feat-2"])

        #expect(table.assign([port(5432, 600), port(3000, 601), port(9, 602)], rows: ["/w/feat"]).isEmpty)
    }

    @Test func groupsFollowRowOrderAndPortsSortByNumber() {
        let table = FakeProcesses(parents: [700: 1, 701: 1], folders: [700: "/w/b", 701: "/w/a"])

        let groups = table.assign([port(3001, 700), port(3000, 700), port(4173, 701)], rows: ["/w/a", "/w/b"])

        #expect(groups.map(\.rowPath) == ["/w/a", "/w/b"])
        #expect(groups.last?.ports.map(\.port) == [3000, 3001])
    }

    @Test func aLoopInTheParentsEnds() {
        let table = FakeProcesses(parents: [5: 6, 6: 5], folders: [5: "/w/a"])

        #expect(table.assign([port(3000, 5)], rows: ["/w/a"]).map(\.rowPath) == ["/w/a"])
    }
}
