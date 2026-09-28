import Foundation
import Testing

@testable import CanopyCore

struct RowClassifierTests {
    let classifier = RowClassifier(canopyWorktreesRoot: "/h/.canopy/worktrees", homeDirectory: "/h")

    @Test func mainWinsOverEverything() {
        #expect(classifier.classify(path: "/h/.canopy/worktrees/x", isMain: true, adopted: []) == (.main, nil))
    }

    @Test func canopyFolderIsCanopy() {
        #expect(
            classifier.classify(path: "/h/.canopy/worktrees/demo/fix-a", isMain: false, adopted: []) == (.canopy, nil))
    }

    @Test func adoptedPathIsAdopted() {
        let path = "/h/.superset/worktrees/demo/fix"
        #expect(classifier.classify(path: path, isMain: false, adopted: [path]) == (.adopted, nil))
    }

    @Test func externalPathsAreTagged() {
        #expect(
            classifier.classify(path: "/h/.superset/worktrees/d/x", isMain: false, adopted: []) == (
                .external, .superset
            ))
        #expect(
            classifier.classify(path: "/h/conductor/workspaces/d/x", isMain: false, adopted: []) == (
                .external, .conductor
            ))
        #expect(classifier.classify(path: "/elsewhere/x", isMain: false, adopted: []) == (.external, .other))
    }

    @Test func rowsSkipBareAndFlagMissing() {
        let worktrees = [
            Worktree(path: "/r/main", head: "a", branch: "main"),
            Worktree(path: "/h/.canopy/worktrees/demo/x", head: "b", branch: "x", isPrunable: true),
            Worktree(path: "/r/other", head: "c", branch: "y"),
        ]
        let rows = classifier.rows(for: worktrees, repoPath: "/r/main", adopted: [], fileExists: { $0 != "/r/other" })

        #expect(rows.map(\.rowClass) == [.main, .canopy, .external])
        #expect(rows.map(\.isMissing) == [false, true, true])
    }

    @Test func detachedRowShowsShortHash() {
        let row = Row(repoPath: "/r", path: "/r", branch: nil, head: "abcdef1234", rowClass: .main)
        #expect(row.displayName == "abcdef1")
    }
}

struct RowOrderingTests {
    @Test func keepsOrderAndAppendsNewRows() {
        #expect(RowOrdering.reconcile(order: ["b", "a"], present: ["a", "b", "c"]) == ["b", "a", "c"])
    }

    @Test func dropsRowsThatAreGone() {
        #expect(RowOrdering.reconcile(order: ["a", "b"], present: ["b"]) == ["b"])
    }

    @Test func removesDuplicates() {
        #expect(RowOrdering.reconcile(order: ["a", "a"], present: ["a"]) == ["a"])
    }
}

struct RepoNamingTests {
    @Test func usesFolderNames() {
        #expect(RepoNaming.displayNames(for: ["/a/web", "/b/api"]) == ["/a/web": "web", "/b/api": "api"])
    }

    @Test func disambiguatesDuplicatesWithParent() {
        #expect(
            RepoNaming.displayNames(for: ["/work/app", "/personal/app"])
                == ["/work/app": "work/app", "/personal/app": "personal/app"]
        )
    }

    @Test func goesBackAsManyFoldersAsItTakesToTellReposApart() {
        #expect(
            RepoNaming.displayNames(for: ["/work/client/app", "/personal/client/app", "/other/app", "/web"])
                == [
                    "/work/client/app": "work/client/app", "/personal/client/app": "personal/client/app",
                    "/other/app": "other/app", "/web": "web",
                ]
        )
    }

    @Test func aRepoAtTheTopOfItsDiskKeepsItsOneName() {
        #expect(RepoNaming.displayNames(for: ["/app", "/x/app"]) == ["/app": "app", "/x/app": "x/app"])
    }

    @Test func dirNameAvoidsTakenNames() {
        #expect(RepoNaming.dirName(for: "/x/app", taken: ["app", "app-2"]) == "app-3")
    }
}
