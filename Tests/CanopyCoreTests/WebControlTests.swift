import Foundation
import Testing

@testable import CanopyCore

extension ControlServerTests {
    @Test func webPagesOpenListAndCloseOverTheSocket() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (workspace, server, client, ui) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = TargetHint(repo: "demo", row: "main")
        let page = "http://127.0.0.1:9/page"

        let opened = try await call(
            client, WebMethod.open, WebOpenParams(target: target, url: page), as: WebOpenResult.self)
        #expect(opened == WebOpenResult(page: "w1", placement: .panel, row: "main"))
        let again = try await call(
            client, WebMethod.open, WebOpenParams(target: target, url: page, placement: .tab), as: WebOpenResult.self)
        #expect(again == opened)
        let tab = try await call(
            client, WebMethod.open, WebOpenParams(target: target, url: page + "2", placement: .tab),
            as: WebOpenResult.self)
        #expect(tab.placement == .tab && tab.page == "w2")

        let listed = try await call(client, WebMethod.list, WebListParams(target: target), as: [WebPageInfo].self)
        #expect(listed.map(\.page) == ["w1", "w2"])
        #expect(listed.map(\.placement) == [.panel, .tab])
        #expect(listed.first?.url == page)
        #expect(listed.first?.title == "127.0.0.1")
        #expect(listed.first?.repo == "demo" && listed.first?.row == "main" && listed.first?.rowPath == repo)
        #expect(try await call(client, WebMethod.list, WebListParams(all: true), as: [WebPageInfo].self).count == 2)

        _ = try await call(client, WebMethod.close, WebCloseParams(page: "w1"), as: JSONValue.self)
        let left = try await call(client, WebMethod.list, WebListParams(target: target), as: [WebPageInfo].self)
        #expect(left.map(\.page) == ["w2"])
        // The CLI never changes which row is selected.
        #expect(ui.selected.withLock { $0 }.isEmpty)

        let opens = await logged(workspace, "cli").filter { $0.data["method"] == .string(WebMethod.open) }
        #expect(opens.count == 3)
        #expect(await logged(workspace, "cli").allSatisfy { $0.data["method"] != .string(WebMethod.list) })
    }

    @Test func webMethodsSayWhatIsWrong() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let (_, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        let target = TargetHint(repo: "demo", row: "main")

        for url in ["file:///etc/hosts", "javascript:alert(1)", "example.com", ""] {
            #expect(
                try await error(client, WebMethod.open, try .from(WebOpenParams(target: target, url: url)))
                    == "invalid_url", "\(url)")
        }
        #expect(
            try await error(
                client, WebMethod.open,
                try .from(WebOpenParams(target: TargetHint(repo: "demo", row: "nope"), url: "https://x.dev")))
                == "row_not_found")
        #expect(try await error(client, WebMethod.close, try .from(WebCloseParams(page: "w7"))) == "page_not_found")
        #expect(try await error(client, WebMethod.close, try .from(WebCloseParams(page: "p7"))) == "page_not_found")
    }
}

extension ControlServerTests {
    @Test func webOpenRefusesARowWhoseFolderIsGoneAndAPlacementItDoesNotKnow() async throws {
        let dir = try TempDir()
        let repo = try await Fixture.repo(in: dir)
        let feature = dir.sub("feature")
        try await Fixture.worktree(repo: repo, branch: "feat/gone", at: feature)
        let (workspace, server, client, _) = try await startServer(dir)
        defer { server.stop() }
        _ = try await call(client, ControlMethod.repoAdd, RepoAddParams(path: repo), as: RepoInfo.self)
        _ = try await workspace.adopt(path: Paths.canonical(feature))
        try FileManager.default.removeItem(atPath: feature)
        await workspace.refreshAll()

        #expect(
            try await error(
                client, WebMethod.open,
                try .from(WebOpenParams(target: TargetHint(repo: "demo", row: "feat/gone"), url: "https://x.dev")))
                == "path_not_found")
        let window: JSONValue = .object([
            "url": "https://x.dev", "placement": "window", "target": try .from(TargetHint(repo: "demo", row: "main")),
        ])
        #expect(try await error(client, WebMethod.open, window) == "bad_params")
    }
}

extension PluginControlTests {
    @Test func aPluginRowShowsPagesAndTheyGoWithIt() async throws {
        let dir = try TempDir()
        let setup = try await start(dir)
        defer { stop(setup) }
        let row = try await newRow(setup, "i1")

        // From a terminal in the plugin row, which knows its row only by CANOPY_ROW_PATH.
        let opened = try await call(
            setup, WebMethod.open, WebOpenParams(target: TargetHint(envRowPath: row.path), url: "https://x.dev/a"),
            as: WebOpenResult.self)
        #expect(opened.row == row.displayName)
        let listed = try await call(setup, WebMethod.list, WebListParams(all: true), as: [WebPageInfo].self)
        #expect(listed.map(\.plugin) == ["t"] && listed.map(\.repo) == [nil] && listed.map(\.rowPath) == [row.path])

        _ = try await call(
            setup, ControlMethod.rowRemove, RowRemoveParams(target: TargetHint(row: row.path)), as: RowRemoveResult.self
        )
        #expect(try await call(setup, WebMethod.list, WebListParams(all: true), as: [WebPageInfo].self).isEmpty)
    }
}
