import Foundation
import Testing

@testable import CanopyCore

struct StateStoreTests {
    @Test func missingFileIsFresh() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        #expect(store.load() == .fresh(AppState()))
    }

    @Test func roundTripsAndIsPrivate() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        let state = AppState(
            repos: [
                RepoEntry(
                    path: "/r", dirName: "r", adopted: ["/x"], rowOrder: ["/x"],
                    prBindings: ["someone/feat": PRBinding(number: 7, repo: "acme/app")])
            ],
            selectedRowPath: "/x"
        )

        try store.save(state)

        #expect(store.load() == .loaded(state))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.sub("state.json"))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func toleratesMissingOptionalFields() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"{"version": 1, "repos": [{"path": "/r", "dirName": "r"}]}"#.write(
            to: url, atomically: true, encoding: .utf8)

        #expect(StateStore(url: url).load() == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r")])))
    }

    @Test func groupsRoundTrip() throws {
        let dir = try TempDir()
        let store = StateStore(url: URL(fileURLWithPath: dir.sub("state.json")))
        var entry = RepoEntry(path: "/r", dirName: "r", rowOrder: ["/a"])
        entry.groups = [RowGroup(name: "Review", rows: ["/b", "/c"]), RowGroup(name: "Later", collapsed: true)]
        let state = AppState(repos: [entry])

        try store.save(state)

        #expect(store.load() == .loaded(state))
    }

    @Test func groupsThatCannotBeTrustedAreCleanedOnLoad() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"""
        {"version": 1, "repos": [{"path": "/r", "dirName": "r", "rowOrder": ["/a", "/b"], "groups": [
            {"rows": ["/x"]},
            {"name": "  ", "rows": ["/y"]},
            {"name": " Review ", "rows": ["/b", "/c", "/c"]},
            {"name": "review", "rows": ["/d"], "collapsed": true},
            {"name": "Later", "rows": ["/c", "/e"], "collapsed": true},
            {"name": "Bad\nName", "rows": ["/f"]},
            {"name": "Odd", "rows": ["/g"], "collapsed": "yes"}
        ]}]}
        """#.write(to: url, atomically: true, encoding: .utf8)

        // "review" differs from "Review" only in case, so its rows join the first. "Odd" cannot be read, so it goes alone.
        var expected = RepoEntry(path: "/r", dirName: "r", rowOrder: ["/a"])
        expected.groups = [
            RowGroup(name: "Review", rows: ["/b", "/c", "/d"]), RowGroup(name: "Later", rows: ["/e"], collapsed: true),
        ]
        #expect(StateStore(url: url).load() == .loaded(AppState(repos: [expected])))
    }

    @Test func anUnreadableGroupsListIsDroppedAlone() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"""
        {"version": 1, "repos": [{"path": "/r", "dirName": "r", "adopted": ["/a"], "rowOrder": ["/a"], "groups": 7}]}
        """#.write(to: url, atomically: true, encoding: .utf8)

        #expect(
            StateStore(url: url).load()
                == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r", adopted: ["/a"], rowOrder: ["/a"])])))
    }

    @Test func unreadableBindingsAreDroppedOnTheirOwn() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"{"version": 1, "repos": [{"path": "/r", "dirName": "r", "adopted": ["/x"], "prBindings": {"b": 7}}]}"#
            .write(to: url, atomically: true, encoding: .utf8)

        #expect(
            StateStore(url: url).load()
                == .loaded(AppState(repos: [RepoEntry(path: "/r", dirName: "r", adopted: ["/x"])])))
    }

    @Test func corruptFileIsBackedUp() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try "{not json".write(to: url, atomically: true, encoding: .utf8)

        let result = StateStore(url: url).load(now: Date(timeIntervalSince1970: 1_000))

        #expect(result == .recovered(AppState(), backup: URL(fileURLWithPath: dir.sub("state.json.broken-1000"))))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: dir.sub("state.json.broken-1000")))
    }

    @Test func newerVersionIsBackedUpRatherThanMisread() throws {
        let dir = try TempDir()
        let url = URL(fileURLWithPath: dir.sub("state.json"))
        try #"{"version": 99, "repos": []}"#.write(to: url, atomically: true, encoding: .utf8)

        guard case .recovered = StateStore(url: url).load() else {
            Issue.record("expected recovery")
            return
        }
    }
}
