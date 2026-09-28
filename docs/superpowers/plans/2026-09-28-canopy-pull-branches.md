# Canopy Rows From a PR or an Existing Branch (PR A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `canopy row new --pr <n | #n | URL>` starts a row on a PR's branch, for PRs from the repo and from forks, and `canopy row new <branch>` says which branch it used and brings an existing branch up to date without losing commits.

**Architecture:** CanopyCore gains a PR reference parser, a one-call PR lookup through gh, and a `Workspace.createRow(repoPath:pullRequest:branch:)` that runs the git steps itself with gh's naming and tracking rules.
The existing `createRow(repoPath:branch:base:)` gains `existing`, reports a `BranchSource`, fast-forwards a branch that is only behind origin, and prunes a missing worktree that holds the branch.
A PR number saved per local branch in `state.json` lets the badge query find fork PRs by number in the same GraphQL call.
The control API and CLI pass the new options through, and PR B only adds list methods and the sheet on top of these calls.

**Tech Stack:** Swift 6.2 in Swift 6 language mode, Swift Testing, git, gh, swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-09-28-canopy-pull-branches-design.md`, and "Creating a row" and "PR badges" in `docs/superpowers/specs/2026-09-27-canopy-design.md`.

## Global Constraints

- Tests never reach the network: a local bare origin with `refs/pull/<n>/head` pushed into it, `GIT_CONFIG_COUNT` rewriting `https://github.com/` to that folder, and a stand-in gh.
- Canopy runs git itself and never calls `gh pr checkout`.
- Never reset a branch. A fast-forward uses `git update-ref` with the old value, so it can only move forward from what was read.
- `source` is `local`, `origin`, or `new`.
- Error codes: `branch_not_found`, `branch_exists`, `invalid_pr`, `pr_not_found`, and `branch_checked_out` naming where the branch is.
- `state.json` fields decode with decodeIfPresent, so older files still load.
- Swift 6 strict concurrency with no warnings, `swift format lint --strict` clean.
- Markdown: one sentence per line, no em dashes.
- Other agents change `GitHubCLI` (repo clone, gh on its own thread) and `row new` (`--group`), so changes there stay small.

## Review Focus

1. A PR ref fetch that fails partway, such as a network drop: the temporary `refs/canopy/pr/<n>` ref and any branch Canopy made are gone afterwards, and the error says which PR could not be fetched.
2. Two `row new --pr 7` calls at once: the second fails with `branch_checked_out` naming the first row, never a half-made branch.
3. A PR URL pasted with a trailing `/files`, a query, a fragment, or surrounding spaces still parses, and an issue URL does not.
4. A binding whose origin now points at another repo is ignored rather than breaking the whole repo's badge lookup.
5. A row removed without deleting its branch keeps its binding, so checking the branch out again still shows the fork PR's badge.

## File Structure

- Create `Sources/CanopyCore/PullRequests/PRReference.swift`: parses `7`, `#7`, and PR URLs.
- Create `Sources/CanopyCore/PullRequests/PullRequestHead.swift`: what starting a row from a PR needs to know, and its GraphQL query.
- Modify `Sources/CanopyCore/PullRequests/GitHubCLI.swift`: one `run` helper for gh calls, and `pullRequest(repo:number:)`.
- Modify `Sources/CanopyCore/PullRequests/PullRequest.swift`: `GitHubRepo` gains `init(owner:name:)`, `matches(_:)`, and `url(replacingRepoIn:)`, and `PRQuery` looks bound branches up by number.
- Create `Sources/CanopyCore/Workspace/Workspace+Branches.swift`: a branch's own spelling, claiming a branch (with the prune), fast-forwarding, and comparing with origin.
- Modify `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`: `source`, `existing`, notes, and the shared worktree add.
- Create `Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift`: `createRow(repoPath:pullRequest:branch:)`.
- Modify `Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`: origin's GitHub repo with the configured-URL fallback, and bound numbers in lookups.
- Modify `Sources/CanopyCore/Workspace/Workspace.swift`: `pruneNow`, callable inside a repo's git queue.
- Modify `Sources/CanopyCore/Workspace/WorkspaceError.swift`: the new errors.
- Modify `Sources/CanopyCore/State/AppState.swift`: `PRBinding` and `RepoEntry.prBindings`.
- Modify `Sources/CanopyCore/Control/ControlMethods.swift` and `WorkspaceControlHandler.swift`: `pr`, `existing`, and the new result fields.
- Modify `Sources/CanopyCLI/RowCommand.swift` and `AgentGuide.swift`.
- Modify `scripts/e2e.sh`.
- Tests: `PRReferenceTests`, `PullRequestTests`, `GitHubCLITests`, `ExistingBranchTests`, `PullRequestRowTests`, `PullRequestWorkspaceTests`, `RowLifecycleTests`, `ControlProtocolTests`, `ControlServerTests`, `StateStoreTests`, and `Support/LocalGitHub.swift`.

