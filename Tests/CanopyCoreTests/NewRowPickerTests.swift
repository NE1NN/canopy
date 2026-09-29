import Foundation
import Synchronization
import Testing

@testable import CanopyCore

/// Opens once `open()` is called, or after 20 seconds, so a test that fails first never leaves a task waiting forever.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        Task {
            try? await Task.sleep(for: .seconds(20))
            self.open()
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// Lists for the picker, with gates that hold back an answer until the test opens them.
final class FakeLists: Sendable {
    struct State {
        var pullRequests: Result<[ListedPullRequest], WorkspaceError> = .success([])
        var lookups: [String: [ListedPullRequest]] = [:]
        var lookupGates: [String: Gate] = [:]
        /// Lookups that fail once, then answer from `lookups`.
        var lookupFailures: [String: WorkspaceError] = [:]
        var local = BranchListing(branches: [], defaultBase: "origin/main")
        var fetched: BranchListing?
        var fetchGate: Gate?
        var pullRequestGate: Gate?
        var queries: [String?] = []
    }

    let state = Mutex(State())

    var sources: NewRowPicker.Sources {
        NewRowPicker.Sources(
            pullRequests: { query in
                let (gate, result) = self.state.withLock { state in
                    state.queries.append(query)
                    guard let query else { return (state.pullRequestGate, state.pullRequests) }
                    if let failure = state.lookupFailures.removeValue(forKey: query) {
                        return (state.lookupGates[query], .failure(failure))
                    }
                    let found = state.lookups[query.trimmingCharacters(in: .whitespaces)] ?? []
                    return (state.lookupGates[query], state.pullRequests.map { _ in found })
                }
                await gate?.wait()
                return try result.get()
            },
            branches: { fetch in
                let (gate, listing) = self.state.withLock { state in
                    fetch ? (state.fetchGate, state.fetched ?? state.local) : (nil, state.local)
                }
                await gate?.wait()
                return listing
            })
    }

    var queries: [String?] { state.withLock { $0.queries } }
}

@MainActor
struct NewRowPickerTests {
    func pr(
        _ number: Int, _ title: String = "PR", head: String, author: String? = "alice", state: PRState = .open,
        row: BranchHolder? = nil
    ) -> ListedPullRequest {
        ListedPullRequest(
            number: number, title: title, url: "https://github.com/acme/app/pull/\(number)", state: state,
            author: author, headBranch: head, isFork: false, updatedAt: "2026-09-28T00:00:00Z", row: row)
    }

    func branch(_ name: String, _ location: BranchLocation = .both, row: BranchHolder? = nil) -> ListedBranch {
        ListedBranch(
            name: name, location: location, ahead: location == .both ? 0 : nil, behind: location == .both ? 0 : nil,
            committedAt: "2026-09-28T00:00:00Z", row: row)
    }

    func listing(_ branches: [ListedBranch], warnings: [String] = []) -> BranchListing {
        BranchListing(branches: branches, defaultBase: "origin/main", warnings: warnings)
    }

    func makePicker(_ lists: FakeLists) -> NewRowPicker {
        NewRowPicker(sources: lists.sources, lookupDelay: .zero)
    }

    func ids(_ items: [NewRowItem]) -> [String] {
        items.map(\.id)
    }

    @Test func showsLocalBranchesBeforeTheFetchFinishes() async throws {
        let lists = FakeLists()
        let gate = Gate()
        lists.state.withLock {
            $0.local = listing([branch("main")])
            $0.fetched = listing([branch("feat/pushed", .origin), branch("main")])
            $0.fetchGate = gate
        }
        let picker = makePicker(lists)

        let loading = Task { await picker.load() }

        #expect(await eventually { picker.isFetching })
        #expect(ids(picker.branchItems) == ["branch/main"])
        await gate.open()
        await loading.value
        #expect(!picker.isFetching)
        #expect(ids(picker.branchItems) == ["branch/feat/pushed", "branch/main"])
    }

