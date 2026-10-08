import Foundation
import Observation

/// What picking an item in the New Row sheet does. Each is one `canopy` command, which `command` spells out.
public enum NewRowAction: Equatable, Sendable {
    /// `canopy row new --pr <number>`
    case pullRequest(Int)
    /// `canopy row new <branch> --existing`
    case branch(String)
    /// `canopy row new <branch> [--from <base>]`
    case newBranch(String, base: String?)
    /// `canopy row select <branch>`
    case selectRow(BranchHolder)
    /// `canopy row adopt <path>`
    case adopt(BranchHolder)

    public var createsRow: Bool {
        switch self {
        case .pullRequest, .branch, .newBranch: true
        case .selectRow, .adopt: false
        }
    }

    /// The same on a host, where each machine's git only knows its own worktrees: a branch with a row on this Mac gets
    /// a row there too. Nil for what a host cannot do yet, starting from a pull request, and for a detached checkout.
    public func onHost() -> NewRowAction? {
        switch self {
        case .pullRequest: nil
        case .branch, .newBranch: self
        case .selectRow(let holder), .adopt(let holder): holder.branch.map(NewRowAction.branch)
        }
    }

    /// The command that makes the row on `host`, or does the same here when it is nil.
    public func command(repo: String, host: String?) -> String {
        guard let host, createsRow else { return command(repo: repo) }
        return command(repo: repo) + " --on " + Self.quoted(host)
    }

    /// The command that does the same in `repo`, quoted for a shell. Adopting names the worktree by its path, which
    /// needs no repo.
    public func command(repo: String) -> String {
        let words: [String] =
            switch self {
            case .pullRequest(let number): ["row", "new", "--pr", "\(number)", "--repo", repo]
            case .branch(let name): ["row", "new", name, "--existing", "--repo", repo]
            case .newBranch(let name, let base):
                ["row", "new", name] + (base.map { ["--from", $0] } ?? []) + ["--repo", repo]
            case .selectRow(let row): ["row", "select", row.branch ?? row.path, "--repo", repo]
            case .adopt(let worktree): ["row", "adopt", worktree.path]
            }
        return (["canopy"] + words.map(Self.quoted)).joined(separator: " ")
    }

    /// `word` as a shell reads it back.
    public static func quoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-@+=")
        guard word.isEmpty || !word.unicodeScalars.allSatisfy(plain.contains) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// One line of the New Row sheet's list.
public enum NewRowItem: Equatable, Sendable, Identifiable {
    case pullRequest(ListedPullRequest)
    case branch(ListedBranch)
    /// "New branch ‘<name>’ from <base>".
    case newBranch(String)

    public var id: String {
        switch self {
        case .pullRequest(let pr): "pr/\(pr.number)"
        case .branch(let branch): "branch/\(branch.name)"
        case .newBranch: "new"
        }
    }

    /// The row or worktree that already has the item checked out.
    public var holder: BranchHolder? {
        switch self {
        case .pullRequest(let pr): pr.row
        case .branch(let branch): branch.row
        case .newBranch: nil
        }
    }

    /// An item that already has a row opens it, and one in another tool's worktree adopts it. `base` is where a new
    /// branch starts, or nil for the repo's default.
    public func action(base: String?) -> NewRowAction {
        if let holder { return holder.isRow ? .selectRow(holder) : .adopt(holder) }
        switch self {
        case .pullRequest(let pr): return .pullRequest(pr.number)
        case .branch(let branch): return .branch(branch.name)
        case .newBranch(let name): return .newBranch(name, base: base)
        }
    }
}

/// The New Row sheet's state: the typed text, the PRs and branches it matches, and which one is selected.
/// Branches show from local refs at once and again after origin is fetched. PRs come from gh, and a PR number not in
/// the list is looked up on its own, a moment after typing stops.
@MainActor
@Observable
public final class NewRowPicker {
    /// Where the lists come from. `pullRequests` gets nil for the open PRs, or text to look one PR up by.
    /// `branches` gets whether to fetch origin first.
    public struct Sources: Sendable {
        public var pullRequests: @Sendable (String?) async throws -> [ListedPullRequest]
        public var branches: @Sendable (Bool) async throws -> BranchListing

        public init(
            pullRequests: @escaping @Sendable (String?) async throws -> [ListedPullRequest],
            branches: @escaping @Sendable (Bool) async throws -> BranchListing
        ) {
            self.pullRequests = pullRequests
            self.branches = branches
        }

        /// The same lists `canopy pr list` and `canopy branch list` give.
        public static func workspace(_ workspace: Workspace, repoPath: String) -> Sources {
            Sources(
                pullRequests: { try await workspace.listPullRequests(repoPath: repoPath, query: $0) },
                branches: { try await workspace.listBranches(repoPath: repoPath, fetch: $0) })
        }
    }

