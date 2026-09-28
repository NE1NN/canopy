# Canopy Repo Clone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clone repos from GitHub into Canopy, from `canopy repo clone` and from the window, and register them in one step.

**Architecture:** `CanopyCore` parses what to clone (`CloneSource`), runs `gh repo clone` or `git clone` into a hidden folder next to the destination, and renames it into place once the clone is whole, so a folder that exists is always a complete clone.
`Workspace.cloneRepo` owns the whole operation: it checks the destination, runs one clone per folder at a time, cleans up on failure or cancel, and registers the result through `addRepo`.
The control API gains `repo.clone`, the CLI gains `canopy repo clone`, and the app gains a `+` menu, File > Clone Repo…, and a clone sheet that lists the author's GitHub repos through `gh`.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, `gh` and `git` run through `Subprocess`.

**Spec:** `docs/superpowers/specs/2026-09-27-canopy-design.md`: "Registering repos", "Data folder", "Sidebar rows", "Commands", and "Activity log".
The approved design for this feature is quoted under "Design" below.

## Design

The author approved this on 2026-09-28:

- `canopy repo clone <owner/repo | url> [--into <dir>]` clones with `gh repo clone`, which uses the author's gh login and preferred git protocol.
  It falls back to `git clone` for a plain URL when gh is missing.
  Then it registers the repo and prints it the way `repo add` does, including `--json`.
- The default folder is `CANOPY_HOME/repos/<owner>/<name>` (`~/.canopy/repos` for release, `~/.canopy-dev/repos` for dev).
  The owner in the path keeps two repos named `app` apart, and the existing naming rule shows them as `owner/app`.
- Idempotent: if the folder already holds that same repo (its origin matches), register it and stop.
  A folder holding anything else is an error with a clear code.
  A failed clone deletes its half-written folder.
- The clone runs in the app, so it lands in the activity log. The CLI waits for it with no timeout.
- In the app, the Repos `+` becomes a menu: "Add Local Repo…" and "Clone from GitHub…". File menu gets "Clone Repo…" too.
  The clone sheet has one field that takes `owner/repo` or a URL, with the author's repos and their orgs' repos listed below it, newest push first, filtered as they type.
  Clicking a listed repo fills the field. Show progress while cloning and the error in the sheet on failure.
  If gh is missing or logged out, the list is replaced by the fix (such as `gh auth login`) and the field still works for URLs.
- `repo rm` still only unregisters; a cloned folder stays until the author deletes it.

### How a clone runs

1. `CloneSource` reads the argument.
   `owner/repo` is a GitHub repo.
   Anything with `://`, an scp-style `host:path`, or a leading `/` is a URL git can clone, and it is also a GitHub repo when its host is GitHub.
   A github.com page, such as `…/acme/app/tree/main`, stands for its repo.
   A leading `-` and git's `transport::address` helper syntax are refused.
   The CLI turns `./x` and `../x` into absolute paths first, as it does for `repo add`.
2. The destination is `--into`, or `CANOPY_HOME/repos/<owner>/<name>`.
   For a URL that is not on GitHub, the owner is the folder above the repo in the URL's path, so `file:///srv/git/acme/app.git` goes to `repos/acme/app`.
   An owner or name of `.` or `..` is refused, so no source can reach outside the repos folder.
3. Clones of one destination run one at a time, so a second clone of the same repo waits and then finds the first one's folder.
   They queue apart from the repo's other git work, so cloning a repo that is already registered never waits behind a fetch.
4. The destination is checked:
   - missing, or an empty folder: clone.
   - the top of a git checkout whose `origin` is the same repo: register it and stop.
     GitHub repos match by owner and name in any case and over any protocol, following SSH host aliases.
     Other URLs match once `.git` and trailing slashes are dropped, and local paths match by their resolved path.
   - anything else: `folder_taken`, naming what the folder holds.
5. The clone goes into a hidden sibling, `.<name>.canopy-clone-<random>`, and is renamed onto the destination when it is whole.
   An empty folder already there stays, and the clone's entries move into it with `RENAME_EXCL`, `.git` last, so a shell sitting in it is still in it.
   A folder filled meanwhile is checked again as in step 4.
6. Which command runs:
   - a GitHub repo with gh found: `gh repo clone <owner/repo or the URL as given> <folder> -- --progress`.
   - gh missing or logged out: a URL falls back to `git clone --progress <url> <folder>`, and `owner/repo` fails with `gh_unavailable` and the fix.
   - any other URL: `git clone --progress`, since gh only clones from GitHub.
7. Progress comes from the tail of the clone's stderr, read every 200 ms while it runs: the phase git names, such as "Receiving objects", and its percent.
8. On failure or cancel, the hidden folder and any parent folders the clone created are deleted.
   Quitting the app kills clones still running, waits up to 2 seconds for them to die, and deletes their hidden folders.
   A failure reports git's or gh's reason: the last `fatal:` or `error:` line, skipping gh's `failed to run git` line, and the line above "Could not read from remote repository.", where ssh or the server says why.
9. On success, `addRepo` registers the destination and logs `repo.added` with `data.clonedFrom` set to the source as given.
   The control API also logs the call as `cli.call`.

### The window

- The Repos `+` is a menu with "Add Local Repo…" and "Clone from GitHub…".
  File has "Add Repo…" (`⇧⌘O`, unchanged) and "Clone Repo…".
- The clone sheet has a title, the field, a line saying where the clone will go, the repo list, a progress bar while cloning, an error line, and Cancel and Clone.
- The list comes from one `gh api graphql` call for the viewer's repos, owned and through their orgs, newest push first, 100 at most.
  Each line has a lock for private repos, `owner/` dimmed before the name, the description, and when it was last pushed.
  Typing filters it by `owner/name`, ignoring case.
  Clicking a line fills the field.
- While gh is missing or logged out, the list's place shows the fix, and the field still clones URLs.
- A successful clone closes the sheet and selects the new repo's main row.
  Cancel while cloning stops the clone and deletes what it wrote.

## Global Constraints

- Swift 6 language mode with strict concurrency, `make lint` and `make build` with 0 warnings.
- Tests and `make e2e` never reach the network: clones come from local bare repos through `file://` URLs, and `gh` is a stand-in script.
- Every UI action has a CLI equivalent: the sheet clones through the same `Workspace.cloneRepo` that `repo.clone` calls.
- `canopy repo clone --json` prints the same `RepoInfo` object as `canopy repo add --json`.
- The CLI waits for `repo.clone` with no timeout.
- Error codes are snake_case and stable: `invalid_clone_source`, `folder_taken`, `clone_failed`, `clone_cancelled`, and the existing `gh_unavailable`.
- `repo rm` never deletes a cloned folder.
- Markdown: one sentence per line, no em dashes. Conventional commit prefixes, no Co-Authored-By trailers.
- Sidebar changes stay inside the Repos `+` and the shared icon menu, since another branch is reworking sidebar rows.

## Review Focus

1. **Two clones of the same repo at once**, from two agents, or from an agent and the sheet: one clone runs, and both calls return the same registered repo.
2. **Cancelling or quitting mid-clone**: no destination folder, no hidden folder, no empty `repos/<owner>/` left, and no git process still running.
3. **A source that would escape the repos folder**, such as `https://host/acme/..` or `acme/..`: refused with `invalid_clone_source`, and nothing is written.
4. **A folder that holds the same repo cloned another way**, over SSH instead of HTTPS, through an SSH host alias, or with different letter case: recognized as the same repo and registered.
5. **gh logged out**: a GitHub URL still clones with plain git, and `owner/repo` fails with `gh_unavailable` naming `gh auth login`.

Each of these has a test in the task that owns the code.

## Decisions to review

1. **URLs not on GitHub clone with plain git even when gh is installed.**
   `gh repo clone` asks the GitHub API about every URL it is given, so it cannot clone GitLab, a self-hosted server, or a local bare repo.
2. **A logged-out gh counts as missing for URLs.**
   gh exits 4 without a login before it writes anything, so Canopy falls back to `git clone`, which works for public repos and for private ones the author's git credentials reach.
3. **A bare repo name such as `canopy` is refused.**
   gh would read it as the author's own repo, but Canopy needs the owner to pick the folder before cloning.
   The error asks for `owner/repo`.
4. **The sheet's list is the 100 most recently pushed repos.**
   Anything older is still one `owner/repo` away in the field.
5. **The list has no CLI command.**
   Agents already have `gh repo list`, and the clone itself is `canopy repo clone`.
6. **Ctrl-C on `canopy repo clone` does not stop the clone.**
   Like `row new`, the app finishes it and registers the repo.
   Running the same command again picks the result up.
7. **The sheet always clones into the default folder.**
   `--into` is only on the CLI.
8. **A clone from the window selects the new repo's main row**, the way a new row is selected.
   `canopy repo clone` does not select anything, like `row new` without `--select`.
9. **`repo.added` gains `data.clonedFrom`** rather than a new event type, so each registration is still one event and the log says where a clone came from.
10. **File > Clone Repo… has no shortcut**, and File > Add Repo… keeps its name and `⇧⌘O`.
    The empty sidebar keeps only its Add Repo… button.
11. **Quitting does not ask about a clone in progress.**
    It kills the clone and deletes the partial folder, and the clone can be run again.
12. **Stale hidden folders from a crash are not swept.**
    They start with a dot, and sweeping could delete another Canopy's clone in progress.
13. **A github.com page stands for its repo.**
    Pasting `https://github.com/acme/app/tree/main` or a pull request's URL clones `acme/app` from `https://github.com/acme/app`.

## File Structure

- Create `Sources/CanopyCore/Repos/CloneSource.swift`: parsing the argument, the default folder, and matching an origin.
- Create `Sources/CanopyCore/Repos/CloneProgress.swift`: reading git's progress lines.
- Create `Sources/CanopyCore/Workspace/Workspace+Clone.swift`: the clone operation.
- Create `Sources/CanopyCore/PullRequests/GitHubRepoList.swift`: the viewer's repos query and its parsing.
- Modify `Sources/CanopyCore/Support/Subprocess.swift`: `SubprocessHandle`, to stop a running process and read its stderr so far.
- Modify `Sources/CanopyCore/Git/GitRunner.swift`: pass a handle through.
- Modify `Sources/CanopyCore/PullRequests/GitHubCLI.swift`: one way to find and run gh, plus `clone` and `viewerRepos`.
- Modify `Sources/CanopyCore/Support/CanopyHome.swift`: `reposRoot`.
- Modify `Sources/CanopyCore/Workspace/Workspace.swift`, `WorkspaceError.swift`: registering with `clonedFrom`, stopping clones, new errors.
- Modify `Sources/CanopyCore/Control/ControlMethods.swift`, `WorkspaceControlHandler.swift`: `repo.clone`.
- Modify `Sources/CanopyCLI/RepoCommand.swift`, `AgentGuide.swift`: `canopy repo clone`.
- Create `Sources/CanopyApp/Repos/CloneRepoSheet.swift`: the sheet and its repo list.
- Modify `Sources/CanopyApp/AppModel.swift`, `CanopyApp.swift`, `RootView.swift`, `Sidebar/SidebarView.swift`, `Style/Style.swift`: the menu, the File item, presenting the sheet, and an icon menu shared with the repo `…` menu.
- Modify `scripts/e2e.sh`, `scripts/ui-fixture.sh`, `scripts/window-shot.swift`: a clone case, a stand-in gh that clones and lists repos, and shots that include open menus.
- Modify the spec.
- Tests: `Tests/CanopyCoreTests/CloneSourceTests.swift`, `CloneProgressTests.swift`, `CloneTests.swift`, and additions to `GitHubCLITests.swift`, `GitRunnerTests.swift`, `ControlServerTests.swift`.

---

### Task 1: Read what `repo clone` is given

**Files:**
- Create: `Sources/CanopyCore/Repos/CloneSource.swift`
- Modify: `Sources/CanopyCore/Support/CanopyHome.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`
- Test: `Tests/CanopyCoreTests/CloneSourceTests.swift`

**Interfaces:**
- Produces: `CloneSource(_ text: String) throws`, with `text`, `github: GitHubRepo?`, `url: String?`, `owner: String?`, `name`, `ghArgument: String?`, `defaultFolder(in: CanopyHome) throws -> String`, and `isSameRepo(asOrigin: String, gitHubRepo: GitHubRepo?) -> Bool`.
- Produces: `CanopyHome.reposRoot`, and `WorkspaceError.invalidCloneSource(String)` (`invalid_clone_source`) and `.cloneNeedsFolder(String)` (`missing_target`).

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/CloneSourceTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct CloneSourceTests {
    @Test func readsOwnerSlashRepoAsAGitHubRepo() throws {
        let source = try CloneSource("  acme/app \n")

        #expect(source.text == "acme/app")
        #expect(source.github == GitHubRepo(remoteURL: "https://github.com/acme/app"))
        #expect(source.url == nil)
        #expect(source.ghArgument == "acme/app")
        #expect(source.owner == "acme")
        #expect(source.name == "app")
    }

    @Test func keepsRepoNamesThatStartWithADot() throws {
        let source = try CloneSource("acme/.github")

        #expect(source.name == ".github")
    }

    @Test(arguments: [
        "https://github.com/acme/app.git", "https://github.com/acme/app", "git@github.com:acme/app.git",
        "ssh://git@github.com/acme/app.git",
    ])
    func readsGitHubURLs(url: String) throws {
        let source = try CloneSource(url)

        #expect(source.github?.nameWithOwner == "acme/app")
        #expect(source.url == url)
        #expect(source.ghArgument == url)
        #expect(source.owner == "acme")
        #expect(source.name == "app")
    }

    @Test(arguments: [
        ("https://gitlab.com/group/team/tool.git", "team", "tool"),
        ("git@example.com:team/tool.git", "team", "tool"),
        ("file:///srv/git/acme/lib.git", "acme", "lib"),
        ("/srv/git/acme/lib.git", "acme", "lib"),
        ("https://example.com/tool.git/", "example.com", "tool"),
    ])
    func takesTheFolderAboveTheRepoAsTheOwnerOfOtherURLs(url: String, owner: String, name: String) throws {
        let source = try CloneSource(url)

        #expect(source.github == nil)
        #expect(source.url == url)
        #expect(source.ghArgument == nil)
        #expect(source.owner == owner)
        #expect(source.name == name)
    }

    @Test(arguments: [
        "", "   ", "canopy", "acme/app/extra", "acme/..", "../app", "acme/.", "https://example.com/acme/..",
        "https://example.com/../app.git", "https://example.com/", "file:///srv/acme/.git", "-acme/app",
        "--upload-pack=touch:pwned",
    ])
    func refusesAnythingElse(text: String) {
        #expect(throws: WorkspaceError.invalidCloneSource(text.trimmingCharacters(in: .whitespacesAndNewlines))) {
            try CloneSource(text)
        }
    }

    @Test func picksAFolderUnderReposByOwnerAndName() throws {
        let home = CanopyHome(path: "/tmp/canopy-home")

        #expect(try CloneSource("acme/app").defaultFolder(in: home) == "/tmp/canopy-home/repos/acme/app")
    }

    @Test func needsAFolderForAURLWithNoOwner() throws {
        let source = try CloneSource("file:///app.git")

        #expect(source.owner == nil)
        #expect(throws: WorkspaceError.cloneNeedsFolder("file:///app.git")) {
            try source.defaultFolder(in: CanopyHome(path: "/tmp/canopy-home"))
        }
    }

    @Test func matchesAGitHubOriginOverAnyProtocolAndInAnyCase() throws {
        let source = try CloneSource("acme/app")
        let origin = "git@github.com:ACME/App.git"

        #expect(source.isSameRepo(asOrigin: origin, gitHubRepo: GitHubRepo(remoteURL: origin)))
        #expect(
            !source.isSameRepo(
                asOrigin: "https://github.com/acme/other",
                gitHubRepo: GitHubRepo(remoteURL: "https://github.com/acme/other")))
        #expect(!source.isSameRepo(asOrigin: "https://example.com/acme/app", gitHubRepo: nil))
    }

    @Test func matchesOtherOriginsWithoutTheirGitSuffixOrTrailingSlash() throws {
        let source = try CloneSource("https://gitlab.com/team/tool")

        #expect(source.isSameRepo(asOrigin: "https://gitlab.com/team/tool.git/", gitHubRepo: nil))
        #expect(!source.isSameRepo(asOrigin: "https://gitlab.com/team/other.git", gitHubRepo: nil))
    }

    @Test func matchesLocalOriginsByTheirResolvedPath() throws {
        let dir = try TempDir()
        let bare = dir.sub("lib.git")
        try FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir.sub("link.git"), withDestinationPath: bare)
        let source = try CloneSource("file://" + dir.sub("link.git"))

        #expect(source.isSameRepo(asOrigin: bare, gitHubRepo: nil))
        #expect(source.isSameRepo(asOrigin: "file://" + bare + "/", gitHubRepo: nil))
        #expect(!source.isSameRepo(asOrigin: dir.sub("other.git"), gitHubRepo: nil))
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter CloneSourceTests`
Expected: the build fails: `cannot find 'CloneSource' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Repos/CloneSource.swift`, new:

```swift
import Foundation

