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
   The CLI turns `./x` and `../x` into absolute paths first, as it does for `repo add`.
2. The destination is `--into`, or `CANOPY_HOME/repos/<owner>/<name>`.
   For a URL that is not on GitHub, the owner is the folder above the repo in the URL's path, so `file:///srv/git/acme/app.git` goes to `repos/acme/app`.
   An owner or name of `.` or `..` is refused, so no source can reach outside the repos folder.
3. Clones of one destination run one at a time, so a second clone of the same repo waits and then finds the first one's folder.
4. The destination is checked:
   - missing, or an empty folder: clone.
   - the top of a git checkout whose `origin` is the same repo: register it and stop.
     GitHub repos match by owner and name in any case and over any protocol, following SSH host aliases.
     Other URLs match once `.git` and trailing slashes are dropped, and local paths match by their resolved path.
   - anything else: `folder_taken`, naming what the folder holds.
5. The clone goes into a hidden sibling, `.<name>.canopy-clone-<random>`, and is renamed onto the destination when it is whole.
   `rename(2)` replaces an empty folder and refuses a full one, so a folder filled meanwhile is checked again as in step 4.
6. Which command runs:
   - a GitHub repo with gh found: `gh repo clone <owner/repo or the URL as given> <folder> -- --progress`.
   - gh missing or logged out: a URL falls back to `git clone --progress <url> <folder>`, and `owner/repo` fails with `gh_unavailable` and the fix.
   - any other URL: `git clone --progress`, since gh only clones from GitHub.
7. Progress comes from the tail of the clone's stderr, read every 200 ms while it runs: the phase git names, such as "Receiving objects", and its percent.
8. On failure or cancel, the hidden folder and any parent folders the clone created are deleted.
   Quitting the app kills clones still running and deletes their hidden folders.
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

The tasks below are filled in from the commits that implement them.