---

## Task 1: PR references, and a PR's details from gh

**Files:**
- Create: `Sources/CanopyCore/PullRequests/PRReference.swift`, `Sources/CanopyCore/PullRequests/PullRequestHead.swift`, `Tests/CanopyCoreTests/PRReferenceTests.swift`
- Modify: `Sources/CanopyCore/PullRequests/GitHubCLI.swift`, `Sources/CanopyCore/PullRequests/PullRequest.swift`, `Tests/CanopyCoreTests/PullRequestTests.swift`, `Tests/CanopyCoreTests/GitHubCLITests.swift`

**Interfaces:**
- Produces: `PRReference(_ text: String)?` with `number: Int` and `repo: GitHubRepo?`.
- Produces: `PullRequestHead` with `pullRequest`, `branch`, `commit`, `branchExists`, `isCrossRepository`, `headRepo: GitHubRepo?`, `maintainerCanModify`, `defaultBranch: String?`.
- Produces: `GHFailure` (`ghMissing`, `notLoggedIn`, `failed(String)`) and `GitHubCLI.pullRequest(repo:number:) async -> Result<PullRequestHead?, GHFailure>`, nil when GitHub has no such PR.
- Produces: `GitHubRepo(owner:name:)`, `GitHubRepo.matches(_:)`, and `GitHubRepo.url(replacingRepoIn:) -> String?`.

- [ ] **Step 1: Write the failing tests** for parsing, the query, the URL rewrite, and the gh call.
- [ ] **Step 2: Run them and see them fail to compile.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test` and see them pass.**
- [ ] **Step 5: Commit** `feat: look up a PR's head through gh`.

## Task 2: `row new <branch>` reports its source, takes `--existing`, and brings a branch up to date

**Files:**
- Create: `Sources/CanopyCore/Workspace/Workspace+Branches.swift`, `Tests/CanopyCoreTests/ExistingBranchTests.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`, `Sources/CanopyCore/Workspace/Workspace.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`, `Tests/CanopyCoreTests/RowLifecycleTests.swift`

**Interfaces:**
- Produces: `BranchSource` (`local`, `origin`, `new`), and `CreatedRow` with `source`, `base`, `pullRequest`, `notes`, and `warnings`.
- Produces: `Workspace.createRow(repoPath:branch:base:existing:)`.
- Produces for Task 3: `existingBranch(_:under:in:)`, `claim(branch:repoPath:)`, `bringUpToDate(_:with:)`, and `addRow(repoPath:branch:arguments:)`.
- Produces: `WorkspaceError.branchNotFound(String, fetchWarning: String?)` and `branchCheckedOut(String, row: Row?)`.