    /// A line in a section in place of, or above, its items.
    public struct Note: Equatable, Sendable {
        public enum Kind: Sendable {
            case loading, info, warning
        }

        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public var text = "" {
        didSet {
            guard text != oldValue else { return }
            selection = nil
            isSelectionPicked = false
            // A lookup that failed, such as one gh did not answer in time, is tried again when asked for again.
            lookups = lookups.filter { if case .failure = $0.value { false } else { true } }
            settleSelection()
            scheduleLookup()
        }
    }
    /// Where a new branch starts. Empty for `defaultBase`.
    public var base = ""
    /// Whether origin is being fetched, after which the branches show again.
    public private(set) var isFetching = false
    /// False once the repo's origin turns out not to be on GitHub.
    public private(set) var showsPullRequests = true

    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private let lookupDelay: Duration
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var lookingUp: Set<String> = []
    /// Nil while the open PRs load.
    private var openPullRequests: Result<[ListedPullRequest], WorkspaceError>?
    /// PRs looked up by number, and by repo too for a URL, nil where GitHub has none.
    private var lookups: [String: Result<ListedPullRequest?, WorkspaceError>] = [:]
    private var branchListing: Result<BranchListing, WorkspaceError>?
    private var selection: String?
    /// Whether the selected item was picked with the arrows, a click, or the start point field, rather than being the
    /// best match for the typed text.
    @ObservationIgnored private var isSelectionPicked = false

    public init(sources: Sources, lookupDelay: Duration = .milliseconds(250)) {
        self.sources = sources
        self.lookupDelay = lookupDelay
    }

    /// Loads the open PRs and the local branches together, then fetches origin and lists the branches again.
    public func load() async {
        async let pullRequests: Void = loadPullRequests()
        await loadBranches(fetch: false)
        await refreshBranches()
        await pullRequests
    }

    func refreshBranches() async {
        isFetching = true
        await loadBranches(fetch: true)
        isFetching = false
    }

    private func loadPullRequests() async {
        do {
            openPullRequests = .success(try await sources.pullRequests(nil))
        } catch WorkspaceError.notOnGitHub {
            showsPullRequests = false
            openPullRequests = .success([])
        } catch {
            openPullRequests = .failure(Self.workspaceError(error))
        }
        settleSelection()
        scheduleLookup()
    }

    private func loadBranches(fetch: Bool) async {
        do {
            branchListing = .success(try await sources.branches(fetch))
        } catch {
            // A failed refresh keeps what the first listing showed.
            if case .success = branchListing, fetch { return }
            branchListing = .failure(Self.workspaceError(error))
        }
        settleSelection()
    }

    // MARK: What the sheet shows

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The PR the typed text names, when it is a number, `#number`, or URL.
    private var reference: PRReference? { PRReference(typed) }

    /// A PR the typed text names that is not in the open list, and so is looked up on its own. URLs are always looked
    /// up, since only the lookup says whether they name this repo. `12` and `#12` share one lookup.
    private var lookupKey: String? {
        guard showsPullRequests, let reference, case .success(let open) = openPullRequests else { return nil }
        guard reference.repo != nil || !open.contains(where: { $0.number == reference.number }) else { return nil }
        return (reference.repo.map { $0.nameWithOwner.lowercased() } ?? "") + "#\(reference.number)"
    }

    public var pullRequestItems: [NewRowItem] {
        guard showsPullRequests, case .success(let open) = openPullRequests else { return [] }
        if let key = lookupKey {
            guard case .success(let found?) = lookups[key] else { return [] }
            return [.pullRequest(found)]
        }
        if let reference {
            return open.filter { $0.number == reference.number }.map(NewRowItem.pullRequest)
        }
        let search = SearchText(typed)
        return open.filter { $0.matches(search) }.map(NewRowItem.pullRequest)
    }

    public var pullRequestNote: Note? {
        guard showsPullRequests else { return nil }
        switch openPullRequests {
        case nil: return Note(kind: .loading, text: "Loading pull requests…")
        case .failure(let error): return Note(kind: .warning, text: Self.pullRequestWarning(error))
        case .success(let open):
            if let key = lookupKey, let number = reference?.number {
                switch lookups[key] {
                case nil: return Note(kind: .loading, text: "Looking up #\(number)…")
                case .success(nil): return Note(kind: .info, text: "No pull request #\(number).")
                case .failure(let error): return Note(kind: .warning, text: Self.pullRequestWarning(error))
                case .success: return nil
                }
            }
            guard pullRequestItems.isEmpty else { return nil }
            if open.isEmpty { return Note(kind: .info, text: "No open pull requests.") }
            return Note(kind: .info, text: "No open pull requests match.")
        }
    }