    @Test func filtersBothSectionsAsYouType() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([
                pr(12, "Round cart totals", head: "fix/cart"), pr(7, "Keep the page", head: "feat/login"),
            ])
            $0.local = listing([branch("fix/cart"), branch("feat/login"), branch("main")])
        }
        let picker = makePicker(lists)
        await picker.load()

        #expect(ids(picker.pullRequestItems) == ["pr/12", "pr/7"])
        #expect(ids(picker.branchItems) == ["branch/fix/cart", "branch/feat/login", "branch/main"])
        #expect(picker.newBranchItem == nil)

        picker.text = "cart"
        #expect(ids(picker.pullRequestItems) == ["pr/12"])
        #expect(ids(picker.branchItems) == ["branch/fix/cart"])
        #expect(picker.newBranchItem == .newBranch("cart"))
        #expect(ids(picker.items) == ["pr/12", "branch/fix/cart", "new"])

        picker.text = "alice page"
        #expect(ids(picker.pullRequestItems) == ["pr/7"])
        #expect(picker.branchItems.isEmpty)
        #expect(picker.branchNote == .init(kind: .info, text: "No branches match."))
    }

    @Test func aPullRequestNumberIsLookedUpWhenItIsNotListed() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([pr(12, head: "fix/cart")])
            $0.lookups = [
                "#40": [pr(40, head: "feat/old", state: .closed)],
                "https://github.com/acme/app/pull/12": [pr(12, head: "fix/cart")],
            ]
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "#12"
        #expect(ids(picker.pullRequestItems) == ["pr/12"])
        #expect(lists.queries == [nil])

        picker.text = "#40"
        #expect(picker.pullRequestNote == .init(kind: .loading, text: "Looking up #40…"))
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/40"] })
        #expect(picker.pullRequestNote == nil)

        picker.text = "41"
        #expect(await eventually { picker.pullRequestNote == .init(kind: .info, text: "No pull request #41.") })
        #expect(picker.pullRequestItems.isEmpty)

        picker.text = "https://github.com/acme/app/pull/12"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/12"] })
        #expect(lists.queries == [nil, "#40", "41", "https://github.com/acme/app/pull/12"])
    }

    @Test func anOlderLookupNeverReplacesANewerOne() async throws {
        let lists = FakeLists()
        let gate = Gate()
        lists.state.withLock {
            $0.lookups = ["#1": [pr(1, head: "feat/one")], "#12": [pr(12, head: "feat/twelve")]]
            $0.lookupGates = ["#1": gate]
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "#1"
        #expect(await eventually { lists.queries.contains("#1") })
        picker.text = "#12"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/12"] })
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ids(picker.pullRequestItems) == ["pr/12"])

        picker.text = "#1"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/1"] })
        #expect(lists.queries.filter { $0 == "#1" }.count == 1)
    }

    @Test func aLookupAKeystrokeMadeUnnecessaryNeverStarts() async throws {
        let lists = FakeLists()
        let picker = NewRowPicker(sources: lists.sources, lookupDelay: .milliseconds(300))
        await picker.load()

        picker.text = "#1"
        picker.text = "#12"
        picker.text = "#123"

        #expect(await eventually { lists.queries.count == 2 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(lists.queries == [nil, "#123"])
    }

    @Test func theNewBranchLineOnlyShowsForAnUnmatchedValidName() async throws {
        let lists = FakeLists()
        lists.state.withLock { $0.local = listing([branch("feat/login")]) }
        let picker = makePicker(lists)
        await picker.load()

        for (text, shown) in [
            ("feat/new", true), (" feat/new ", true), ("12", false), ("feat/login", false), ("", false),
            ("bad name", false), ("#12", false), ("feat/x.lock", false), ("https://github.com/acme/app/pull/1", false),
        ] {
            picker.text = text
            #expect((picker.newBranchItem != nil) == shown, "\(text)")
        }
        picker.text = " feat/new "
        #expect(picker.newBranchItem == .newBranch("feat/new"))
    }

    @Test func aNameInAnotherCaseIsNotNew() async throws {
        let lists = FakeLists()
        lists.state.withLock { $0.local = listing([branch("feat/login-page"), branch("feat/login")]) }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "Feat/Login"

        #expect(picker.newBranchItem == nil)
        #expect(ids(picker.branchItems) == ["branch/feat/login", "branch/feat/login-page"])
        #expect(picker.selectedItem?.id == "branch/feat/login")
    }

    @Test func nothingIsSelectedUntilYouType() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([pr(12, head: "fix/cart")])
            $0.local = listing([branch("main")])
        }
        let picker = makePicker(lists)
        await picker.load()

        #expect(picker.selectedItem == nil)
        #expect(picker.selectedAction == nil)
        picker.text = "m"
        #expect(picker.selectedItem?.id == "branch/main")
        picker.text = ""
        #expect(picker.selectedItem == nil)
        picker.moveSelection(by: 1)
        #expect(picker.selectedItem?.id == "pr/12")
    }

    @Test func arrowsMoveTheSelectionAndStopAtTheEnds() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .success([pr(12, head: "fix/cart")])
            $0.local = listing([branch("feat/a"), branch("feat/b")])
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.moveSelection(by: -1)
        #expect(picker.selectedItem?.id == "branch/feat/b")
        picker.text = "f"
        #expect(picker.selectedItem?.id == "pr/12")
        picker.moveSelection(by: 1)
        #expect(picker.selectedItem?.id == "branch/feat/a")
        picker.moveSelection(by: 10)
        #expect(picker.selectedItem?.id == "new")
        picker.moveSelection(by: -10)
        #expect(picker.selectedItem?.id == "pr/12")
        picker.select("branch/feat/b")
        #expect(picker.selectedItem?.id == "branch/feat/b")
    }

    @Test func anExplicitSelectionStaysPutWhenTheListRefreshes() async throws {
        let lists = FakeLists()
        let prGate = Gate()
        let fetchGate = Gate()
        lists.state.withLock {
            $0.pullRequests = .success([pr(3, head: "feat/c")])
            $0.pullRequestGate = prGate
            $0.local = listing([branch("feat/a"), branch("feat/b")])
            $0.fetched = listing([branch("feat/new", .origin), branch("feat/a"), branch("feat/b")])
            $0.fetchGate = fetchGate
        }
        let picker = makePicker(lists)
        let loading = Task { await picker.load() }
        #expect(await eventually { picker.isFetching })

        picker.text = "feat"
        #expect(picker.selectedItem?.id == "branch/feat/a")
        picker.moveSelection(by: 1)
        #expect(picker.selectedItem?.id == "branch/feat/b")
        await prGate.open()
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/3"] })
        #expect(picker.selectedItem?.id == "branch/feat/b")
        await fetchGate.open()
        await loading.value
        #expect(ids(picker.branchItems).first == "branch/feat/new")
        #expect(picker.selectedItem?.id == "branch/feat/b")

        // A picked item that goes away gives way to the best match.
        lists.state.withLock { $0.fetched = listing([branch("feat/a")]) }
        await picker.refreshBranches()
        #expect(picker.selectedItem?.id == "pr/3")
    }

    @Test func theAutomaticSelectionFollowsTheBestMatch() async throws {
        let lists = FakeLists()
        let prGate = Gate()
        let lookupGate = Gate()
        lists.state.withLock {
            $0.pullRequests = .success([pr(145, "Fix the main menu", head: "feat/menu"), pr(3, head: "feat/c")])
            $0.pullRequestGate = prGate
            $0.lookups = ["139": [pr(139, head: "fix/old", state: .closed)]]
            $0.lookupGates = ["139": lookupGate]
            $0.local = listing([branch("feat/menu"), branch("main")])
        }
        let picker = makePicker(lists)
        let loading = Task { await picker.load() }
        #expect(await eventually { !picker.branchItems.isEmpty })

        // Partial text selects the first item, and follows the first item as answers arrive.
        picker.text = "feat"
        #expect(picker.selectedItem?.id == "branch/feat/menu")
        // A PR number typed before the open PRs arrive offers nothing to create by mistake.
        picker.text = "145"
        #expect(picker.items.isEmpty && picker.selectedItem == nil)
        await prGate.open()
        await loading.value
        #expect(picker.selectedItem?.id == "pr/145")
        picker.text = "feat"
        #expect(picker.selectedItem?.id == "pr/145")

        // A closed PR's number, whose lookup answers late.
        picker.text = "139"
        #expect(picker.items.isEmpty && picker.selectedItem == nil)
        await lookupGate.open()
        #expect(await eventually { picker.selectedItem?.id == "pr/139" })

        // A branch named exactly what was typed, in any case, beats a PR that only mentions it.
        picker.text = "MAIN"
        #expect(ids(picker.items).first == "pr/145")
        #expect(picker.selectedItem?.id == "branch/main")
    }

    @Test func aNumberIsLookedUpOnceHoweverItIsTyped() async throws {
        let lists = FakeLists()
        lists.state.withLock { $0.lookups = ["40": [pr(40, head: "feat/old", state: .closed)]] }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "40"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/40"] })
        picker.text = "#40"
        #expect(ids(picker.pullRequestItems) == ["pr/40"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(lists.queries == [nil, "40"])
    }

    @Test func aFailedLookupIsTriedAgain() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.lookups = ["#40": [pr(40, head: "feat/old", state: .closed)]]
            $0.lookupFailures = ["#40": .ghFailed("gh did not answer in time.")]
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "#40"
        #expect(
            await eventually {
                picker.pullRequestNote
                    == .init(kind: .warning, text: "Pull requests did not load: gh did not answer in time.")
            })
        picker.text = "#4"
        picker.text = "#40"
        #expect(await eventually { ids(picker.pullRequestItems) == ["pr/40"] })
        #expect(lists.queries.filter { $0 == "#40" }.count == 2)
    }

    @Test func eachItemMapsToOneCommand() {
        let row = BranchHolder(path: "/w/feat-x", branch: "feat/x", rowClass: .canopy)
        let main = BranchHolder(path: "/r/app", branch: "main", rowClass: .main)
        let other = BranchHolder(path: "/tmp/my worktree", branch: "feat/z", rowClass: .external)
        let cases: [(NewRowItem, String?, NewRowAction, String)] = [
            (.pullRequest(pr(12, head: "fix/cart")), nil, .pullRequest(12), "canopy row new --pr 12 --repo web-app"),
            (.branch(branch("feat/y")), nil, .branch("feat/y"), "canopy row new feat/y --existing --repo web-app"),
            (.newBranch("feat/n"), nil, .newBranch("feat/n", base: nil), "canopy row new feat/n --repo web-app"),
            (
                .newBranch("feat/n"), "origin/dev", .newBranch("feat/n", base: "origin/dev"),
                "canopy row new feat/n --from origin/dev --repo web-app"
            ),
            (.branch(branch("feat/x", row: row)), nil, .selectRow(row), "canopy row select feat/x --repo web-app"),
            (
                .pullRequest(pr(9, head: "feat/x", row: row)), nil, .selectRow(row),
                "canopy row select feat/x --repo web-app"
            ),
            (.branch(branch("main", row: main)), nil, .selectRow(main), "canopy row select main --repo web-app"),
            (.branch(branch("feat/z", row: other)), nil, .adopt(other), "canopy row adopt '/tmp/my worktree'"),
        ]
        for (item, base, action, command) in cases {
            #expect(item.action(base: base) == action, "\(item.id)")
            #expect(action.command(repo: "web-app") == command)
        }
        #expect(NewRowAction.pullRequest(1).createsRow && NewRowAction.newBranch("x", base: nil).createsRow)
        #expect(!NewRowAction.selectRow(row).createsRow && !NewRowAction.adopt(other).createsRow)
        #expect(
            NewRowAction.branch("it's").command(repo: "a b") == #"canopy row new 'it'\''s' --existing --repo 'a b'"#)
        // A word starting with # would read as a comment.
        #expect(NewRowAction.branch("#hotfix").command(repo: "app") == "canopy row new '#hotfix' --existing --repo app")
    }

    @Test func theNewBranchLineStartsFromTheTypedBase() async throws {
        let lists = FakeLists()
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "feat/n"
        #expect(picker.defaultBase == "origin/main")
        #expect(picker.selectedAction == .newBranch("feat/n", base: nil))
        picker.base = " origin/dev "
        #expect(picker.selectedAction == .newBranch("feat/n", base: "origin/dev"))
    }

    @Test func ghUnavailableShowsTheSidebarsWarning() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .failure(.ghUnavailable("Run `gh auth login` to see pull requests."))
            $0.local = listing([branch("main")])
        }
        let picker = makePicker(lists)
        await picker.load()

        let warning = NewRowPicker.Note(kind: .warning, text: "Run `gh auth login` to see pull requests.")
        #expect(picker.showsPullRequests)
        #expect(picker.pullRequestNote == warning)
        #expect(ids(picker.branchItems) == ["branch/main"])
        picker.text = "#12"
        try await Task.sleep(for: .milliseconds(100))
        #expect(picker.pullRequestNote == warning)
        #expect(lists.queries == [nil])

        lists.state.withLock { $0.pullRequests = .failure(.ghFailed("HTTP 502")) }
        let failed = makePicker(lists)
        await failed.load()
        #expect(failed.pullRequestNote == .init(kind: .warning, text: "Pull requests did not load: HTTP 502"))
    }

    @Test func aRepoNotOnGitHubHidesThePullRequests() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.pullRequests = .failure(.notOnGitHub("demo"))
            $0.local = BranchListing(branches: [branch("main", .local)], defaultBase: "HEAD")
        }
        let picker = makePicker(lists)
        await picker.load()

        picker.text = "#12"
        #expect(!picker.showsPullRequests)
        #expect(picker.pullRequestItems.isEmpty && picker.pullRequestNote == nil)
        picker.text = "feat/new"
        #expect(ids(picker.items) == ["new"])
        #expect(picker.defaultBase == "HEAD")
    }

    @Test func aFailedFetchSaysSoAndKeepsLocalBranches() async throws {
        let lists = FakeLists()
        lists.state.withLock {
            $0.local = listing([branch("main")])
            $0.fetched = listing(
                [branch("main")],
                warnings: [
                    "git fetch timed out, so the list shows what Canopy "
                        + "last saw of origin."
                ])
        }
        let picker = makePicker(lists)
        await picker.load()

        #expect(ids(picker.branchItems) == ["branch/main"])
        #expect(
            picker.branchNote
                == .init(kind: .warning, text: "git fetch timed out, so the list shows what Canopy last saw of origin.")
        )
    }

    @Test func listsAWorkspacesPullRequestsAndBranches() async throws {
        let dir = try TempDir()
        let github = try LocalGitHub(dir)
        try await github.createRepo("acme/app")
        try await github.push(to: "feat/split", of: "acme/app")
        try await github.push(to: "feat/taken", of: "acme/app")
        try await github.openPR(7, on: "acme/app", from: "feat/split", title: "Split checkout")
        let repo = try await github.clone("acme/app")
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: github.git, github: github.gh)
        try await workspace.start()
        try await workspace.addRepo(path: repo)
        let row = try await workspace.createRow(repoPath: repo, branch: "feat/taken", existing: true).row
        let picker = NewRowPicker(sources: .workspace(workspace, repoPath: repo))

        await picker.load()

        #expect(ids(picker.pullRequestItems) == ["pr/7"])
        #expect(Set(ids(picker.branchItems)) == ["branch/feat/split", "branch/feat/taken", "branch/main"])
        picker.text = "taken"
        #expect(picker.selectedAction == .selectRow(BranchHolder(row)))
        picker.text = "split"
        #expect(picker.selectedAction == .pullRequest(7))
    }
}