/// What `canopy repo clone` was given: a GitHub `owner/repo`, or a URL git can clone, which may be on GitHub too.
public struct CloneSource: Sendable, Equatable {
    /// As given, trimmed.
    public let text: String
    /// Set for `owner/repo` and for URLs on GitHub.
    public let github: GitHubRepo?
    /// Set for everything but `owner/repo`.
    public let url: String?
    /// The folder the repo's own folder goes in. Nil when a URL names no folder above the repo and no host.
    public let owner: String?
    public let name: String

    public init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text
        // Anything starting with a dash would reach gh or git as an option.
        guard !text.isEmpty, !text.hasPrefix("-") else { throw WorkspaceError.invalidCloneSource(text) }
        if let location = Self.locate(text) {
            let parts = location.path.split(separator: "/").map(String.init)
            var name = parts.last ?? ""
            if name.hasSuffix(".git") { name.removeLast(4) }
            let owner = parts.count > 1 ? parts[parts.count - 2] : location.host
            guard Self.isFolderName(name), owner.map(Self.isFolderName) ?? true else {
                throw WorkspaceError.invalidCloneSource(text)
            }
            github = GitHubRepo(remoteURL: text)
            url = text
            self.owner = github?.owner ?? owner
            self.name = github?.name ?? name
        } else {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, Self.isGitHubOwner(parts[0]), Self.isGitHubRepoName(parts[1]),
                let github = GitHubRepo(remoteURL: "https://github.com/\(text)")
            else { throw WorkspaceError.invalidCloneSource(text) }
            self.github = github
            url = nil
            owner = github.owner
            name = github.name
        }
    }

    /// What `gh repo clone` is given: the URL as typed, so its protocol is kept, or `owner/repo`, so gh picks one.
    /// Nil when the repo is not on GitHub.
    public var ghArgument: String? {
        github.map { url ?? $0.nameWithOwner }
    }

    /// CANOPY_HOME/repos/<owner>/<name>.
    public func defaultFolder(in home: CanopyHome) throws -> String {
        guard let owner else { throw WorkspaceError.cloneNeedsFolder(text) }
        return home.reposRoot.appending(path: owner).appending(path: name).path
    }

    /// Whether a checkout whose origin is `origin` holds this repo. `gitHubRepo` is the GitHub repo behind `origin`,
    /// found the way PR lookups find it, so SSH host aliases count. GitHub repos match by owner and name in any case.
    public func isSameRepo(asOrigin origin: String, gitHubRepo: GitHubRepo?) -> Bool {
        if let github {
            guard let gitHubRepo else { return false }
            return github.owner.lowercased() == gitHubRepo.owner.lowercased()
                && github.name.lowercased() == gitHubRepo.name.lowercased()
        }
        guard let url else { return false }
        return Self.normalized(url) == Self.normalized(origin)
    }

    /// Local paths resolved, and other URLs without trailing slashes or `.git`.
    static func normalized(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://") { text.removeFirst("file://".count) }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        if text.hasPrefix("/") { return Paths.canonical(text) }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text
    }

    /// The host and path of `scheme://[user@]host[:port]/path`, `[user@]host:path`, or a local `/path`.
    private static func locate(_ text: String) -> (host: String?, path: String)? {
        if text.hasPrefix("/") { return (nil, text) }
        if let separator = text.range(of: "://") {
            let rest = text[separator.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var host = rest[..<slash]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
            return (host.isEmpty ? nil : String(host), String(rest[slash...]))
        }
        // A colon after a slash is part of a path, like acme/a:b.
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex, !text[..<colon].contains("/") else {
            return nil
        }
        var host = text[..<colon]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        return (String(host), String(text[text.index(after: colon)...]))
    }

    /// A single folder that stays inside its parent.
    private static func isFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// Letters, digits, and hyphens, not starting with a hyphen, as GitHub allows.
    private static func isGitHubOwner(_ owner: String) -> Bool {
        guard let first = owner.unicodeScalars.first, first != "-" else { return false }
        return owner.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// Letters, digits, dots, hyphens, and underscores, as GitHub allows.
    private static func isGitHubRepoName(_ name: String) -> Bool {
        isFolderName(name)
            && name.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
            }
    }
}
```

`Sources/CanopyCore/Support/CanopyHome.swift`:

```diff
@@ -36,6 +36,8 @@ public struct CanopyHome: Sendable, Equatable {
     public var stateFile: URL { root.appending(path: "state.json") }
     public var configFile: URL { root.appending(path: "config.json") }
     public var worktreesRoot: URL { root.appending(path: "worktrees") }
+    /// Repos cloned by Canopy, at repos/<owner>/<name>.
+    public var reposRoot: URL { root.appending(path: "repos") }
     /// One JSON Lines file of activity events per local day.
     public var activityFolder: URL { root.appending(path: "activity") }
     /// ZDOTDIR for zsh terminals while command logging is on.
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -26,6 +26,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case ghFailed(String)
     case portNotFound(Int)
     case portInOtherRow(Int, row: String)
+    case invalidCloneSource(String)
+    case cloneNeedsFolder(String)
     case git(GitError)
 
     public var code: String {
@@ -57,6 +59,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .ghFailed: "gh_failed"
         case .portNotFound: "port_not_found"
         case .portInOtherRow: "port_in_other_row"
+        case .invalidCloneSource: "invalid_clone_source"
+        case .cloneNeedsFolder: "missing_target"
         case .git: "git_failed"
         }
     }
@@ -95,6 +99,8 @@ public enum WorkspaceError: Error, Sendable, Equatable {
             "No row's process listens on port \(port). Run `canopy ports --all`; Canopy only stops its rows' ports."
         case .portInOtherRow(let port, let row):
             "Port \(port) belongs to \(row), not to this row. Pass --row \(row), or --all to stop it anywhere."
+        case .invalidCloneSource(let text): "Pass owner/repo or a URL to clone, not \"\(text)\"."
+        case .cloneNeedsFolder(let text): "Canopy cannot tell which folder \(text) goes in. Pass --into."
         case .git(let error): error.description
         }
     }
```

- [ ] **Step 4: Run the checks**

Run: `swift test $(scripts/test-flags.sh) --filter CloneSourceTests`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: read what repo clone is given"
```

### Task 2: Read a clone's progress

**Files:**
- Create: `Sources/CanopyCore/Repos/CloneProgress.swift`
- Test: `Tests/CanopyCoreTests/CloneProgressTests.swift`