- [ ] **Step 1: Write the failing tests**: each source, `--existing`, fast-forward, ahead, diverged, gone upstream, the prune, each place a branch can be checked out, the case twin, and a fetch that prunes.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test` and see them pass.**
- [ ] **Step 5: Commit** `feat: row new says which branch it used and brings it up to date`.

## Task 3: Start a row from a PR

**Files:**
- Create: `Sources/CanopyCore/Workspace/Workspace+PullRequestRows.swift`, `Tests/CanopyCoreTests/PullRequestRowTests.swift`, `Tests/CanopyCoreTests/Support/LocalGitHub.swift`
- Modify: `Sources/CanopyCore/State/AppState.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`, `Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`, `Tests/CanopyCoreTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's lookup and Task 2's branch helpers.
- Produces: `Workspace.createRow(repoPath:pullRequest:branch:) async throws -> CreatedRow`.
- Produces: `PRBinding` (`number`, `repo`) and `RepoEntry.prBindings: [String: PRBinding]`.
- Produces: `Workspace.gitHubRemote(_:repoPath:) async -> (url: String, repo: GitHubRepo)?`.
- Produces: `WorkspaceError.invalidPullRequest`, `pullRequestInOtherRepo`, `pullRequestNotFound`, `pullRequestFetchFailed`, and `branchExists`.

- [ ] **Step 1: Write the failing tests**: same-repo PRs, with `--branch`, with the head deleted, forks with and without maintainer edits, both naming fallbacks, reusing a branch that tracks the PR, `branch_exists`, a PR already in a row, the gh failures, and a failed fetch leaving nothing behind.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test` and see them pass.**
- [ ] **Step 5: Commit** `feat: start a row from a PR, including a fork's`.

## Task 4: Badges for branches bound to a PR

**Files:**
- Modify: `Sources/CanopyCore/PullRequests/PullRequest.swift`, `Sources/CanopyCore/PullRequests/GitHubCLI.swift`, `Sources/CanopyCore/Workspace/Workspace+PullRequests.swift`, `Sources/CanopyCore/Workspace/Workspace+RowLifecycle.swift`, `Tests/CanopyCoreTests/PullRequestTests.swift`, `Tests/CanopyCoreTests/PullRequestWorkspaceTests.swift`

**Interfaces:**
- Consumes: Task 3's `prBindings`.
- Produces: `PRQuery.build(repo:branches:numbers:)` and `PRQuery.parse(_:branches:numbers:)`, and `GitHubCLI.pullRequests(repo:branches:numbers:)`.

- [ ] **Step 1: Write the failing tests**: the query asks for a bound branch by number, a fork row made by `createRow(pullRequest:)` shows its badge, a binding for another repo is ignored, and deleting the branch drops the binding.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `make test` and see them pass.**
- [ ] **Step 5: Commit** `feat: badges for rows started from a fork's PR`.

## Task 5: `canopy row new --pr`, `--branch`, and `--existing`

**Files:**
- Modify: `Sources/CanopyCore/Control/ControlMethods.swift`, `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`, `Sources/CanopyCLI/RowCommand.swift`, `Sources/CanopyCLI/AgentGuide.swift`, `Tests/CanopyCoreTests/ControlProtocolTests.swift`, `Tests/CanopyCoreTests/ControlServerTests.swift`

**Interfaces:**
- Consumes: both `createRow` calls.
- Produces: `RowNewParams` with optional `branch`, `pr` (a number or a string), and `existing`, and `RowNewResult` with `source`, `base`, `pr`, and `notes`.

- [ ] **Step 1: Write the failing tests**: params decode `pr` as a number or a string, and the handler refuses combinations with `bad_params` and bad refs with `invalid_pr`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement, including the CLI's flags, its printed lines, and the agent guide.**
- [ ] **Step 4: Run `make test` and see them pass.**
- [ ] **Step 5: Commit** `feat: canopy row new --pr and --existing`.

## Task 6: End-to-end cases

**Files:**
- Modify: `scripts/e2e.sh`

- [ ] **Step 1: Add the cases**: a same-repo PR, a fork PR by URL with its badge through `canopy pr`, `--existing` failing with `branch_not_found`, and `source` for a new branch, with a window shot of the fork PR row.
- [ ] **Step 2: Run `make e2e` and see it pass.**
- [ ] **Step 3: Commit** `test: e2e cases for row new --pr and --existing`.