    public var branchItems: [NewRowItem] {
        guard case .success(let listing) = branchListing else { return [] }
        let search = SearchText(typed)
        let matching = listing.branches.filter { $0.matches(search) }
        // An exact name, in any case, first. The listing is already newest first.
        let exact = matching.filter { $0.name.caseInsensitiveCompare(typed) == .orderedSame }
        let others = matching.filter { $0.name.caseInsensitiveCompare(typed) != .orderedSame }
        return (exact + others).map(NewRowItem.branch)
    }

    public var branchNote: Note? {
        switch branchListing {
        case nil: return Note(kind: .loading, text: "Loading branches…")
        case .failure(let error): return Note(kind: .warning, text: error.message)
        case .success(let listing):
            if !listing.warnings.isEmpty { return Note(kind: .warning, text: listing.warnings.joined(separator: " ")) }
            return branchItems.isEmpty ? Note(kind: .info, text: "No branches match.") : nil
        }
    }

    /// Where a new branch starts by default, such as origin/main, once the branches are listed.
    public var defaultBase: String? {
        guard case .success(let listing) = branchListing else { return nil }
        return listing.defaultBase
    }

    /// "New branch ‘<name>’", shown for a valid branch name that no branch has in any case, since `row new` would use
    /// that branch. A PR number, and any text starting with `#`, means a PR, so it never offers a branch to create by
    /// mistake while the PR is on its way.
    public var newBranchItem: NewRowItem? {
        let name = typed
        guard BranchName.isValid(name), !name.hasPrefix("#"), reference == nil else { return nil }
        if case .success(let listing) = branchListing,
            listing.branches.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        {
            return nil
        }
        return .newBranch(name)
    }

    /// Every item in list order: PRs, branches, then the new branch line.
    public var items: [NewRowItem] {
        pullRequestItems + branchItems + (newBranchItem.map { [$0] } ?? [])
    }

    public var selectedItem: NewRowItem? {
        selection.flatMap { id in items.first { $0.id == id } }
    }

    public var selectedAction: NewRowAction? {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedItem?.action(base: base.isEmpty ? nil : base)
    }

    // MARK: Selection

    public func select(_ id: String?) {
        selection = id
        isSelectionPicked = id != nil
    }

    /// Moves by `offset` items, stopping at the ends. With nothing selected, down picks the first and up the last.
    public func moveSelection(by offset: Int) {
        let items = items
        guard !items.isEmpty else { return }
        isSelectionPicked = true
        guard let index = items.firstIndex(where: { $0.id == selection }) else {
            selection = (offset > 0 ? items.first : items.last)?.id
            return
        }
        selection = items[min(max(index + offset, 0), items.count - 1)].id
    }

    /// Keeps a picked item selected while it is listed, so answers arriving later never move it. Otherwise the best
    /// match is selected once something is typed, and nothing before, and it follows the answers as they arrive.
    private func settleSelection() {
        let items = items
        if isSelectionPicked, let selection, items.contains(where: { $0.id == selection }) { return }
        isSelectionPicked = false
        selection = typed.isEmpty ? nil : bestMatch(in: items)?.id
    }

    /// The PR a number names, then a branch named exactly what was typed, in any case, then the first item.
    private func bestMatch(in items: [NewRowItem]) -> NewRowItem? {
        if reference != nil, let pullRequest = pullRequestItems.first { return pullRequest }
        if let branch = branchItems.first, case .branch(let listed) = branch,
            listed.name.caseInsensitiveCompare(typed) == .orderedSame
        {
            return branch
        }
        return items.first
    }

    // MARK: Looking up one PR

    /// Waits for typing to stop, then asks GitHub. A lookup that has started finishes and is kept, so an older answer
    /// can never stand in for what is typed now.
    private func scheduleLookup() {
        lookupTask?.cancel()
        guard let key = lookupKey, lookups[key] == nil, !lookingUp.contains(key) else { return }
        lookupTask = Task { [weak self, lookupDelay, query = typed] in
            if lookupDelay > .zero { try? await Task.sleep(for: lookupDelay) }
            guard !Task.isCancelled else { return }
            await self?.lookUp(key, query: query)
        }
    }

    private func lookUp(_ key: String, query: String) async {
        lookingUp.insert(key)
        defer { lookingUp.remove(key) }
        let result: Result<ListedPullRequest?, WorkspaceError>
        do {
            result = .success(try await sources.pullRequests(query).first)
        } catch {
            result = .failure(Self.workspaceError(error))
        }
        lookups[key] = result
        settleSelection()
    }

    // MARK: Errors

    private static func workspaceError(_ error: any Error) -> WorkspaceError {
        error as? WorkspaceError ?? .ghFailed("\(error)")
    }

    /// The sidebar's words for why PRs cannot be shown.
    private static func pullRequestWarning(_ error: WorkspaceError) -> String {
        switch error {
        case .ghUnavailable(let fix): fix
        case .ghFailed(let message): RepoPullRequests(source: .failed(message)).warning ?? message
        default: error.message
        }
    }
}