**Interfaces:**
- Produces: `CloneProgress(phase: String, fraction: Double)` and `CloneProgress.latest(in: Data) -> CloneProgress?`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/CloneProgressTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct CloneProgressTests {
    @Test func readsTheLatestPhaseAndPercent() {
        let output = """
            Cloning into '/tmp/x'...
            remote: Enumerating objects: 30, done.
            remote: Counting objects: 100% (30/30), done.
            Receiving objects:  10% (3/30)\rReceiving objects:  46% (14/30), 1.20 MiB | 2.00 MiB/s\r
            """

        #expect(
            CloneProgress.latest(in: Data(output.utf8)) == CloneProgress(phase: "Receiving objects", fraction: 0.46))
    }

    @Test func dropsTheRemotePrefix() {
        let output = "remote: Compressing objects:  50% (5/10)\r"

        #expect(
            CloneProgress.latest(in: Data(output.utf8)) == CloneProgress(phase: "Compressing objects", fraction: 0.5))
    }

    @Test func skipsALineStillBeingWritten() {
        let output = "Resolving deltas:  75% (3/4)\rResolving del"

        #expect(CloneProgress.latest(in: Data(output.utf8)) == CloneProgress(phase: "Resolving deltas", fraction: 0.75))
    }

    @Test func isNilBeforeAnyPercent() {
        #expect(CloneProgress.latest(in: Data("Cloning into '/tmp/x'...\n".utf8)) == nil)
        #expect(CloneProgress.latest(in: Data([0xFF, 0xFE])) == nil)
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter CloneProgressTests`
Expected: the build fails: `cannot find 'CloneProgress' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Repos/CloneProgress.swift`, new:

```swift
import Foundation

/// How far a clone has got, read from the progress lines git writes to stderr with `--progress`.
public struct CloneProgress: Sendable, Equatable {
    /// What git is doing, such as "Receiving objects" or "Resolving deltas".
    public var phase: String
    /// From 0 to 1, for this phase.
    public var fraction: Double

    public init(phase: String, fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }

    /// The last complete progress line so far. git rewrites a line with `\r` as it goes, and gh passes git's through.
    public static func latest(in output: Data) -> CloneProgress? {
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for line in lines.reversed() {
            if let progress = parse(line) { return progress }
        }
        return nil
    }

    /// Reads `[remote: ]<phase>: <spaces><percent>% ...`.
    private static func parse(_ line: Substring) -> CloneProgress? {
        var text = line
        if text.hasPrefix("remote: ") { text = text.dropFirst("remote: ".count) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let phase = text[..<colon]
        let rest = text[text.index(after: colon)...].drop(while: { $0 == " " })
        guard let percent = rest.firstIndex(of: "%"), let value = Int(rest[..<percent]), (0...100).contains(value),
            !phase.isEmpty
        else { return nil }
        return CloneProgress(phase: String(phase), fraction: Double(value) / 100)
    }
}
```

- [ ] **Step 4: Run the checks**

Run: `swift test $(scripts/test-flags.sh) --filter CloneProgressTests`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: read a clone's progress from git"
```

### Task 3: Stop a subprocess and read its stderr while it runs

**Files:**
- Modify: `Sources/CanopyCore/Support/Subprocess.swift`, `Sources/CanopyCore/Git/GitRunner.swift`
- Test: `Tests/CanopyCoreTests/GitRunnerTests.swift`

**Interfaces:**
- Produces: `SubprocessHandle` with `cancel()`, `isCancelled`, and `errorOutput(last:) -> Data`; `Subprocess.run(..., handle:)`; `GitRunner.run(_:in:timeout:handle:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/GitRunnerTests.swift`:

```diff
@@ -1,3 +1,4 @@
+import Foundation
 import Testing
 
 @testable import CanopyCore
@@ -48,4 +49,53 @@ struct GitRunnerTests {
         let git = try Fixture.git(in: dir, before: "sleep 0.5")
         #expect(try await git.run(["--version"]).hasPrefix("git version"))
     }
+
+    @Test func aHandleStopsGitAndEverythingItStarted() async throws {
+        let dir = try TempDir()
+        let background = dir.sub("background.pid")
+        let git = try Fixture.git(in: dir, before: "sleep 30 &\necho $! > '\(background)'\nsleep 30")
+        let handle = SubprocessHandle()
+        let clock = ContinuousClock()
+        let start = clock.now
+
+        let run = Task { try await git.run(["clone"], handle: handle) }
+        #expect(await eventually { FileManager.default.fileExists(atPath: background) })
+        handle.cancel()
+
+        await #expect(throws: GitError.self) { try await run.value }
+        #expect(handle.isCancelled)
+        #expect(clock.now - start < .seconds(10))
+        let pid = try #require(
+            Int32(String(contentsOfFile: background, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
+        #expect(await eventually { kill(pid, 0) != 0 })
+    }
+
+    @Test func aHandleCancelledFirstStopsGitAsItStarts() async throws {
+        let dir = try TempDir()
+        let git = try Fixture.git(in: dir, before: "sleep 30")
+        let handle = SubprocessHandle()
+        handle.cancel()
+        let clock = ContinuousClock()
+        let start = clock.now
+
+        await #expect(throws: GitError.self) { try await git.run(["clone"], handle: handle) }
+
+        #expect(clock.now - start < .seconds(10))
+    }
+
+    @Test func aHandleReadsWhatGitWroteToStderrSoFar() async throws {
+        let dir = try TempDir()
+        let git = try Fixture.git(in: dir, before: "echo 'Receiving objects:  50% (1/2)' >&2\nsleep 30")
+        let handle = SubprocessHandle()
+
+        let run = Task { try await git.run(["clone"], handle: handle) }
+        let seen = await eventually {
+            String(decoding: handle.errorOutput(), as: UTF8.self).contains("Receiving objects:  50%")
+        }
+        handle.cancel()
+        _ = try? await run.value
+
+        #expect(seen)
+        #expect(handle.errorOutput().isEmpty)
+    }
 }
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter GitRunnerTests`
Expected: the build fails: `cannot find 'SubprocessHandle' in scope`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Support/Subprocess.swift`:

```diff
@@ -1,4 +1,5 @@
 import Foundation
+import Synchronization
 
 public struct SubprocessResult: Sendable {
     public var status: Int32
@@ -16,6 +17,60 @@ public struct SubprocessError: Error, Sendable, Equatable, CustomStringConvertib
     }
 }
 
+/// Lets other threads stop a running subprocess and read what it has written to stderr so far.
+public final class SubprocessHandle: Sendable {
+    private struct State {
+        var pid: pid_t?
+        var errors: Int32 = -1
+        var cancelled = false
+    }
+
+    private let state = Mutex(State())
+
+    public init() {}
+
+    public var isCancelled: Bool {
+        state.withLock { $0.cancelled }
+    }
+
+    /// Kills the process and everything it started. One that has not started yet is killed as it starts.
+    public func cancel() {
+        state.withLock { state in
+            state.cancelled = true
+            if let pid = state.pid { kill(-pid, SIGKILL) }
+        }
+    }
+
+    /// Up to the last `limit` bytes of stderr so far. Empty before the process starts and after it exits.
+    public func errorOutput(last limit: Int = 4096) -> Data {
+        state.withLock { state in
+            guard state.errors >= 0 else { return Data() }
+            var info = stat()
+            guard fstat(state.errors, &info) == 0 else { return Data() }
+            let count = min(Int(info.st_size), limit)
+            var buffer = [UInt8](repeating: 0, count: count)
+            let read = pread(state.errors, &buffer, count, info.st_size - off_t(count))
+            return read > 0 ? Data(buffer[0..<read]) : Data()
+        }
+    }
+
+    /// The process is at worst a zombie until it is reaped, so its pid and group cannot be reused before `exited`.
+    fileprivate func started(pid: pid_t, errors: Int32) {
+        state.withLock { state in
+            state.pid = pid
+            state.errors = errors
+            if state.cancelled { kill(-pid, SIGKILL) }
+        }
+    }
+
+    fileprivate func exited() {
+        state.withLock { state in
+            state.pid = nil
+            state.errors = -1
+        }
+    }
+}
+
 private typealias KeventCall = (
     Int32, UnsafePointer<kevent>?, Int32, UnsafeMutablePointer<kevent>?, Int32, UnsafePointer<timespec>?
 ) -> Int32
@@ -32,7 +87,8 @@ public enum Subprocess {
         _ arguments: [String],
         environment: [String: String],
         directory: String?,
-        timeout: Duration?
+        timeout: Duration?,
+        handle: SubprocessHandle? = nil
     ) throws -> SubprocessResult {
         let output = try temporaryFile(for: executable)
         defer { close(output) }
@@ -64,12 +120,14 @@ public enum Subprocess {
         var pid: pid_t = 0
         let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
         guard spawned == 0 else { throw SubprocessError(executable: executable, code: spawned) }
+        handle?.started(pid: pid, errors: errors)
 
         // Until waitpid reaps it, the child is at worst a zombie, so its pid and process group cannot be reused.
         let timedOut = !waitForExit(pid, timeout: timeout)
         if timedOut {
             kill(-pid, SIGKILL)
         }
+        handle?.exited()
         var status: Int32 = 0
         while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
```

`Sources/CanopyCore/Git/GitRunner.swift`:

```diff
@@ -25,14 +25,15 @@ public struct GitRunner: Sendable {
     }
 
     /// Runs git off the Swift concurrency pool. With a timeout, git and everything it started are killed
-    /// when it expires, and the error has `timedOut` set.
+    /// when it expires, and the error has `timedOut` set. `handle` can stop git and read its stderr as it runs.
     @discardableResult
-    public func run(_ arguments: [String], in directory: String? = nil, timeout: Duration? = nil) async throws
-        -> String
-    {
+    public func run(
+        _ arguments: [String], in directory: String? = nil, timeout: Duration? = nil, handle: SubprocessHandle? = nil
+    ) async throws -> String {
         try await withCheckedThrowingContinuation { continuation in
             DispatchQueue.global().async {
-                continuation.resume(with: Result { try runBlocking(arguments, in: directory, timeout: timeout) })
+                continuation.resume(
+                    with: Result { try runBlocking(arguments, in: directory, timeout: timeout, handle: handle) })
             }
         }
     }
@@ -42,13 +43,16 @@ public struct GitRunner: Sendable {
         (try? await run(arguments, in: directory)) != nil
     }
 
-    private func runBlocking(_ arguments: [String], in directory: String?, timeout: Duration?) throws -> String {
+    private func runBlocking(
+        _ arguments: [String], in directory: String?, timeout: Duration?, handle: SubprocessHandle?
+    ) throws -> String {
         let result: SubprocessResult
         do {
             let environment =
                 baseEnvironment.map { GitEnvironment.build(base: $0, loginPath: nil) } ?? GitEnvironment.current
             result = try Subprocess.run(
-                executable, arguments, environment: environment, directory: directory, timeout: timeout)
+                executable, arguments, environment: environment, directory: directory, timeout: timeout,
+                handle: handle)
         } catch let error as SubprocessError {
             throw GitError(arguments: arguments, exitCode: -1, stderr: error.description)
         }
```

- [ ] **Step 4: Run the checks**

Run: `swift test $(scripts/test-flags.sh) --filter GitRunnerTests`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: stop a subprocess and read its stderr while it runs"
```

### Task 4: Clone and list repos through gh

**Files:**
- Create: `Sources/CanopyCore/PullRequests/GitHubRepoList.swift`
- Modify: `Sources/CanopyCore/PullRequests/GitHubCLI.swift`
- Test: `Tests/CanopyCoreTests/GitHubCLITests.swift`

**Interfaces:**
- Consumes: `SubprocessHandle` from Task 3.
- Produces: `GHFailure` (`ghMissing`, `notLoggedIn`, `failed(String)`), `GitHubCLI.clone(_:into:handle:) async -> GHFailure?`, `GitHubCLI.viewerRepos() async -> Result<[GitHubRepoSummary], GHFailure>`, and `GitHubRepoSummary`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/GitHubCLITests.swift`:

```diff
@@ -76,4 +76,77 @@ struct GitHubCLITests {
 
         #expect(await gh.pullRequests(repo: repo, branches: ["a"]) == .failed("gh did not answer in time."))
     }
+
+    @Test func clonesWithGHAndHasGitReportProgress() async throws {
+        let dir = try TempDir()
+        let gh = try Fixture.gh(in: dir, #"printf '%s\n' "$@" > "\#(dir.sub("args"))"; mkdir "$4""#)
+        let folder = dir.sub("clone")
+
+        let failure = await gh.clone("acme/app", into: folder, handle: SubprocessHandle())
+
+        #expect(failure == nil)
+        let args = try String(contentsOfFile: dir.sub("args"), encoding: .utf8).split(separator: "\n")
+        #expect(args == ["repo", "clone", "acme/app", Substring(folder), "--", "--progress"])
+    }
+
+    @Test func cloneReportsMissingAndLoggedOutGH() async throws {
+        let dir = try TempDir()
+        let missing = GitHubCLI(environment: ["PATH": dir.path, "HOME": dir.path], fallbackFolders: [])
+        let loggedOut = try Fixture.gh(
+            in: dir, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
+
+        #expect(await missing.clone("acme/app", into: dir.sub("a"), handle: SubprocessHandle()) == .ghMissing)
+        #expect(await loggedOut.clone("acme/app", into: dir.sub("b"), handle: SubprocessHandle()) == .notLoggedIn)
+    }
+
+    @Test func cloneFailuresPassOnTheirLastLine() async throws {
+        let dir = try TempDir()
+        let gh = try Fixture.gh(
+            in: dir,
+            """
+            printf 'Cloning into x...\\rReceiving objects:  10%%\\r' >&2
+            echo "fatal: repository 'https://github.com/acme/nope/' not found" >&2
+            exit 1
+            """)
+
+        #expect(
+            await gh.clone("acme/nope", into: dir.sub("x"), handle: SubprocessHandle())
+                == .failed("repository 'https://github.com/acme/nope/' not found"))
+    }
+
+    @Test func listsTheViewersReposWithOneGraphQLCall() async throws {
+        let dir = try TempDir()
+        let gh = try Fixture.gh(
+            in: dir,
+            """
+            printf '%s\\n' "$@" > "\(dir.sub("args"))"
+            echo '{"data": {"viewer": {"repositories": {"nodes": [
+              {"nameWithOwner": "acme/app", "description": "The app", "isPrivate": true, "pushedAt": "2026-09-28T01:00:00Z"},
+              {"nameWithOwner": "me/empty", "description": null, "isPrivate": false, "pushedAt": null}]}}}}'
+            """)
+
+        let listing = await gh.viewerRepos()
+
+        #expect(
+            listing
+                == .success([
+                    GitHubRepoSummary(
+                        nameWithOwner: "acme/app", description: "The app", isPrivate: true,
+                        pushedAt: Date(timeIntervalSince1970: 1_790_557_200)),
+                    GitHubRepoSummary(nameWithOwner: "me/empty", description: nil, isPrivate: false, pushedAt: nil),
+                ]))
+        let args = try String(contentsOfFile: dir.sub("args"), encoding: .utf8)
+        #expect(args.hasPrefix("api\ngraphql\n-f\nquery=query { viewer { repositories("))
+        #expect(args.contains("orderBy: {field: PUSHED_AT, direction: DESC}"))
+        #expect(args.contains("ownerAffiliations: [OWNER, ORGANIZATION_MEMBER]"))
+    }
+
+    @Test func repoListReportsGHTrouble() async throws {
+        let (first, second) = (try TempDir(), try TempDir())
+        let loggedOut = try Fixture.gh(in: first, "exit 4")
+        let garbled = try Fixture.gh(in: second, "echo 'not json'")
+
+        #expect(await loggedOut.viewerRepos() == .failure(.notLoggedIn))
+        #expect(await garbled.viewerRepos() == .failure(.failed("gh returned a reply Canopy could not read.")))
+    }
 }
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter GitHubCLITests`
Expected: the build fails: `value of type 'GitHubCLI' has no member 'clone'`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/PullRequests/GitHubRepoList.swift`, new:

```swift
import Foundation

/// One of the user's GitHub repos, for picking one to clone.
public struct GitHubRepoSummary: Sendable, Equatable, Identifiable {
    public var nameWithOwner: String
    public var description: String?
    public var isPrivate: Bool
    /// Nil for a repo nothing was ever pushed to.
    public var pushedAt: Date?

    public var id: String { nameWithOwner }

    public init(nameWithOwner: String, description: String?, isPrivate: Bool, pushedAt: Date?) {
        self.nameWithOwner = nameWithOwner
        self.description = description
        self.isPrivate = isPrivate
        self.pushedAt = pushedAt
    }
}

/// The user's own repos and those of their organizations, the 100 most recently pushed.
enum RepoListQuery {
    static let text = """
        query { viewer { repositories(first: 100, orderBy: {field: PUSHED_AT, direction: DESC}, \
        ownerAffiliations: [OWNER, ORGANIZATION_MEMBER]) \
        { nodes { nameWithOwner description isPrivate pushedAt } } } }
        """

    static func parse(_ data: Data) throws -> [GitHubRepoSummary] {
        struct Node: Decodable {
            var nameWithOwner: String
            var description: String?
            var isPrivate: Bool
            var pushedAt: String?
        }
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Viewer: Decodable {
                    struct Connection: Decodable { var nodes: [Node] }
                    var repositories: Connection
                }
                var viewer: Viewer
            }
            var data: Payload
        }
        return try JSONDecoder().decode(Response.self, from: data).data.viewer.repositories.nodes.map {
            GitHubRepoSummary(
                nameWithOwner: $0.nameWithOwner, description: $0.description, isPrivate: $0.isPrivate,
                pushedAt: $0.pushedAt.flatMap { try? Date($0, strategy: .iso8601) })
        }
    }
}
```

`Sources/CanopyCore/PullRequests/GitHubCLI.swift`:

```diff
@@ -1,5 +1,12 @@
 import Foundation
 
+/// Why gh could not do what it was asked.
+public enum GHFailure: Error, Sendable, Equatable {
+    case ghMissing
+    case notLoggedIn
+    case failed(String)
+}
+
 public enum PRLookup: Sendable, Equatable {
     /// Each looked-up branch that has a PR.
     case found([String: PullRequest])
@@ -43,45 +50,86 @@ public struct GitHubCLI: Sendable {
     }
 
     public func pullRequests(repo: GitHubRepo, branches: [String]) async -> PRLookup {
+        let query = PRQuery.build(repo: repo, branches: branches)
+        switch await run(["api", "graphql", "-f", "query=\(query)"], timeout: timeout) {
+        case .failure(.ghMissing): return .ghMissing
+        case .failure(.notLoggedIn): return .notLoggedIn
+        case .failure(.failed(let message)): return .failed(message)
+        case .success(let reply):
+            guard let found = try? PRQuery.parse(reply, branches: branches) else { return .failed(Self.unreadable) }
+            return .found(found)
+        }
+    }
+
+    /// Clones with `gh repo clone`, which uses the user's login and preferred git protocol, into `folder`, which must
+    /// not exist yet. git reports progress to stderr, which `handle` reads. Nil when it cloned.
+    public func clone(_ repo: String, into folder: String, handle: SubprocessHandle) async -> GHFailure? {
+        switch await run(["repo", "clone", repo, folder, "--", "--progress"], timeout: nil, handle: handle) {
+        case .success: nil
+        case .failure(let failure): failure
+        }
+    }
+
+    /// The user's repos and their organizations' repos, most recently pushed first.
+    public func viewerRepos() async -> Result<[GitHubRepoSummary], GHFailure> {
+        switch await run(["api", "graphql", "-f", "query=\(RepoListQuery.text)"], timeout: timeout) {
+        case .failure(let failure): return .failure(failure)
+        case .success(let reply):
+            guard let repos = try? RepoListQuery.parse(reply) else { return .failure(.failed(Self.unreadable)) }
+            return .success(repos)
+        }
+    }
+
+    private static let unreadable = "gh returned a reply Canopy could not read."
+
+    /// Runs gh off the Swift concurrency pool and returns what it printed.
+    private func run(
+        _ arguments: [String], timeout: Duration?, handle: SubprocessHandle? = nil
+    ) async -> Result<Data, GHFailure> {
         await withCheckedContinuation { continuation in
             DispatchQueue.global().async {
-                continuation.resume(returning: lookUpBlocking(repo: repo, branches: branches))
+                continuation.resume(returning: runBlocking(arguments, timeout: timeout, handle: handle))
             }
         }
     }
 
-    private func lookUpBlocking(repo: GitHubRepo, branches: [String]) -> PRLookup {
+    private func runBlocking(
+        _ arguments: [String], timeout: Duration?, handle: SubprocessHandle?
+    ) -> Result<Data, GHFailure> {
         var environment = environment ?? GitEnvironment.current
         let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
         guard
             let executable = (folders + fallbackFolders).lazy.map({ $0 + "/gh" }).first(where: {
                 FileManager.default.isExecutableFile(atPath: $0)
             })
-        else { return .ghMissing }
+        else { return .failure(.ghMissing) }
         environment["GH_PROMPT_DISABLED"] = "1"
         environment["GH_NO_UPDATE_NOTIFIER"] = "1"
 
-        let query = PRQuery.build(repo: repo, branches: branches)
         let result: SubprocessResult
         do {
             result = try Subprocess.run(
-                executable, ["api", "graphql", "-f", "query=\(query)"], environment: environment, directory: nil,
-                timeout: timeout)
+                executable, arguments, environment: environment, directory: nil, timeout: timeout, handle: handle)
         } catch {
-            return .failed("\(error)")
+            return .failure(.failed("\(error)"))
         }
-        if result.timedOut { return .failed("gh did not answer in time.") }
+        if result.timedOut { return .failure(.failed("gh did not answer in time.")) }
         let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
         // gh exits 4 when it has no login, and a revoked or expired token comes back as a 401.
-        if result.status == 4 || message.contains("HTTP 401") { return .notLoggedIn }
+        if result.status == 4 || message.contains("HTTP 401") { return .failure(.notLoggedIn) }
         guard result.status == 0 else {
-            let line = message.split(separator: "\n").last.map(String.init) ?? "gh exited with \(result.status)."
-            return .failed(line.hasPrefix("gh: ") ? String(line.dropFirst(4)) : line)
+            // git rewrites progress lines with a carriage return, so those end lines too.
+            let line = message.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init)
+            return .failure(.failed(line.map(Self.withoutPrefix) ?? "gh exited with \(result.status)."))
         }
-        do {
-            return .found(try PRQuery.parse(result.stdout, branches: branches))
-        } catch {
-            return .failed("gh returned a reply Canopy could not read.")
+        return .success(result.stdout)
+    }
+
+    /// gh's and git's own names for a message, which Canopy's messages do not need.
+    private static func withoutPrefix(_ line: String) -> String {
+        for prefix in ["gh: ", "fatal: ", "error: "] where line.hasPrefix(prefix) {
+            return String(line.dropFirst(prefix.count))
         }
+        return line
     }
 }
```

- [ ] **Step 4: Run the checks**

Run: `swift test $(scripts/test-flags.sh) --filter GitHubCLITests`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: clone and list repos through gh"
```

### Task 5: Clone into the workspace and register

**Files:**
- Create: `Sources/CanopyCore/Workspace/Workspace+Clone.swift`, `Sources/CanopyCore/Support/ToolOutput.swift`
- Modify: `Sources/CanopyCore/Workspace/Workspace.swift`, `Sources/CanopyCore/Workspace/WorkspaceError.swift`, `Sources/CanopyCore/PullRequests/GitHubCLI.swift`
- Test: `Tests/CanopyCoreTests/CloneTests.swift`, `Tests/CanopyCoreTests/Support/Fixtures.swift`

**Interfaces:**
- Consumes: `CloneSource` (Task 1), `CloneProgress` (Task 2), `SubprocessHandle` (Task 3), `GitHubCLI.clone` (Task 4).
- Produces: `Workspace.cloneRepo(_ text: String, into: String?, progress:) async throws -> RepoSnapshot`, `Workspace.stopClones()`, `addRepo(path:clonedFrom:)`, and `WorkspaceError.folderTaken(String, holding: String?)`, `.cloneFailed(String, reason: String)`, `.cloneCancelled`.
- Test fixtures: `Fixture.remote(in:_:)`, `Fixture.cloningGH(in:before:sshConfigFile:)`, `Fixture.noGH(in:)`, `Fixture.gitRedirectingGitHub(to:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/Support/Fixtures.swift`:

```diff
@@ -49,6 +49,49 @@ enum Fixture {
             sshConfigFile: sshConfigFile)
     }
 
+    /// A bare repo with one commit at `<dir>/remotes/<owner>/<name>.git`, to clone from.
+    @discardableResult
+    static func remote(in dir: TempDir, _ nameWithOwner: String) async throws -> String {
+        let bare = dir.sub("remotes/\(nameWithOwner).git")
+        let seed = try await repo(in: dir, name: "seed-\(UUID().uuidString.prefix(6))")
+        try await git.run(["clone", "--quiet", "--bare", seed, bare])
+        return Paths.canonical(bare)
+    }
+
+    /// A GitHubCLI whose gh clones `owner/repo` from `<dir>/remotes` and points origin at GitHub, as gh would.
+    /// `before` runs first, with gh's arguments in "$@".
+    static func cloningGH(in dir: TempDir, before: String = "", sshConfigFile: String? = nil) throws -> GitHubCLI {
+        try gh(
+            in: dir, sshConfigFile: sshConfigFile,
+            """
+            \(before)
+            [[ "$1 $2" == "repo clone" ]] || exit 1
+            repo="${3#https://github.com/}"
+            repo="${repo%.git}"
+            if [[ ! -d "\(dir.path)/remotes/$repo.git" ]]; then
+                echo "GraphQL: Could not resolve to a Repository with the name '$repo'. (repository)" >&2
+                exit 1
+            fi
+            git clone "${@:6}" "file://\(dir.path)/remotes/$repo.git" "$4" || exit 1
+            git -C "$4" remote set-url origin "https://github.com/$repo.git"
+            """)
+    }
+
+    /// A GitHubCLI that finds no gh.
+    static func noGH(in dir: TempDir) -> GitHubCLI {
+        GitHubCLI(environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path], fallbackFolders: [])
+    }
+
+    /// A GitRunner that fetches https://github.com/ URLs from `<dir>/remotes` instead, so plain git clones of GitHub
+    /// URLs stay on this machine.
+    static func gitRedirectingGitHub(to dir: TempDir) -> GitRunner {
+        var environment = ProcessInfo.processInfo.environment
+        environment["GIT_CONFIG_COUNT"] = "1"
+        environment["GIT_CONFIG_KEY_0"] = "url.file://\(dir.sub("remotes"))/.insteadOf"
+        environment["GIT_CONFIG_VALUE_0"] = "https://github.com/"
+        return GitRunner(environment: environment)
+    }
+
     static func worktree(repo: String, branch: String, at path: String) async throws {
         try FileManager.default.createDirectory(
             atPath: (path as NSString).deletingLastPathComponent,
```

`Tests/CanopyCoreTests/CloneTests.swift`, new:

```swift
import Foundation
import Synchronization
import Testing

@testable import CanopyCore

struct CloneTests {
    func makeWorkspace(_ dir: TempDir, github: GitHubCLI, git: GitRunner = Fixture.git) async throws -> Workspace {
        let workspace = Workspace(home: CanopyHome(path: dir.sub("home")), git: git, github: github)
        try await workspace.start()
        return workspace
    }

    func origin(of path: String) async throws -> String {
        try await Fixture.git.run(["remote", "get-url", "origin"], in: path).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// Everything in a folder, or nil when it does not exist.
    func contents(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path).sorted()
    }

    // MARK: Cloning

    @Test func clonesOwnerSlashRepoWithGHIntoReposOwnerName() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        let repo = try await workspace.cloneRepo("acme/app")

        #expect(repo.path == dir.sub("home/repos/acme/app"))
        #expect(repo.name == "app")
        #expect(repo.rows.map(\.branch) == ["main"])
        #expect(try await origin(of: repo.path) == "https://github.com/acme/app.git")
        #expect(await workspace.snapshot.repos.map(\.path) == [repo.path])
    }

    @Test func clonesURLsNotOnGitHubWithGit() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))

        let repo = try await workspace.cloneRepo("file://" + bare)

        #expect(repo.path == dir.sub("home/repos/team/lib"))
        #expect(repo.rows.map(\.branch) == ["main"])
    }

    @Test func clonesIntoTheFolderItIsGiven() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))

        let repo = try await workspace.cloneRepo(bare, into: dir.sub("elsewhere/my-lib"))

        #expect(repo.path == dir.sub("elsewhere/my-lib"))
        #expect(repo.name == "my-lib")
    }

    @Test func clonesIntoAnEmptyFolder() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        try FileManager.default.createDirectory(atPath: dir.sub("empty"), withIntermediateDirectories: true)
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))

        let repo = try await workspace.cloneRepo(bare, into: dir.sub("empty"))

        #expect(repo.path == dir.sub("empty"))
    }

    @Test func tellsHowTheCloneIsGoing() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let gh = try Fixture.cloningGH(in: dir, before: "echo 'Receiving objects:  50% (1/2)' >&2; sleep 1")
        let workspace = try await makeWorkspace(dir, github: gh)
        let heard = Mutex<[CloneProgress]>([])

        try await workspace.cloneRepo("acme/app") { progress in heard.withLock { $0.append(progress) } }

        #expect(heard.withLock { $0.first } == CloneProgress(phase: "Receiving objects", fraction: 0.5))
    }

    @Test func logsWhereTheRepoWasClonedFrom() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        let repo = try await ActivitySource.$current.withValue(.cli) { try await workspace.cloneRepo("acme/app") }

        let events = await logged(workspace, "repo")
        #expect(events.map(\.type) == ["repo.added"])
        #expect(events.first?.path == repo.path)
        #expect(events.first?.source == .cli)
        #expect(events.first?.data["clonedFrom"] == "acme/app")
    }

    // MARK: Without gh

    @Test func fallsBackToGitForAGitHubURLWhenGHIsMissing() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let workspace = try await makeWorkspace(
            dir, github: Fixture.noGH(in: dir), git: Fixture.gitRedirectingGitHub(to: dir))

        let repo = try await workspace.cloneRepo("https://github.com/acme/app.git")

        #expect(repo.path == dir.sub("home/repos/acme/app"))
        #expect(repo.rows.map(\.branch) == ["main"])
    }

    @Test func fallsBackToGitForAGitHubURLWhenGHIsLoggedOut() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let gh = try Fixture.gh(
            in: dir, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
        let workspace = try await makeWorkspace(dir, github: gh, git: Fixture.gitRedirectingGitHub(to: dir))

        let repo = try await workspace.cloneRepo("https://github.com/acme/app")

        #expect(repo.rows.map(\.branch) == ["main"])
    }

    @Test func ownerSlashRepoNeedsGHAndSaysHowToGetIt() async throws {
        let dir = try TempDir()
        let missing = try await makeWorkspace(dir, github: Fixture.noGH(in: dir))
        let other = try TempDir()
        let loggedOut = try await makeWorkspace(other, github: try Fixture.gh(in: other, "exit 4"))

        await #expect(
            throws: WorkspaceError.ghUnavailable(
                "Install gh to clone acme/app: `brew install gh`, then `gh auth login`. Or pass the repo's URL.")
        ) { try await missing.cloneRepo("acme/app") }
        await #expect(
            throws: WorkspaceError.ghUnavailable("Run `gh auth login` to clone acme/app, or pass the repo's URL.")
        ) { try await loggedOut.cloneRepo("acme/app") }
        #expect(contents(dir.sub("home/repos")) == nil)
    }

    // MARK: Folders that already exist

    @Test func registersAFolderThatAlreadyHoldsTheSameRepo() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let calls = dir.sub("calls")
        let workspace = try await makeWorkspace(
            dir, github: try Fixture.cloningGH(in: dir, before: "echo x >> '\(calls)'"))

        let first = try await workspace.cloneRepo("acme/app")
        try await workspace.removeRepo(path: first.path)
        let second = try await workspace.cloneRepo("ACME/App")

        #expect(second.path == first.path)
        #expect(try String(contentsOfFile: calls, encoding: .utf8) == "x\n")
        #expect(await workspace.snapshot.repos.map(\.path) == [first.path])
    }

    @Test(arguments: ["git@github.com:ACME/App.git", "git@github-work:acme/app.git", "ssh://git@github.com/acme/app"])
    func recognizesTheSameRepoClonedAnotherWay(origin: String) async throws {
        let dir = try TempDir()
        let sshConfig = dir.sub("ssh_config")
        try "Host github-work\n  HostName github.com\n".write(toFile: sshConfig, atomically: true, encoding: .utf8)
        let folder = dir.sub("home/repos/acme/app")
        try FileManager.default.createDirectory(atPath: dir.sub("home/repos/acme"), withIntermediateDirectories: true)
        try await Fixture.repo(in: dir, name: "home/repos/acme/app")
        try await Fixture.git.run(["remote", "add", "origin", origin], in: folder)
        let gh = try Fixture.gh(in: dir, sshConfigFile: sshConfig, "exit 1")
        let workspace = try await makeWorkspace(dir, github: gh)

        let repo = try await workspace.cloneRepo("acme/app")

        #expect(repo.path == folder)
    }

    @Test func refusesAFolderHoldingAnotherRepo() async throws {
        let dir = try TempDir()
        let folder = try await Fixture.repo(in: dir, name: "taken")
        try await Fixture.git.run(["remote", "add", "origin", "https://github.com/acme/other.git"], in: folder)
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(
            throws: WorkspaceError.folderTaken(folder, holding: "a clone of https://github.com/acme/other.git")
        ) {
            try await workspace.cloneRepo("acme/app", into: folder)
        }
        #expect(await workspace.snapshot.repos.isEmpty)
    }

    @Test func refusesAFolderHoldingARepoWithNoOrigin() async throws {
        let dir = try TempDir()
        let folder = try await Fixture.repo(in: dir, name: "local")
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(throws: WorkspaceError.folderTaken(folder, holding: "a repo with no origin")) {
            try await workspace.cloneRepo("acme/app", into: folder)
        }
    }

    @Test func refusesAFolderHoldingAnythingElseAndLeavesItAlone() async throws {
        let dir = try TempDir()
        let folder = dir.sub("home/repos/acme/app")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "notes".write(toFile: folder + "/notes.txt", atomically: true, encoding: .utf8)
        try "file".write(toFile: dir.sub("a-file"), atomically: true, encoding: .utf8)
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(throws: WorkspaceError.folderTaken(folder, holding: nil)) {
            try await workspace.cloneRepo("acme/app")
        }
        await #expect(throws: WorkspaceError.folderTaken(dir.sub("a-file"), holding: nil)) {
            try await workspace.cloneRepo("acme/app", into: dir.sub("a-file"))
        }
        #expect(contents(folder) == ["notes.txt"])
    }

    @Test func refusesASourceThatWouldLeaveTheReposFolder() async throws {
        let dir = try TempDir()
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(throws: WorkspaceError.invalidCloneSource("https://example.com/acme/..")) {
            try await workspace.cloneRepo("https://example.com/acme/..")
        }
        #expect(contents(dir.sub("home/repos")) == nil)
    }

    // MARK: Failing and stopping

    @Test func aFailedCloneLeavesNothingBehind() async throws {
        let dir = try TempDir()
        let workspace = try await makeWorkspace(dir, github: try Fixture.cloningGH(in: dir))

        await #expect(
            throws: WorkspaceError.cloneFailed(
                "acme/nope",
                reason: "GraphQL: Could not resolve to a Repository with the name 'acme/nope'. (repository)")
        ) { try await workspace.cloneRepo("acme/nope") }

        #expect(contents(dir.sub("home/repos")) == nil)
    }

    @Test func aCloneThatFailsHalfwayLeavesNothingBehind() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "team/lib")
        // git writes the whole clone, then fails the way a checkout can.
        let git = try Fixture.git(
            in: dir,
            before:
                #"[[ "$1" == clone ]] && { /usr/bin/git "$@"; echo 'fatal: unable to checkout working tree' >&2; exit 128; }"#
        )
        let workspace = try await makeWorkspace(dir, github: Fixture.noGH(in: dir), git: git)

        await #expect(throws: WorkspaceError.cloneFailed(bare, reason: "unable to checkout working tree")) {
            try await workspace.cloneRepo(bare, into: dir.sub("new/deeper/lib"))
        }

        #expect(contents(dir.sub("new")) == nil)
    }

    @Test func cancellingStopsTheCloneAndDeletesWhatItWrote() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let sleeper = dir.sub("sleeper.pid")
        let gh = try Fixture.cloningGH(
            in: dir, before: "mkdir -p \"$4\"; touch \"$4/half\"; sleep 30 & echo $! > '\(sleeper)'; wait")
        let workspace = try await makeWorkspace(dir, github: gh)

        let clone = Task { try await workspace.cloneRepo("acme/app") }
        #expect(await eventually { FileManager.default.fileExists(atPath: sleeper) })
        clone.cancel()

        await #expect(throws: WorkspaceError.cloneCancelled) { try await clone.value }
        #expect(contents(dir.sub("home/repos")) == nil)
        let pid = try #require(
            Int32(String(contentsOfFile: sleeper, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { kill(pid, 0) != 0 })
    }

    @Test func stoppingClonesDeletesWhatTheyWroteAtOnce() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let started = dir.sub("started")
        let gh = try Fixture.cloningGH(in: dir, before: "mkdir -p \"$4\"; touch \"$4/half\" '\(started)'; sleep 30")
        let workspace = try await makeWorkspace(dir, github: gh)

        let clone = Task { try await workspace.cloneRepo("acme/app") }
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
        workspace.stopClones()

        #expect(contents(dir.sub("home/repos")) == nil)
        await #expect(throws: WorkspaceError.cloneCancelled) { try await clone.value }
    }

    // MARK: Racing

    @Test func twoClonesOfOneRepoCloneItOnce() async throws {
        let dir = try TempDir()
        try await Fixture.remote(in: dir, "acme/app")
        let calls = dir.sub("calls")
        let gh = try Fixture.cloningGH(in: dir, before: "echo x >> '\(calls)'; sleep 0.5")
        let workspace = try await makeWorkspace(dir, github: gh)

        async let first = workspace.cloneRepo("acme/app")
        async let second = workspace.cloneRepo("https://github.com/acme/app")
        let paths = try await [first.path, second.path]

        #expect(paths == [dir.sub("home/repos/acme/app"), dir.sub("home/repos/acme/app")])
        #expect(try String(contentsOfFile: calls, encoding: .utf8) == "x\n")
        #expect(await workspace.snapshot.repos.count == 1)
    }

    @Test func aFolderFilledWithTheSameRepoDuringTheCloneIsRegistered() async throws {
        let dir = try TempDir()
        let bare = try await Fixture.remote(in: dir, "acme/app")
        let folder = dir.sub("home/repos/acme/app")
        // Another tool clones the same repo into the folder while Canopy's clone runs.
        let gh = try Fixture.cloningGH(
            in: dir,
            before: """
                git clone -q "file://\(bare)" '\(folder)'
                git -C '\(folder)' remote set-url origin https://github.com/acme/app.git
                """)
        let workspace = try await makeWorkspace(dir, github: gh)

        let repo = try await workspace.cloneRepo("acme/app")

        #expect(repo.path == folder)
        #expect(contents(dir.sub("home/repos/acme")) == ["app"])
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter CloneTests`
Expected: the build fails: `value of type 'Workspace' has no member 'cloneRepo'`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Workspace/Workspace+Clone.swift`, new:

```swift
import Foundation
import Synchronization

extension Workspace {
    /// Clones a repo into CANOPY_HOME/repos/<owner>/<name>, or into `folder`, and registers it. A folder that already
    /// holds a clone of the same repo is registered as it is. Clones of one folder run one at a time, so a second clone
    /// of a repo finds the first one's folder. Cancelling the calling task stops the clone and deletes what it wrote.
    @discardableResult
    public func cloneRepo(
        _ text: String, into folder: String? = nil,
        progress: @escaping @Sendable (CloneProgress) -> Void = { _ in }
    ) async throws -> RepoSnapshot {
        let source = try CloneSource(text)
        let destination = Paths.canonical(try folder ?? source.defaultFolder(in: home))
        let handle = SubprocessHandle()
        return try await withTaskCancellationHandler {
            try await serialized(repoPath: destination) {
                try await self.clone(source, to: destination, handle: handle, progress: progress)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Stops every clone under way and deletes what they wrote, without waiting, for quitting.
    public nonisolated func stopClones() {
        runningClones.stopAll()
    }

    /// Clones into a hidden folder beside the destination and renames it into place once git is done, so the
    /// destination only ever holds a whole clone.
    private func clone(
        _ source: CloneSource, to destination: String, handle: SubprocessHandle,
        progress: @escaping @Sendable (CloneProgress) -> Void
    ) async throws -> RepoSnapshot {
        guard !handle.isCancelled else { throw WorkspaceError.cloneCancelled }
        if try await holdsClone(of: source, at: destination) {
            return try await addRepo(path: destination)
        }
        let parent = (destination as NSString).deletingLastPathComponent
        let created: [String]
        do {
            created = try Self.createFolders(parent)
        } catch {
            throw WorkspaceError.cloneFailed(source.text, reason: error.localizedDescription)
        }
        let staging =
            "\(parent)/.\((destination as NSString).lastPathComponent).canopy-clone-\(UUID().uuidString.prefix(8))"
        runningClones.add(handle, folder: staging, created: created)
        defer { runningClones.remove(handle) }
        do {
            try await fetch(source, into: staging, handle: handle, progress: progress)
            guard !handle.isCancelled else { throw WorkspaceError.cloneCancelled }
            // rename(2) replaces an empty folder and refuses a full one.
            if rename(staging, destination) != 0 {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(atPath: staging)
                if try await holdsClone(of: source, at: destination) {
                    return try await addRepo(path: destination)
                }
                throw WorkspaceError.cloneFailed(source.text, reason: reason)
            }
        } catch {
            RunningClones.delete(staging, created: created)
            throw handle.isCancelled ? WorkspaceError.cloneCancelled : error
        }
        return try await addRepo(path: destination, clonedFrom: source.text)
    }

    /// gh for GitHub repos, since it knows the user's login and preferred protocol. Plain git for other URLs, and for
    /// GitHub URLs when gh cannot be used.
    private func fetch(
        _ source: CloneSource, into folder: String, handle: SubprocessHandle,
        progress: @escaping @Sendable (CloneProgress) -> Void
    ) async throws {
        let watcher = Task.detached {
            var last: CloneProgress?
            while !Task.isCancelled {
                if let now = CloneProgress.latest(in: handle.errorOutput()), now != last {
                    last = now
                    progress(now)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }

        if let argument = source.ghArgument, let repo = source.github {
            let fix: String
            switch await github.clone(argument, into: folder, handle: handle) {
            case nil: return
            case .failed(let reason)?: throw WorkspaceError.cloneFailed(source.text, reason: reason)
            case .ghMissing?:
                fix =
                    "Install gh to clone \(repo.nameWithOwner): `brew install gh`, then `gh auth login`. Or pass the repo's URL."
            case .notLoggedIn?:
                fix = "Run `gh auth login` to clone \(repo.nameWithOwner), or pass the repo's URL."
            }
            guard source.url != nil else { throw WorkspaceError.ghUnavailable(fix) }
            try? FileManager.default.removeItem(atPath: folder)
        }
        guard let url = source.url else { return }
        do {
            try await git.run(["clone", "--progress", "--", url, folder], handle: handle)
        } catch let error as GitError {
            throw WorkspaceError.cloneFailed(source.text, reason: ToolOutput.reason(error.stderr) ?? error.description)
        }
    }

    /// Whether `folder` already holds a clone of `source`. False when it is missing or empty, so a clone can go there.
    /// Throws `folderTaken` for anything else.
    private func holdsClone(of source: CloneSource, at folder: String) async throws -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) else { return false }
        guard isFolder.boolValue else { throw WorkspaceError.folderTaken(folder, holding: nil) }
        if (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty == true { return false }
        let top = try? await git.run(["rev-parse", "--show-toplevel"], in: folder)
        guard let top, Paths.canonical(top.trimmingCharacters(in: .whitespacesAndNewlines)) == folder else {
            throw WorkspaceError.folderTaken(folder, holding: nil)
        }
        // The URL as saved, and as git would use it after `insteadOf` rules, since either may name the repo.
        var origins: [String] = []
        for arguments in [["config", "--get", "remote.origin.url"], ["remote", "get-url", "origin"]] {
            let origin = (try? await git.run(arguments, in: folder))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let origin, !origin.isEmpty, !origins.contains(origin) { origins.append(origin) }
        }
        guard let first = origins.first else {
            throw WorkspaceError.folderTaken(folder, holding: "a repo with no origin")
        }
        for origin in origins {
            if source.isSameRepo(asOrigin: origin, gitHubRepo: await github.repo(forRemote: origin)) { return true }
        }
        throw WorkspaceError.folderTaken(folder, holding: "a clone of \(first)")
    }

    /// Creates `path` and any folders above it, and returns the ones it created, outermost first.
    private static func createFolders(_ path: String) throws -> [String] {
        var missing: [String] = []
        var current = path
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            missing.insert(current, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return missing
    }
}

/// Clones under way, with the hidden folder each writes to and the folders it created to hold it.
final class RunningClones: Sendable {
    private struct Clone {
        let handle: SubprocessHandle
        let folder: String
        let created: [String]
    }

    private let clones = Mutex<[ObjectIdentifier: Clone]>([:])

    func add(_ handle: SubprocessHandle, folder: String, created: [String]) {
        clones.withLock { $0[ObjectIdentifier(handle)] = Clone(handle: handle, folder: folder, created: created) }
    }

    func remove(_ handle: SubprocessHandle) {
        _ = clones.withLock { $0.removeValue(forKey: ObjectIdentifier(handle)) }
    }

    func stopAll() {
        let stopping = clones.withLock { clones in
            defer { clones.removeAll() }
            return Array(clones.values)
        }
        for clone in stopping {
            clone.handle.cancel()
            Self.delete(clone.folder, created: clone.created)
        }
    }

    /// Deletes a clone's hidden folder, then the folders it created to hold it, innermost first, while they are empty.
    static func delete(_ folder: String, created: [String]) {
        try? FileManager.default.removeItem(atPath: folder)
        for path in created.reversed() {
            guard rmdir(path) == 0 else { return }
        }
    }
}
```

`Sources/CanopyCore/Support/ToolOutput.swift`, new:

```swift
import Foundation

/// What git and gh print when they fail.
enum ToolOutput {
    /// The last line of `output`, which is where both put the reason, without their own name for the message.
    /// git rewrites progress lines with a carriage return, so those end lines too.
    static func reason(_ output: String) -> String? {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        guard let line = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["gh: ", "fatal: ", "error: "] where trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed
    }
}
```

`Sources/CanopyCore/Workspace/Workspace.swift`:

```diff
@@ -41,6 +41,9 @@ public actor Workspace {
     /// Set by `stop()`, so watcher events and refreshes already under way start no more lookups.
     var prStopped = false
 
+    /// Clones under way, which quitting stops without waiting for the actor.
+    nonisolated let runningClones = RunningClones()
+
     public init(
         home: CanopyHome, git: GitRunner = GitRunner(), fetchTimeout: Duration = .seconds(60),
         github: GitHubCLI = GitHubCLI(), prTiming: PRTiming = .standard, activity: ActivityLog? = nil
@@ -81,6 +84,7 @@ public actor Workspace {
 
     /// Stops watching and releases the home for another instance.
     public func stop() {
+        stopClones()
         watchers.removeAll()
         for task in pendingRefreshes.values {
             task.cancel()
@@ -122,8 +126,9 @@ public actor Workspace {
 
     // MARK: Repos
 
+    /// `clonedFrom` is what a clone was made from, for the activity log.
     @discardableResult
-    public func addRepo(path: String) async throws -> RepoSnapshot {
+    public func addRepo(path: String, clonedFrom: String? = nil) async throws -> RepoSnapshot {
         let mainPath = try await mainCheckout(for: path)
         if state.repos.contains(where: { $0.path == mainPath }) {
             return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
@@ -131,7 +136,9 @@ public actor Workspace {
         let dirName = RepoNaming.dirName(for: mainPath, taken: Set(state.repos.map(\.dirName)))
         state.repos.append(RepoEntry(path: mainPath, dirName: dirName))
         try save()
-        activity.record(ActivityType.repoAdded, repo: snapshot.repo(path: mainPath)?.name, path: mainPath)
+        activity.record(
+            ActivityType.repoAdded, repo: snapshot.repo(path: mainPath)?.name, path: mainPath,
+            data: clonedFrom.map { ["clonedFrom": .string($0)] } ?? [:])
         await watch(repoPath: mainPath)
         await refresh(repoPath: mainPath)
         return snapshot.repo(path: mainPath) ?? RepoSnapshot(path: mainPath, name: "")
```

`Sources/CanopyCore/Workspace/WorkspaceError.swift`:

```diff
@@ -28,6 +28,10 @@ public enum WorkspaceError: Error, Sendable, Equatable {
     case portInOtherRow(Int, row: String)
     case invalidCloneSource(String)
     case cloneNeedsFolder(String)
+    /// `holding` says what the folder holds, such as "a clone of <url>", or is nil for anything that is not a repo.
+    case folderTaken(String, holding: String?)
+    case cloneFailed(String, reason: String)
+    case cloneCancelled
     case git(GitError)
 
     public var code: String {
@@ -61,6 +65,9 @@ public enum WorkspaceError: Error, Sendable, Equatable {
         case .portInOtherRow: "port_in_other_row"
         case .invalidCloneSource: "invalid_clone_source"
         case .cloneNeedsFolder: "missing_target"
+        case .folderTaken: "folder_taken"
+        case .cloneFailed: "clone_failed"
+        case .cloneCancelled: "clone_cancelled"
         case .git: "git_failed"
         }
     }
@@ -101,6 +108,12 @@ public enum WorkspaceError: Error, Sendable, Equatable {
             "Port \(port) belongs to \(row), not to this row. Pass --row \(row), or --all to stop it anywhere."
         case .invalidCloneSource(let text): "Pass owner/repo or a URL to clone, not \"\(text)\"."
         case .cloneNeedsFolder(let text): "Canopy cannot tell which folder \(text) goes in. Pass --into."
+        case .folderTaken(let path, let holding?):
+            "\(path) already holds \(holding). Pass --into to clone somewhere else."
+        case .folderTaken(let path, nil):
+            "\(path) is already there and is not an empty folder. Pass --into to clone somewhere else."
+        case .cloneFailed(let source, let reason): "Could not clone \(source): \(reason)"
+        case .cloneCancelled: "The clone was stopped before it finished."
         case .git(let error): error.description
         }
     }
```

`Sources/CanopyCore/PullRequests/GitHubCLI.swift`:

```diff
@@ -118,18 +118,8 @@ public struct GitHubCLI: Sendable {
         // gh exits 4 when it has no login, and a revoked or expired token comes back as a 401.
         if result.status == 4 || message.contains("HTTP 401") { return .failure(.notLoggedIn) }
         guard result.status == 0 else {
-            // git rewrites progress lines with a carriage return, so those end lines too.
-            let line = message.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init)
-            return .failure(.failed(line.map(Self.withoutPrefix) ?? "gh exited with \(result.status)."))
+            return .failure(.failed(ToolOutput.reason(message) ?? "gh exited with \(result.status)."))
         }
         return .success(result.stdout)
     }
-
-    /// gh's and git's own names for a message, which Canopy's messages do not need.
-    private static func withoutPrefix(_ line: String) -> String {
-        for prefix in ["gh: ", "fatal: ", "error: "] where line.hasPrefix(prefix) {
-            return String(line.dropFirst(prefix.count))
-        }
-        return line
-    }
 }
```

- [ ] **Check the tests catch what they claim to**

One at a time, with the file copied aside first: key the queue by a random string instead of the destination, drop the cleanup in the `catch`, drop the second `holdsClone` after a failed `rename`, drop the deletes in `RunningClones.stopAll`, and drop `handle.cancel()` from `onCancel`.
Expected: `twoClonesOfOneRepoCloneItOnce`, the three cleanup tests, `aFolderFilledWithTheSameRepoDuringTheCloneIsRegistered`, `stoppingClonesDeletesWhatTheyWroteAtOnce`, and `cancellingStopsTheCloneAndDeletesWhatItWrote` fail in turn. Copy the file back after each.

- [ ] **Step 4: Run the checks**

Run: `swift test $(scripts/test-flags.sh) --filter CloneTests`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: clone a repo into the workspace and register it"
```

### Task 6: `repo.clone` and `canopy repo clone`

**Files:**
- Modify: `Sources/CanopyCore/Control/ControlMethods.swift`, `Sources/CanopyCore/Control/WorkspaceControlHandler.swift`, `Sources/CanopyCLI/RepoCommand.swift`, `Sources/CanopyCLI/AgentGuide.swift`
- Test: `Tests/CanopyCoreTests/ControlServerTests.swift`, `Tests/CanopyCoreTests/ControlProtocolTests.swift`

**Interfaces:**
- Consumes: `Workspace.cloneRepo` from Task 5.
- Produces: `ControlMethod.repoClone` (`repo.clone`), `RepoCloneParams(source:into:)`, and the reply `RepoInfo`.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/ControlProtocolTests.swift`:

```diff
@@ -51,6 +51,7 @@ struct JSONValueTests {
     @Test func writesWaitLongerThanReads() {
         #expect(ControlMethod.replyTimeout(for: ControlMethod.rowNew) == nil)
         #expect(ControlMethod.replyTimeout(for: ControlMethod.rowRemove) == nil)
+        #expect(ControlMethod.replyTimeout(for: ControlMethod.repoClone) == nil)
         #expect(ControlMethod.replyTimeout(for: ControlMethod.repoAdd).map { $0 >= 600 } == true)
         #expect(ControlMethod.replyTimeout(for: ControlMethod.status).map { $0 <= 60 } == true)
         #expect(ControlMethod.replyTimeout(for: ControlMethod.rowList).map { $0 <= 60 } == true)
```

`Tests/CanopyCoreTests/ControlServerTests.swift`:

```diff
@@ -315,6 +315,45 @@ struct ControlServerTests {
         #expect(calls.map(\.data["error"]) == [nil, nil, "invalid_branch"])
     }
 
+    @Test func repoCloneAnswersLikeRepoAddAndIsLogged() async throws {
+        let dir = try TempDir()
+        try await Fixture.remote(in: dir, "acme/app")
+        let (workspace, server, client, _) = try await startServer(dir, github: try Fixture.cloningGH(in: dir))
+        defer { server.stop() }
+
+        let cloned = try await call(
+            client, ControlMethod.repoClone, RepoCloneParams(source: "acme/app"), as: RepoInfo.self)
+        let again = try await call(client, ControlMethod.repoClone, ["source": "acme/app"], as: RepoInfo.self)
+
+        #expect(cloned.name == "app")
+        #expect(cloned.path == dir.sub("home/repos/acme/app"))
+        #expect(cloned.rows == 1)
+        #expect(again == cloned)
+        let events = await logged(workspace, "repo", "cli")
+        #expect(events.map(\.type) == ["repo.added", "cli.call", "cli.call"])
+        #expect(events.allSatisfy { $0.source == .cli })
+        #expect(events[0].data["clonedFrom"] == "acme/app")
+        #expect(events[1].data["method"] == "repo.clone")
+        #expect(events[1].data["params"] == .object(["source": .string("acme/app")]))
+    }
+
+    @Test func repoCloneErrorsCarryCodes() async throws {
+        let dir = try TempDir()
+        let taken = try await Fixture.repo(in: dir, name: "taken")
+        let (_, server, client, _) = try await startServer(dir, github: try Fixture.cloningGH(in: dir))
+        defer { server.stop() }
+
+        func code(_ params: RepoCloneParams) async throws -> String? {
+            let request = ControlRequest(method: ControlMethod.repoClone, params: try .from(params))
+            return try await offPool { try client.send(request) }.error?.code
+        }
+
+        #expect(try await code(RepoCloneParams(source: "acme/app", into: taken)) == "folder_taken")
+        #expect(try await code(RepoCloneParams(source: "acme/nope")) == "clone_failed")
+        #expect(try await code(RepoCloneParams(source: "nope")) == "invalid_clone_source")
+        #expect(try await code(RepoCloneParams(source: "acme/app", into: "relative/app")) == "bad_params")
+    }
+
     @Test func commandTextIsLeftOutOfCallsWhenCommandLoggingIsOff() async throws {
         let dir = try TempDir()
         let repo = try await Fixture.repo(in: dir)
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter 'ControlServerTests|ControlProtocolTests'`
Expected: the build fails: `type 'ControlMethod' has no member 'repoClone'`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/Control/ControlMethods.swift`:

```diff
@@ -5,6 +5,7 @@ public enum ControlMethod {
     public static let repoAdd = "repo.add"
     public static let repoList = "repo.list"
     public static let repoRemove = "repo.remove"
+    public static let repoClone = "repo.clone"
     public static let rowList = "row.list"
     public static let rowNew = "row.new"
     public static let rowRemove = "row.remove"
@@ -19,10 +20,11 @@ public enum ControlMethod {
 
     /// How long the CLI waits for a reply. Changes to a repo queue behind other git work in that repo, so they
     /// can take minutes. Creating and removing rows also wait for setup or teardown, which can run for as long as
-    /// a build does and cannot be cancelled, so the CLI waits for them without a limit. A PR lookup can queue
-    /// behind one already asking GitHub, and each may take 30 seconds. Other reads answer from memory.
+    /// a build does and cannot be cancelled, so the CLI waits for them without a limit, and so does a clone, which
+    /// takes as long as the repo is big. A PR lookup can queue behind one already asking GitHub, and each may take
+    /// 30 seconds. Other reads answer from memory.
     public static func replyTimeout(for method: String) -> TimeInterval? {
-        if [rowNew, rowRemove].contains(method) { return nil }
+        if [rowNew, rowRemove, repoClone].contains(method) { return nil }
         if method == prShow { return 90 }
         return [repoAdd, repoRemove, rowAdopt].contains(method) ? 900 : 30
     }
@@ -87,6 +89,18 @@ public struct RepoAddParams: Codable, Sendable {
     }
 }
 
+public struct RepoCloneParams: Codable, Sendable {
+    /// `owner/repo`, or a URL git can clone.
+    public var source: String
+    /// An absolute path to clone into. CANOPY_HOME/repos/<owner>/<name> when nil.
+    public var into: String?
+
+    public init(source: String, into: String? = nil) {
+        self.source = source
+        self.into = into
+    }
+}
+
 public struct RepoRemoveParams: Codable, Sendable {
     /// A repo display name or path.
     public var repo: String
```

`Sources/CanopyCore/Control/WorkspaceControlHandler.swift`:

```diff
@@ -79,6 +79,14 @@ public struct WorkspaceControlHandler: Sendable {
             let params = try request.decodeParams(RepoAddParams.self)
             return try .from(RepoInfo(try await workspace.addRepo(path: params.path)))
 
+        case ControlMethod.repoClone:
+            let params = try request.decodeParams(RepoCloneParams.self)
+            // The app runs in another folder than the caller, so a relative path would land somewhere unexpected.
+            if let into = params.into, !(into as NSString).expandingTildeInPath.hasPrefix("/") {
+                throw ControlError(code: "bad_params", message: "into must be an absolute path, not \(into).")
+            }
+            return try .from(RepoInfo(try await workspace.cloneRepo(params.source, into: params.into)))
+
         case ControlMethod.repoList:
             return try .from(await workspace.snapshot.repos.map(RepoInfo.init))
```

`Sources/CanopyCLI/RepoCommand.swift`:

```diff
@@ -4,8 +4,8 @@ import CanopyCore
 struct RepoCommand: AsyncParsableCommand {
     static let configuration = CommandConfiguration(
         commandName: "repo",
-        abstract: "Register and list repositories.",
-        subcommands: [Add.self, List.self, Remove.self]
+        abstract: "Register, clone, and list repositories.",
+        subcommands: [Add.self, Clone.self, List.self, Remove.self]
     )
 
     struct Add: AsyncParsableCommand {
@@ -25,6 +25,35 @@ struct RepoCommand: AsyncParsableCommand {
         }
     }
 
+    struct Clone: AsyncParsableCommand {
+        static let configuration = CommandConfiguration(
+            abstract: "Clone a repository and register it.",
+            discussion: """
+                owner/repo and GitHub URLs clone with gh, which uses your login and preferred protocol. \
+                Other URLs clone with git, and so do GitHub URLs when gh is missing or logged out. \
+                The clone goes in CANOPY_HOME/repos/<owner>/<name> unless --into names a folder. \
+                A folder that already holds the repo is registered as it is.
+                """
+        )
+
+        @Argument(help: "owner/repo, or a URL git can clone.")
+        var source: String
+        @Option(help: ArgumentHelp("The folder to clone into.", valueName: "dir"))
+        var into: String?
+        @OptionGroup var output: OutputOptions
+
+        func run() async throws {
+            let client = Client(json: output.json)
+            let params = RepoCloneParams(
+                source: Client.absolutePathIfRelative(source), into: into.map(Client.absolutePath))
+            let result = client.call(ControlMethod.repoClone, params)
+            try client.print(result) {
+                let repo = try result.decode(RepoInfo.self)
+                return "Added \(repo.name) (\(repo.path))."
+            }
+        }
+    }
+
     struct List: AsyncParsableCommand {
         static let configuration = CommandConfiguration(abstract: "List registered repositories.")
```

`Sources/CanopyCLI/AgentGuide.swift`:

```diff
@@ -24,6 +24,7 @@ struct AgentGuide: ParsableCommand {
         ## Repos and rows
 
             canopy repo add <path> | canopy repo list | canopy repo rm <name>
+            canopy repo clone <owner/repo | url> [--into <dir>]
 
             canopy row list [--all]                       rows, and other tools' worktrees with --all
             canopy row new <branch> [--from <ref>] [--run <cmd>] [--no-setup] [--select]
@@ -31,6 +32,9 @@ struct AgentGuide: ParsableCommand {
             canopy row select [<branch>]
             canopy row adopt <path>                       show another tool's worktree as a row
 
+        `repo clone` clones with your gh login into CANOPY_HOME/repos/<owner>/<name> and registers the repo. Run it
+        again and it registers the folder it already made. `repo rm` only unregisters and never deletes files.
+
         `row new` creates the branch and worktree, runs the repo's setup commands from .canopy/config.json in a
         Setup tab, waits for them, then types `--run` into a new terminal. If setup fails, the row stays, the
         command is not run, and `row new` exits 1. `row rm` runs teardown first, then removes the worktree.
```

- [ ] **Step 4: Run the checks**

Run: `swift test $(scripts/test-flags.sh) --filter 'ControlServerTests|ControlProtocolTests' && .build/debug/canopy repo clone --help`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: canopy repo clone"
```

### Task 7: The window: the `+` menu, File > Clone Repo…, and the sheet

**Files:**
- Create: `Sources/CanopyApp/Repos/CloneRepoSheet.swift`
- Modify: `Sources/CanopyApp/AppModel.swift`, `Sources/CanopyApp/CanopyApp.swift`, `Sources/CanopyApp/RootView.swift`, `Sources/CanopyApp/Sidebar/SidebarView.swift`, `Sources/CanopyApp/Style/Style.swift`, `Sources/CanopyCore/PullRequests/GitHubRepoList.swift`, `Sources/CanopyCore/Workspace/Workspace+Clone.swift`
- Test: `Tests/CanopyCoreTests/GitHubRepoListTests.swift`

**Interfaces:**
- Consumes: `Workspace.cloneRepo`, `Workspace.stopClones` (Task 5), `GitHubCLI.viewerRepos` (Task 4).
- Produces: `GitHubRepoSummary.filter(_:by:)`, `GHFailure.repoListNote`, `Workspace.gitHubRepos()`, `AppModel.showCloneSheet()`, `AppModel.cloneRepo(_:progress:)`, `AppModel.cloneFolder(for:)`, and `IconMenu`, which the repo `…` menu now uses too.

- [ ] **Step 1: Write the failing tests**

`Tests/CanopyCoreTests/GitHubRepoListTests.swift`, new:

```swift
import Foundation
import Testing

@testable import CanopyCore

struct GitHubRepoListTests {
    let repos = ["acme/web-app", "acme/api", "NE1NN/canopy", "other/app"].map {
        GitHubRepoSummary(nameWithOwner: $0, description: nil, isPrivate: false, pushedAt: nil)
    }

    func names(_ typed: String) -> [String] {
        GitHubRepoSummary.filter(repos, by: typed).map(\.nameWithOwner)
    }

    @Test func showsEverythingUntilSomethingIsTyped() {
        #expect(names("  ") == ["acme/web-app", "acme/api", "NE1NN/canopy", "other/app"])
    }

    @Test func keepsReposWhoseNameHoldsTheTextInAnyCase() {
        #expect(names("APP") == ["acme/web-app", "other/app"])
        #expect(names("ne1nn/") == ["NE1NN/canopy"])
    }

    @Test func matchesAPastedGitHubURLByItsRepo() {
        #expect(names("git@github.com:ne1nn/canopy.git") == ["NE1NN/canopy"])
        #expect(names("https://github.com/acme/api") == ["acme/api"])
    }

    @Test func saysHowToFixGH() {
        #expect(
            GHFailure.ghMissing.repoListNote
                == "Install gh to see your repos here: `brew install gh`, then `gh auth login`. You can still paste a URL."
        )
        #expect(
            GHFailure.notLoggedIn.repoListNote
                == "Run `gh auth login` to see your repos here. You can still paste a URL.")
        #expect(GHFailure.failed("HTTP 502").repoListNote == "Your repos did not load: HTTP 502")
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test $(scripts/test-flags.sh) --filter GitHubRepoListTests`
Expected: the build fails: `type 'GitHubRepoSummary' has no member 'filter'`.

- [ ] **Step 3: Implement it**

`Sources/CanopyCore/PullRequests/GitHubRepoList.swift`:

```diff
@@ -18,6 +18,28 @@ public struct GitHubRepoSummary: Sendable, Equatable, Identifiable {
     }
 }
 
+extension GitHubRepoSummary {
+    /// The repos whose `owner/name` holds what was typed, ignoring case. A pasted GitHub URL matches its own repo.
+    public static func filter(_ repos: [GitHubRepoSummary], by typed: String) -> [GitHubRepoSummary] {
+        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
+        guard !text.isEmpty else { return repos }
+        let wanted = (try? CloneSource(text))?.github?.nameWithOwner ?? text
+        return repos.filter { $0.nameWithOwner.localizedCaseInsensitiveContains(wanted) }
+    }
+}
+
+extension GHFailure {
+    /// What the clone sheet shows in place of the repo list, with the fix.
+    public var repoListNote: String {
+        switch self {
+        case .ghMissing:
+            "Install gh to see your repos here: `brew install gh`, then `gh auth login`. You can still paste a URL."
+        case .notLoggedIn: "Run `gh auth login` to see your repos here. You can still paste a URL."
+        case .failed(let message): "Your repos did not load: \(message)"
+        }
+    }
+}
+
 /// The user's own repos and those of their organizations, the 100 most recently pushed.
 enum RepoListQuery {
     static let text = """
```

`Sources/CanopyCore/Workspace/Workspace+Clone.swift`:

```diff
@@ -22,6 +22,11 @@ extension Workspace {
         }
     }
 
+    /// The user's GitHub repos and their organizations', for picking one to clone.
+    public nonisolated func gitHubRepos() async -> Result<[GitHubRepoSummary], GHFailure> {
+        await github.viewerRepos()
+    }
+
     /// Stops every clone under way and deletes what they wrote, without waiting, for quitting.
     public nonisolated func stopClones() {
         runningClones.stopAll()
```

`Sources/CanopyApp/Style/Style.swift`:

```diff
@@ -131,6 +131,32 @@ struct IconButton: View {
     }
 }
 
+/// A borderless icon that opens a menu, drawn like `IconButton`.
+struct IconMenu<Items: View>: View {
+    let title: String
+    let systemImage: String
+    @ViewBuilder var items: Items
+    @State private var isHovering = false
+
+    var body: some View {
+        Menu {
+            items
+        } label: {
+            Image(systemName: systemImage)
+                .font(.system(size: 12, weight: .medium))
+        }
+        .menuStyle(.button)
+        .buttonStyle(.plain)
+        .menuIndicator(.hidden)
+        .frame(width: 22, height: 22)
+        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
+        .foregroundStyle(isHovering ? .primary : .secondary)
+        .onHover { isHovering = $0 }
+        .help(title)
+        .accessibilityLabel(title)
+    }
+}
+
 /// The accent dot that marks a program running in a row, tab, or pane.
 struct RunningDot: View {
     var size = 6.0
```

`Sources/CanopyApp/Sidebar/SidebarView.swift`:

```diff
@@ -43,8 +43,9 @@ struct SidebarView: View {
             VStack(alignment: .leading, spacing: 0) {
                 if !model.snapshot.repos.isEmpty {
                     SectionLabel(title: "Repos") {
-                        IconButton(title: "Add Repo…", systemImage: "plus", shortcut: "⇧⌘O") {
-                            model.chooseFolder(for: .addRepo)
+                        IconMenu(title: "Add Repo", systemImage: "plus") {
+                            Button("Add Local Repo…") { model.chooseFolder(for: .addRepo) }
+                            Button("Clone from GitHub…", action: model.showCloneSheet)
                         }
                     }
                 }
@@ -191,24 +192,11 @@ struct RepoHeaderView: View {
 struct RepoMenu: View {
     let repo: RepoSnapshot
     let onNewRow: () -> Void
-    @State private var isHovering = false
 
     var body: some View {
-        Menu {
+        IconMenu(title: "More for \(repo.name)", systemImage: "ellipsis") {
             RepoMenuItems(repo: repo, onNewRow: onNewRow)
-        } label: {
-            Image(systemName: "ellipsis")
-                .font(.system(size: 12, weight: .medium))
         }
-        .menuStyle(.button)
-        .buttonStyle(.plain)
-        .menuIndicator(.hidden)
-        .frame(width: 22, height: 22)
-        .background(isHovering ? Style.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 5))
-        .foregroundStyle(isHovering ? .primary : .secondary)
-        .onHover { isHovering = $0 }
-        .help("More for \(repo.name)")
-        .accessibilityLabel("More for \(repo.name)")
     }
 }
```

`Sources/CanopyApp/CanopyApp.swift`:

```diff
@@ -70,6 +70,7 @@ struct TerminalCommands: Commands {
         CommandGroup(after: .newItem) {
             Button("Add Repo…") { model.chooseFolder(for: .addRepo) }
                 .keyboardShortcut("o", modifiers: [.command, .shift])
+            Button("Clone Repo…", action: model.showCloneSheet)
             Divider()
             Button("New Tab", action: model.newTab)
                 .keyboardShortcut("t")
```

`Sources/CanopyApp/RootView.swift`:

```diff
@@ -39,6 +39,9 @@ struct RootView: View {
         }
         .animation(.snappy, value: model.toast)
         .fileImporter(isPresented: $model.isChoosingFolder, allowedContentTypes: [.folder]) { model.folderChosen($0) }
+        .sheet(isPresented: $model.isShowingCloneSheet) {
+            CloneRepoSheet()
+        }
         .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
             model.refresh()
         }
```

`Sources/CanopyApp/AppModel.swift`:

```diff
@@ -88,6 +88,7 @@ final class AppModel {
     }
 
     func shutdown() {
+        workspace.stopClones()
         portsTask?.cancel()
         activityTask?.cancel()
         server?.stop()
@@ -550,6 +551,32 @@ final class AppModel {
         perform { try await $0.prune(repoPath: repo.path) }
     }
 
+    // MARK: Cloning
+
+    /// The Repos `+` menu and File > Clone Repo….
+    var isShowingCloneSheet = false
+
+    func showCloneSheet() {
+        isShowingCloneSheet = true
+    }
+
+    func gitHubRepos() async -> Result<[GitHubRepoSummary], GHFailure> {
+        await workspace.gitHubRepos()
+    }
+
+    /// Where a clone of `text` goes, or nil while it is not something to clone.
+    func cloneFolder(for text: String) -> String? {
+        try? CloneSource(text).defaultFolder(in: home)
+    }
+
+    /// Clones a repo into its default folder and selects its main row. Cancelling the calling task stops the clone.
+    func cloneRepo(_ text: String, progress: @escaping @Sendable (CloneProgress) -> Void) async throws {
+        let repo = try await workspace.cloneRepo(text, progress: progress)
+        if let main = repo.rows.first {
+            await select(main.path)
+        }
+    }
+
     // MARK: Internals
 
     private func apply(_ snapshot: WorkspaceSnapshot) {
```

`Sources/CanopyApp/Repos/CloneRepoSheet.swift`, new:

```swift
import CanopyCore
import SwiftUI

/// One field for `owner/repo` or a URL, with the user's GitHub repos below it to pick from.
struct CloneRepoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clone = CloneRepoState()
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var clone = clone
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone Repo")
                .font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                TextField("Repo", text: $clone.source, prompt: Text("owner/repo or URL"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .onSubmit(start)
                    .disabled(clone.isCloning)
                // Kept at one line even when empty, so the list does not jump as it appears.
                Text(destination ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            GitHubRepoList(
                listing: clone.listing, repos: clone.repos, chosen: clone.source,
                pick: { clone.source = $0.nameWithOwner }
            )
            .frame(height: 260)
            .disabled(clone.isCloning)
            if clone.isCloning {
                CloneProgressView(source: clone.source, progress: clone.progress)
            }
            if let error = clone.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    clone.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || clone.isCloning)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { await clone.load(from: model) }
        .onAppear { isFieldFocused = true }
        .onDisappear { clone.cancel() }
    }

    private var destination: String? {
        model.cloneFolder(for: clone.source).map { "Clones into \(($0 as NSString).abbreviatingWithTildeInPath)" }
    }

    private func start() {
        guard destination != nil else { return }
        clone.start(with: model) { dismiss() }
    }
}

/// The sheet's state, kept out of the view so progress from the clone can reach it.
@MainActor
@Observable
final class CloneRepoState {
    var source = ""
    private(set) var listing: Result<[GitHubRepoSummary], GHFailure>?
    private(set) var isCloning = false
    private(set) var progress: CloneProgress?
    private(set) var error: String?
    @ObservationIgnored private var cloning: Task<Void, Never>?

    var repos: [GitHubRepoSummary] {
        guard case .success(let repos) = listing else { return [] }
        return GitHubRepoSummary.filter(repos, by: source)
    }

    func load(from model: AppModel) async {
        listing = await model.gitHubRepos()
    }

    func start(with model: AppModel, then done: @escaping @MainActor () -> Void) {
        guard !isCloning else { return }
        isCloning = true
        progress = nil
        error = nil
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        cloning = Task {
            do {
                try await model.cloneRepo(text) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.isCloning == true else { return }
                        self?.progress = progress
                    }
                }
                done()
            } catch WorkspaceError.cloneCancelled {
                // Cancel closed the sheet already.
            } catch {
                self.error = (error as? WorkspaceError)?.message ?? "\(error)"
            }
            isCloning = false
        }
    }

    /// Stops a clone under way, which deletes what it wrote.
    func cancel() {
        cloning?.cancel()
    }
}

/// The user's repos, newest push first, or why they cannot be listed.
struct GitHubRepoList: View {
    let listing: Result<[GitHubRepoSummary], GHFailure>?
    let repos: [GitHubRepoSummary]
    let chosen: String
    let pick: (GitHubRepoSummary) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    @ViewBuilder private var content: some View {
        switch listing {
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your repos…")
                    .foregroundStyle(.secondary)
            }
        case .failure(let failure):
            Label {
                Text((try? AttributedString(markdown: failure.repoListNote)) ?? AttributedString(failure.repoListNote))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .foregroundStyle(.secondary)
            .padding(24)
        case .success where repos.isEmpty:
            Text("No repos match.")
                .foregroundStyle(.secondary)
        case .success:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(repos) { repo in
                        GitHubRepoLine(
                            repo: repo, isChosen: repo.nameWithOwner.caseInsensitiveCompare(chosen) == .orderedSame,
                            pick: { pick(repo) })
                    }
                }
                .padding(4)
            }
        }
    }
}

struct GitHubRepoLine: View {
    let repo: GitHubRepoSummary
    let isChosen: Bool
    let pick: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    name
                        .font(Style.row)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let description = repo.description, !description.isEmpty {
                        Text(description)
                            .font(Style.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let pushedAt = repo.pushedAt {
                    Text(pushedAt, format: .relative(presentation: .named))
                        .font(Style.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(repo.isPrivate ? "\(repo.nameWithOwner), private" : repo.nameWithOwner)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// The owner dimmed before the repo's own name.
    private var name: Text {
        let parts = repo.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return Text(verbatim: repo.nameWithOwner) }
        return Text(verbatim: parts[0] + "/").foregroundStyle(.secondary) + Text(verbatim: parts[1])
    }

    private var fill: Color {
        if isChosen { return Style.selectionFill }
        return isHovering ? Style.hoverFill : .clear
    }
}

struct CloneProgressView: View {
    let source: String
    let progress: CloneProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Cloning \(source)…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let progress {
                    Text(verbatim: "\(progress.phase) \(Int(progress.fraction * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let progress {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }
}
```

- [ ] **Step 4: Run the checks**

Run: `swift test $(scripts/test-flags.sh) --filter GitHubRepoListTests && swift build`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: clone repos from the window"
```

### Task 8: The spec, an e2e case, and fixture support

**Files:**
- Modify: `docs/superpowers/specs/2026-09-27-canopy-design.md`, `scripts/e2e.sh`, `scripts/ui-fixture.sh`, `scripts/window-shot.swift`

**Interfaces:**
- Consumes: `canopy repo clone` from Task 6 and the sheet from Task 7.

- [ ] **Step 1: Make the change**

`docs/superpowers/specs/2026-09-27-canopy-design.md`:

```diff
@@ -93,6 +93,7 @@ Everything lives in `CANOPY_HOME`, which defaults to `~/.canopy`.
   config.json                global settings
   canopy.sock                control socket
   worktrees/<repo>/<slug>/   rows created by Canopy
+  repos/<owner>/<name>/      repos cloned by Canopy
   activity/2026-09-27.jsonl  activity log, one file per local day
   shell/zsh/                 zsh startup shim for command logging
 ```
@@ -129,7 +130,26 @@ A repo is added from the UI or with `canopy repo add <path>`.
 If the path is a linked worktree, Canopy resolves it to the main checkout.
 A repo's display name is its folder name.
 If two repos share a folder name, each gets as many parent folder names as it takes to tell them apart, such as `work/client/app` and `personal/client/app`.
-Removing a repo only unregisters it and never touches files.
+Removing a repo only unregisters it and never touches files, including a folder Canopy cloned.
+
+### Cloning repos
+
+A repo can also be cloned and registered in one step, from the window or with `canopy repo clone <owner/repo | url> [--into <dir>]`.
+The clone runs in the app, and the CLI waits for it with no timeout.
+
+- `owner/repo` and GitHub URLs clone with `gh repo clone`, which uses the author's gh login and preferred git protocol.
+  When gh is missing or logged out, a URL clones with `git clone` instead, and `owner/repo` fails with the fix, such as `gh auth login`.
+- Other URLs, including `file://` URLs and local paths, clone with `git clone`, since gh only clones from GitHub.
+- The clone goes in `CANOPY_HOME/repos/<owner>/<name>` unless `--into` names a folder.
+  The owner keeps two repos named `app` apart, and the naming rule above shows them as `acme/app` and `other/app`.
+  For a URL not on GitHub, the owner is the folder above the repo in the URL.
+- If the folder already holds a clone of the same repo, Canopy registers it and stops, so running the same clone twice is safe.
+  A GitHub repo is the same whatever the protocol, SSH host alias, or letter case of the folder's `origin`.
+  A folder holding anything else fails with `folder_taken`.
+- git writes into a hidden folder beside the destination, which is renamed into place once the clone is whole.
+  A clone that fails, is cancelled, or is still running when Canopy quits leaves nothing behind.
+- Clones of the same folder run one at a time, so a second one finds the first one's result.
+- Stopping `canopy repo clone` with Ctrl-C does not stop the clone, which finishes and registers the repo.
 
 ### Discovery
 
@@ -212,8 +232,16 @@ They get these environment variables:
 
 ## Sidebar rows
 
-A "Repos" label heads the sidebar, with a `+` that adds a repo.
-File > Add Repo… (`⇧⌘O`) and the empty sidebar's button add one too.
+A "Repos" label heads the sidebar, with a `+` menu holding "Add Local Repo…" and "Clone from GitHub…".
+File > Add Repo… (`⇧⌘O`) and the empty sidebar's button add one too, and File > Clone Repo… clones one.
+
+The clone sheet has one field that takes `owner/repo` or a URL, and says where the clone will go.
+Below it are the author's GitHub repos and their organizations' repos, the 100 most recently pushed first, filtered by what is typed.
+Clicking one fills the field.
+While gh is missing or logged out, the list's place shows the fix, and the field still clones URLs.
+The sheet shows git's progress while it clones and git's or gh's reason if the clone fails.
+Cancel stops the clone and deletes what it wrote.
+A clone from the window selects the new repo's main row.
 
 Each repo group starts with a header: a tile with the repo's first letter, its name, and its row count.
 The tile takes one of eight hues, picked by a stable hash of the repo's path, so a repo keeps its color across launches.
@@ -491,6 +519,7 @@ Every command exits non-zero on failure.
 |---|---|
 | `canopy status` | whether the app is running, its version, and `CANOPY_HOME` |
 | `canopy repo add <path>` | register a repo |
+| `canopy repo clone <owner/repo \| url> [--into <dir>]` | clone a repo and register it |
 | `canopy repo list` | list repos |
 | `canopy repo rm <name>` | unregister a repo |
 | `canopy row list [--all]` | list rows, including external ones with `--all` |
@@ -541,7 +570,7 @@ Readers skip a trailing partial line and any line they cannot read.
 
 | Type | Recorded when | `data` |
 |---|---|---|
-| `repo.added`, `repo.removed` | a repo is registered or unregistered | |
+| `repo.added`, `repo.removed` | a repo is registered or unregistered | `clonedFrom` when Canopy cloned it |
 | `row.created`, `row.adopted`, `row.removed` | a row appears, is adopted, or goes away, including being un-adopted | `class` |
 | `row.branch_changed` | a row's HEAD moves to another branch | `from`, `to`, null when detached |
 | `pr.opened` | a row's branch goes from no PR, or a closed one, to a new PR | `number`, `title`, `state`, `url` |
```

`scripts/e2e.sh`:

```diff
@@ -267,5 +267,92 @@ done
 "$cli" log --type repo.added | grep -q demo || fail "canopy log needs the app"
 [[ -z "$(app_pid)" ]] || fail "canopy log launched the app"
 
+step "canopy repo clone clones owner/repo through gh into repos/<owner>/<name>"
+# A stand-in gh clones from local bare repos and points origin at GitHub, as gh would, so nothing reaches the network.
+# The app finds it first on its login PATH through a ZDOTDIR, so this part launches the app itself.
+mkdir -p "$work/bin" "$work/zdot"
+cat > "$work/bin/gh" <<'GH'
+#!/bin/bash
+remotes="$(cd "$(dirname "$0")/.." && pwd)/remotes"
+# PR lookups for the repos above find no PRs.
+[[ "$1 $2" == "api graphql" ]] && { echo '{"data": {"repository": {}}}'; exit 0; }
+[[ "$1 $2" == "repo clone" ]] || { echo "gh: the stand-in only clones" >&2; exit 1; }
+repo="${3#https://github.com/}"
+repo="${repo%.git}"
+if [[ ! -d "$remotes/$repo.git" ]]; then
+    echo "GraphQL: Could not resolve to a Repository with the name '$repo'. (repository)" >&2
+    exit 1
+fi
+git clone "${@:6}" "file://$remotes/$repo.git" "$4" || exit 1
+git -C "$4" remote set-url origin "https://github.com/$repo.git"
+GH
+chmod +x "$work/bin/gh"
+printf 'export PATH="%s/bin:$PATH"\n' "$work" > "$work/zdot/.zshrc"
+for repo in acme/app other/app team/lib; do
+    git clone -q --bare "$work/demo" "$work/remotes/$repo.git"
+done
+(ZDOTDIR="$work/zdot" SHELL=/bin/zsh exec "$app/Contents/MacOS/Canopy" </dev/null >/dev/null 2>&1) &
+for _ in $(seq 1 100); do
+    [[ -n "$(app_pid)" ]] && break
+    sleep 0.1
+done
+[[ -n "$(app_pid)" ]] || fail "the app did not start"
+json_field() { /usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$@"; }
+repos="$(cd "$CANOPY_HOME" && pwd -P)/repos"
+"$cli" repo clone acme/app --json > "$work/clone.json"
+[[ "$(json_field "$work/clone.json" path)" == "$repos/acme/app" ]] || fail "acme/app is not in repos/acme/app"
+[[ "$(git -C "$repos/acme/app" remote get-url origin)" == https://github.com/acme/app.git ]] || fail "wrong origin"
+git -C "$repos/acme/app" log --oneline -1 | grep -q "canopy config" || fail "the clone has no commits"
+
+step "cloning it again registers the folder it made"
+"$cli" repo clone https://github.com/acme/app --json > "$work/again.json"
+[[ "$(json_field "$work/again.json" path)" == "$repos/acme/app" ]] || fail "the second clone went somewhere else"
+[[ "$("$cli" repo list | grep -c "repos/acme/app")" == 1 ]] || fail "acme/app is registered twice"
+
+step "two repos named app show their owners"
+"$cli" repo clone other/app >/dev/null
+"$cli" repo list | grep -q "^acme/app " || fail "acme/app is not named by its owner"
+"$cli" repo list | grep -q "^other/app " || fail "other/app is not named by its owner"
+
+step "other URLs clone with git, and --into takes a folder relative to the caller"
+(cd "$work" && "$cli" repo clone "file://$work/remotes/team/lib.git" --into ./lib-copy --json) > "$work/lib.json"
+[[ "$(json_field "$work/lib.json" path)" == "$(cd "$work" && pwd -P)/lib-copy" ]] || fail "--into was not used"
+
+step "a failed clone exits 1 and leaves nothing behind"
+if "$cli" repo clone acme/nope --json > "$work/nope.json" 2>/dev/null; then fail "expected failure"; fi
+grep -q '"clone_failed"' "$work/nope.json" || fail "missing clone_failed"
+[[ "$(ls -A "$repos/acme")" == app ]] || fail "the failed clone left $(ls -A "$repos/acme")"
+
+step "a folder holding something else is refused and left alone"
+mkdir -p "$repos/acme/taken"
+touch "$repos/acme/taken/notes.txt"
+if "$cli" repo clone acme/taken --json > "$work/taken.json" 2>/dev/null; then fail "expected failure"; fi
+grep -q '"folder_taken"' "$work/taken.json" || fail "missing folder_taken"
+[[ -f "$repos/acme/taken/notes.txt" ]] || fail "the folder's contents were touched"
+
+step "screenshot"
+"$cli" row select main --repo acme/app >/dev/null
+sleep 1
+swift scripts/window-shot.swift "$(app_pid)" "$shots/clone.png"
+echo "saved $shots/clone.png"
+
+step "repo rm unregisters a clone and leaves its folder"
+"$cli" repo rm acme/app >/dev/null
+[[ -d "$repos/acme/app/.git" ]] || fail "repo rm deleted the clone"
+
+step "clones are in the activity log"
+"$cli" log --json > "$work/clone-log.json"
+/usr/bin/python3 - "$work/clone-log.json" <<'EOF' || fail "canopy log is missing the clone"
+import json, sys
+events = json.load(open(sys.argv[1]))
+added = [e for e in events if e["type"] == "repo.added" and e["data"].get("clonedFrom") == "acme/app"]
+calls = [e for e in events if e["type"] == "cli.call" and e["data"]["method"] == "repo.clone"]
+if len(added) != 1 or added[0]["source"] != "cli":
+    sys.exit(f"repo.added for acme/app: {added}")
+if len(calls) < 5 or not any(c["data"].get("error") == "clone_failed" for c in calls):
+    sys.exit(f"repo.clone calls: {calls}")
+EOF
+"$cli" agent-guide | grep -q "canopy repo clone" || fail "agent-guide is missing repo clone"
+
 echo
 echo "e2e passed"
```

`scripts/ui-fixture.sh`:

```diff
@@ -6,8 +6,10 @@
 #   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
 #   scripts/ui-fixture.sh stop           quit it and delete its folder
 #
-# PR badges come from a stand-in gh, which the app finds first on its login PATH through a fixture ZDOTDIR.
-# Writing "logged-out" to $work/bin/gh-mode makes it answer like a gh with no login.
+# PR badges and the clone sheet's repo list come from a stand-in gh, which the app finds first on its login PATH through
+# a fixture ZDOTDIR. It clones acme/billing and acme/design-system from local bare repos in $work/remotes, and fails
+# like gh for any other repo. Writing "logged-out" to $work/bin/gh-mode makes it answer like a gh with no login, and
+# writing a number of seconds to $work/bin/clone-seconds makes clones show git's progress for that long.
 set -euo pipefail
 cd "$(dirname "$0")/.."
 app="$PWD/build/Canopy Dev.app"
@@ -42,7 +44,42 @@ mode = os.path.join(os.path.dirname(__file__), "gh-mode")
 if os.path.exists(mode) and open(mode).read().strip() == "logged-out":
     sys.stderr.write("gh: To get started with GitHub CLI, please run:  gh auth login\n")
     sys.exit(4)
+here = os.path.dirname(__file__)
+if sys.argv[1:3] == ["repo", "clone"]:
+    import subprocess, time
+    repo, folder = sys.argv[3], sys.argv[4]
+    repo = repo.removeprefix("https://github.com/").removesuffix(".git")
+    remote = os.path.join(here, "..", "remotes", repo + ".git")
+    if not os.path.isdir(remote):
+        sys.stderr.write(f"GraphQL: Could not resolve to a Repository with the name '{repo}'. (repository)\n")
+        sys.exit(1)
+    seconds_file = os.path.join(here, "clone-seconds")
+    seconds = float(open(seconds_file).read()) if os.path.exists(seconds_file) else 0
+    for step in range(51):
+        sys.stderr.write(f"Receiving objects: {step * 2:3d}% ({step * 37}/1850), {step * 0.4:.2f} MiB | 2.10 MiB/s\r")
+        sys.stderr.flush()
+        time.sleep(seconds / 50)
+    subprocess.run(["git", "clone", "-q", "file://" + os.path.abspath(remote), folder], check=True)
+    subprocess.run(["git", "-C", folder, "remote", "set-url", "origin", f"https://github.com/{repo}.git"], check=True)
+    sys.exit(0)
 query = next(a[6:] for a in sys.argv if a.startswith("query="))
+if "viewer" in query:
+    from datetime import datetime, timedelta, timezone
+    def pushed(hours):
+        return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
+    repos = [
+        ("acme/web-app", "Storefront and checkout", True, 2),
+        ("acme/api-server", "REST API and background jobs", True, 5),
+        ("acme/billing", "Invoices, plans, and payment webhooks", True, 26),
+        ("acme/mobile-app", "iOS and Android app", True, 75),
+        ("acme/design-system", "Shared UI components", False, 150),
+        ("acme/docs", "The public docs site", False, 500),
+        ("ne1nn/dotfiles", "zsh, git, and editor settings", False, 340),
+        ("ne1nn/advent-of-code", None, False, 1500),
+    ]
+    nodes = [{"nameWithOwner": n, "description": d, "isPrivate": p, "pushedAt": pushed(h)} for n, d, p, h in repos]
+    print(json.dumps({"data": {"viewer": {"repositories": {"nodes": nodes}}}}))
+    sys.exit(0)
 prs = {
     "feat/onboarding-flow": (142, "Onboarding in three steps", "OPEN", True),
     "fix/login-redirect": (139, "Keep the page after logging in", "MERGED", False),
@@ -69,6 +106,9 @@ for repo in web-app api-server docs; do
     git init -q -b main "$work/$repo"
     git -C "$work/$repo" -c user.email=ui@example.com -c user.name=ui commit -q --allow-empty -m init
 done
+for repo in billing design-system; do
+    git clone -q --bare "$work/web-app" "$work/remotes/acme/$repo.git"
+done
 
 # Either appearance, whatever the Mac is set to.
 if [[ "${1:-dark}" == light ]]; then args=(-NSRequiresAquaSystemAppearance YES); else args=(-AppleInterfaceStyle Dark); fi
@@ -90,6 +130,7 @@ git -C "$work/web-app" worktree add -q -b spike/new-parser "$work/elsewhere/new-
 # Remotes come after the rows, so creating the rows does not fetch. The stand-in gh answers for them.
 git -C "$work/web-app" remote add origin https://github.com/acme/web-app.git
 git -C "$work/api-server" remote add origin https://github.com/acme/api-server.git
+"$cli" pr feat/onboarding-flow --repo web-app --refresh >/dev/null
 "$cli" row select feat/checkout-redesign --repo web-app >/dev/null
 sleep 1
```

`scripts/window-shot.swift`:

```diff
@@ -1,8 +1,21 @@
-// Captures the main window of a process, even when it is behind other apps or not yet shown. Usage: swift scripts/window-shot.swift <pid> <out.png>
+// Captures the main window of a process, even when it is behind other apps or not yet shown.
+// Usage: swift scripts/window-shot.swift <pid> <out.png>
 import CoreGraphics
 import Foundation
 
 let pid = Int32(CommandLine.arguments[1])!
+// screencapture runs as part of the app hosting this terminal, which needs Screen Recording. Without it the capture fails
+// with only "could not create image from window".
+guard CGPreflightScreenCaptureAccess() else {
+    FileHandle.standardError.write(
+        Data(
+            """
+            Screen Recording is off for the app running this terminal. Turn it on in System Settings > Privacy & Security \
+            > Screen Recording. macOS then offers to quit and reopen that app, which closes its terminals.
+
+            """.utf8))
+    exit(1)
+}
 let output = CommandLine.arguments[2]
 let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
```

- [ ] **Take the UI shots**

Run `scripts/ui-fixture.sh dark`, clone with the dev CLI against its `CANOPY_HOME`, select the new repo's main row, and shoot the window with `swift scripts/window-shot.swift <pid> <out.png>`. Repeat with `light`, and stop the fixture with `scripts/ui-fixture.sh stop`.

- [ ] **Step 2: Run the checks**

Run: `make e2e`
Expected: PASS, and `make lint` and `swift build` print no warnings.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: cloning in the spec, with an e2e case and fixture support"
```

## After Review

An independent opus reviewer read `git diff main...feat/repo-clone` against the spec and this plan.
It found no critical issues. Everything below is fixed in one commit with tests, except where it says otherwise.

1. **Major: the failure reason came from the wrong line.**
   With real gh, a failing git is followed by gh's own `failed to run git: exit status 128`, and a failing remote ends with git's advice ("and the repository exists.").
   `ToolOutput.reason` now takes git's last `fatal:` or `error:` line, skips gh's line, and when git only says it could not read from the remote, takes the line above it, where ssh or the server says why.
   The tests use stderr captured from gh 2.101 and git 2.50.
2. **Minor: the sheet truncated git's percent**, so 58% showed as 57%.
   `CloneProgress` now keeps git's integer percent.
3. **Minor: cloning into an existing empty folder replaced it**, which left a shell sitting in it inside a deleted folder.
   The clone's entries now move into the folder with `RENAME_EXCL`, `.git` last, and move back if anything is in the way.
   A test checks the folder's inode is unchanged.
4. **Minor: a source through an SSH host alias never matched an existing clone.**
   The source's URL is now resolved through the SSH config before comparing, like the folder's origin.
5. **Minor: quitting could delete a hidden folder while a killed git was still writing to it.**
   Quitting now waits up to 2 seconds for killed clones to exit before deleting, through a new `SubprocessHandle.isRunning`.
   Not changed: the delete still runs on the main thread during quit, which only costs time when quitting mid-clone.
6. **Minor: sheet errors told the user to pass `--into`, which the sheet does not have, and showed backticks as text.**
   The sheet now words those errors itself, pointing at `canopy repo clone <source> --into <folder>` set as code, and renders gh's fix as Markdown.
   git's and gh's own words stay plain text, so a path or URL in them is never turned into formatting or a link.
7. **Minor: git's `transport::address` syntax got through**, where only git's default `protocol.allow` stood between a crafted source and a remote helper.
   `CloneSource` now refuses `::`.
8. **Minor: in logged-out mode, the UI fixture's sheet could fall back to a real `git clone` from GitHub.**
   The reviewer suggested an `insteadOf` rule, but that also rewrites what `git remote get-url` reports, which hid the fixture's PR badges and stopped `ui-fixture.sh` at its `canopy pr --refresh`.
   Both `ui-fixture.sh` and the e2e clone section now start the app with `GIT_ALLOW_PROTOCOL=file`, so any clone that falls back to plain git fails at once instead of reaching the network.

Test gaps the reviewer listed, all now covered:
a failing gh does not fall back to git, an origin that only matches after an `insteadOf` rule, `stopClones` kills the process, a CLI that disconnects does not stop its clone (decision 6), and cancelling a clone queued behind another leaves the first alone.

Nits, all fixed:
- A github.com page URL such as `…/tree/main` stands for its repo (decision 13).
- The sheet keeps one size, and the list gives way to the progress bar or an error.
  An empty field shows a hint in the destination line instead of a blank one.
- The field takes focus back after a failed clone.
- Repo lines read their description and push date to VoiceOver, and the title is a header.
- Clones queue apart from the repo's other git work (`KeyedQueue`), so re-cloning a registered repo never waits behind a `row new` fetch.
- This plan's tasks are filled in.
- `ui-fixture.sh stop` only kills its pid while that pid is still a `Canopy Dev.app` process.

The reviewer confirmed option injection is refused, `.` and `..` cannot escape the repos folder, the handle never touches a reused pid or fd, cancellation reaches the queued task, the control server never cancels a clone when the CLI goes away, and the e2e stand-in stays local.

### CI

The first CI run failed `aHandleStopsGitAndEverythingItStarted`: 16 seconds against a 10 second bound, because its clock started before a loaded runner had even started bash.
The two handle tests now time from the cancel, with a 30 second bound on a 60 second sleep, which still proves the kill.
`aCloneDoesNotWaitBehindTheRepositorysOtherGitWork` holds the row's fetch until it is released and checks the row was still being created when the clone returned, with no clock at all.
Pointing clones at the repo's git queue again makes it fail, as it should.
The progress test gives the watcher 3 seconds to see its line.

## UI checks

The release Canopy hosts the agent's terminal, so macOS treats it as the app posting events, and it has no Accessibility permission.
`scripts/ui.swift` could therefore not open the `+` menu or the sheet in the dev app, so the window shots cover the cloned repo in the sidebar, in dark and light, through the CLI.
The sheet's own views (the repo list and its lines, the gh notes, progress, and errors) were rendered offscreen from the committed source in every state, in dark and light, and checked by eye.
The `+` menu, File > Clone Repo…, and the sheet in the live app are hand checks in the PR.

