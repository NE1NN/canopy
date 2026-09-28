# Canopy rows from a PR or an existing branch

Date: 2026-09-28
Status: approved 2026-09-28, from the spike's recommendation and its decisions.
PR A merged as #17, and PR B builds the sheet and the list commands.

## Summary

A row can start from an open pull request or from a branch that already exists on GitHub, not only from a new branch.
`canopy row new --pr 123` checks out a PR's branch, including a PR from a fork, and `canopy row new feat/x` says which branch it used.
The New Row sheet becomes one search list of open PRs and branches.
Canopy runs the git steps itself, with the same naming and tracking rules as `gh pr checkout`.
Every action in the sheet has one CLI command an agent can use without the window.

## Goals

1. Start a row from a PR by number, `#number`, or URL, for PRs from the repo itself and from forks.
2. Pick up a branch someone else pushed, and know it was picked up rather than created.
3. Never lose local commits while bringing a branch up to date.
4. A fork PR's row shows its PR badge like any other row.
5. Find PRs and branches from the sheet by typing, and from the CLI with two list commands.

## Non-goals

- Issues as a starting point.
- Git hosts other than GitHub.
- Adding a named remote per fork.
- Resetting a local branch that has diverged from origin.
- Adopting another tool's worktree without being asked.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Who runs git for a PR | Canopy, with gh's naming and tracking rules, rather than `gh pr checkout --worktree` | `--worktree` needs gh 2.98.0 or later, and the sync behavior would be whatever gh decides. Tests would need a working gh, and gh's errors would have to be translated into Canopy's. |
| A local branch that is only behind origin | Fast-forward it before checking it out | The user asked for the branch from GitHub, and a fast-forward loses nothing. |
| A fork PR's local branch name | The head's name, or `<owner>/<head>` when that name is origin's default branch or an unrelated local branch | This is gh's rule. It keeps `git push` working with the default `push.default=simple`, which always prefixing the owner would break. |
| A branch that already has a row | `row new` fails and names the row, and the sheet selects that row | `--run` then never types into a row the agent did not create. |
| A branch in another tool's worktree | A hint to adopt it, not an automatic adopt | Adopting changes what the sidebar shows, so it stays the user's choice. |
| A name that matches nothing | `row new <branch>` still creates a new branch, and `--existing` opts out | Current scripts keep working. |
| A PR's badge when its branch name cannot find it | The PR number is saved for the local branch in `state.json` | A binding on the branch follows `git switch` inside the row. A same-repo PR checked out under its own name keeps the name lookup, which also finds a later PR from the same branch. |
| How a fork is reached | origin's URL with the fork's owner and name, stored on the branch, not as a named remote | The fork is reached the way origin is: the same protocol, SSH host alias, and URL rewrites. gh also stores the URL rather than adding a remote. |
| Fetching for `row new <branch>` | `git fetch --prune origin` | Without pruning, a branch deleted on GitHub still looks like it is on origin. |
| Worktrees whose folder was deleted | `git worktree remove` on the one that holds the requested branch | That is the case where git refuses the add. Other missing rows stay until the user prunes them. |
| What `row new` reports | `source`, plus separate lists of notes and warnings | Warnings say something may need fixing. Notes say what Canopy did, such as a fast-forward. |
| Which URL names origin's GitHub repo | `git remote get-url origin`, then origin's configured URL when the first is not on GitHub | A mirror set up with `insteadOf` still has PRs on GitHub. Tests use the same rewrite to fetch from a local repo while origin reads as GitHub. |

## Starting from a branch

`canopy row new <branch> [--from <ref>] [--existing]` keeps its rules and reports what it did.

1. Canopy runs `git fetch --prune origin`, unless a fetch that finished after this request was made already covers it.
2. It picks the branch:
   - **local**: a local branch has that name, in any case.
   - **origin**: `origin/<branch>` exists, and a local branch tracking it is created.
   - **new**: nothing matches, and a branch is created from `--from`, defaulting to origin's default branch.
     With `--existing`, this fails with `branch_not_found` instead.
3. It runs `git worktree add`, then setup, as before.

The result gains `source`, with the value `local`, `origin`, or `new`, and `base`, the start point of a new branch.
The printed line says which happened:

```
Checked out feat/x in ~/.canopy/worktrees/web-app/feat-x.
Checked out feat/x, tracking origin/feat/x, in ~/.canopy/worktrees/web-app/feat-x.
Created new branch feat/x from origin/main in ~/.canopy/worktrees/web-app/feat-x.
```

Before this, a mistyped name quietly made a new branch from main, and the output looked the same as a checkout.
Agents that mean to pick up someone else's work pass `--existing`.
`--from` only applies to new branches, so it cannot be combined with `--existing`.

### Edge cases

| Case | Canopy |
|---|---|
| The local branch is only behind `origin/<branch>` | Checks it out, then fast-forwards it with `git merge --ff-only` in the row, as `gh pr checkout` does, and notes how many commits it moved. Moving it in its own worktree means git has already made sure no other worktree holds it, such as one in the middle of a rebase. |
| The local branch is only ahead | Checks it out as it is and notes the unpushed commits. |
| The local branch has diverged | Checks it out as it is and warns with both counts and the two ways to fix it: `git rebase origin/<branch>` to keep the local commits on top, or `git reset --hard origin/<branch>` to drop them. Canopy never resets on its own. |
| The branch exists locally but not on origin | Checks it out as it is. If its upstream is set but gone from origin, warns that it was probably merged and deleted. If the fetch failed, keeps the warning that the row starts from local refs. |
| The branch already has a Canopy or adopted row | Fails with `branch_checked_out`, naming the row's path and `canopy row select`. |
| The branch is checked out in the main checkout | Fails with `branch_checked_out`, naming the main checkout. |
| The branch is checked out in another tool's worktree | Fails with `branch_checked_out`, naming the path and `canopy row adopt <path>`. |
| The branch is held by a worktree whose folder was deleted | Runs `git worktree remove` on that worktree, then creates the row. Git would otherwise refuse with "already used by worktree". |
| The name is typed in the wrong case | Uses the branch's own spelling and notes it. On a case-insensitive file system `Feat` and `feat` share one ref file, so checking out `Feat` would give one ref two names, and creating `Feat` next to a packed `feat` would hide it. |

Comparisons are with `origin/<branch>` by name, not with a configured upstream.
A branch created with `git checkout -b feat/x origin/main` tracks `origin/main`, and fast-forwarding it there would be wrong.

## Starting from a PR

`canopy row new --pr <n | #n | PR URL> [--branch <local name>] [--group <name>] [--run <cmd>] [--select] [--no-setup]`

- `--pr` cannot be combined with a branch argument, `--from`, or `--existing`.
  `--branch` names the local branch, and is only for `--pr`.
- A URL must be a pull request of origin's GitHub repo, compared without regard to case.
- One `gh api graphql` call looks the PR up: its number, title, url, state, draft flag, head branch and commit, whether the head branch still exists, base branch, whether it is from a fork, the fork's owner and name, whether maintainers can edit it, and the repo's default branch.
- Closed and merged PRs are allowed, with a warning that the PR is not open.
- If gh is missing or not logged in, `row new` fails with `gh_unavailable` and the same fix the sidebar shows, such as `gh auth login`.
  A PR that does not exist fails with `pr_not_found`.

### A PR from the repo itself

1. `git fetch --quiet --no-tags origin +refs/heads/<head>:refs/remotes/origin/<head>`.
2. The local branch is `<head>`, or `--branch`.
   From there the branch rules above apply: a local branch is fast-forwarded or checked out as it is, and otherwise a local branch tracking `origin/<head>` is created.
3. With `--branch`, an existing local branch must track this PR's head, or `row new` fails with `branch_exists`.
   A new one tracks `origin/<head>`, and a warning says that `git push` needs `git push origin HEAD:<head>` because the names differ.

If the head branch is gone from origin, which is common after a merge, Canopy fetches `refs/pull/<n>/head` as it does for a fork.
The new branch tracks `refs/pull/<n>/head` on origin, and a warning says the branch is gone from origin, so `git pull` works and `git push` does not.

### A PR from a fork

1. `git fetch --quiet --no-tags origin +refs/pull/<n>/head:refs/canopy/pr/<n>`.
2. The local branch is `<head>`.
   It is `<owner>/<head>` instead when `<head>` is origin's default branch or an unrelated local branch has that name, and `pr/<n>` when GitHub no longer reports the fork's owner.
   A head that is not a usable branch name, such as one starting with `-`, is always `pr/<n>`.
   `--branch` overrides both.
3. A local branch whose upstream is this PR is reused, with the fast-forward rule.
   Its upstream is this PR when it tracks `refs/pull/<n>/head` on origin, or `refs/heads/<head>` on the fork.
   A `--branch` naming any other existing branch fails with `branch_exists`.
4. Otherwise Canopy runs `git branch --no-track <local> refs/canopy/pr/<n>` and sets its tracking by hand, the way `gh pr checkout` does, since `--track` needs a fetch refspec that a single-branch clone lacks:
   - If maintainers can edit the PR, `branch.<local>.remote` and `branch.<local>.pushRemote` are the fork's URL, and `branch.<local>.merge` is `refs/heads/<head>`.
   - Otherwise `remote` is `origin` and `merge` is `refs/pull/<n>/head`.
5. `git worktree add <path> <local>`, then the temporary ref is deleted.
   If the add fails, the branch Canopy created is deleted too.

The fork's URL is origin's URL with the fork's owner and name in place of origin's, so `git@github.com:acme/app.git` gives `git@github.com:someone/app.git`.
Both ways `git pull` works.
`git push` works only when maintainers can edit the PR and the local name is `<head>`.
Otherwise a warning says why and how to push.

### Result

`source` is `local` when an existing branch was reused and `origin` otherwise, since the PR's commits come from origin.
The result also has `pr`, the PR as the badge shows it.

```
Checked out PR #7 as someone/feat-x in ~/.canopy/worktrees/web-app/someone-feat-x.
Split checkout into steps: https://github.com/acme/web-app/pull/7
```

### Keeping the PR's badge

The badge query finds a row's PR by its branch name and skips PRs whose head is in another repo.
That finds nothing for a fork PR, or for a PR checked out under another name.
So when either is true, the repo's entry in `state.json` saves the PR for the local branch:

```json
"prBindings": {"someone/feat-x": {"number": 7, "repo": "acme/web-app"}}
```

For a bound branch, the badge query asks for `pullRequest(number: 7)` in the same GraphQL call.
The binding is used only while origin still points at the repo it names, and it is dropped when Canopy deletes the branch or creates a new branch with that name.
GitHub fails the whole query over one PR number it cannot find, so a binding to such a PR is dropped too, and the query runs again.
`prBindings` decodes with decodeIfPresent, so older files still load.

## Listing PRs and branches

These are read-only and back the sheet's lists.

- `canopy pr list [--query <text>] [--closed] [--json]` lists PRs with their state, number, title, author, head branch, a fork flag, the time of their last update, and the row that has each one.
  It shows the 100 most recently updated open PRs, or PRs in any state with `--closed`, from one `gh api graphql` call.
- `canopy pr show [row]` is today's `canopy pr [row]`, which stays its default subcommand.
- `canopy branch list [--query <text>] [--no-fetch] [--json]` lists local and origin branches.
  Each shows where it exists (local, origin, or both), how far it is ahead of or behind origin, its last commit date, and the row or worktree that has it checked out.
  It runs `git fetch --prune origin` first in the repo's git queue, with the same freshness guard as `row new`, unless `--no-fetch` asks for what the repo already has.
  A failed fetch lists local refs and warns on stderr.
- `--query` keeps the items holding each of its words, ignoring case: in a PR's number, title, head branch, or author, and in a branch's name.
  A PR number, `#number`, or PR URL looks that one PR up in any state instead, which is how the sheet finds a closed PR.
  A branch named exactly what was typed, in any case, comes first.
- `row new` with no argument stays an error.
  One command that lists sometimes and creates other times is harder for agents to use correctly.

In `--json`, each PR carries `number`, `title`, `url`, `state`, `author`, `headBranch`, `fork`, `updatedAt`, and `row`, and each branch carries `name`, `where`, `ahead`, `behind`, `committedAt`, and `row`.
`row` is `{path, branch, class}`, or null, and `class` is `external` for another tool's worktree.
A PR's row is the row on a branch bound to it, or for a PR from the repo itself, the row on its head branch unless that branch is bound to another PR, as the badges find it.
A worktree whose folder was deleted holds nothing, since `row new` takes its branch back.

## The New Row sheet

- It opens from the same places as today: the `+` next to a repo, and a group's `+`, which picks that group.
- One focused field, with the placeholder "Branch, PR number, or new branch name".
  The Start from field moves into the "New branch" line, since it only matters there.
- One list with two sections.
  Tabs are not worth it: they make the Tab key switch between them.
  - **Pull requests**: open PRs, most recently updated first.
    Each shows the sidebar's PR glyph in its state color, then `#123` (`Text(verbatim:)`), then the title.
    A second line shows `head · author · 2h ago`, with tags for `draft` and `fork`, or "In row".
    Typing `#123`, a bare number, or a PR URL for this repo looks that PR up directly, even when it is closed.
  - **Branches**: origin and local branches together, newest commit first.
    Each shows its name and commit age, with a tag saying `origin`, `local`, `local, 3 behind`, or `local ≠ origin`, plus "In row" or "Other worktree" where they apply.
  - **Last line**: "New branch ‘<typed text>’ from <base>", shown when the text is not an exact match.
- The list comes from local refs at once.
  A background `git fetch --prune origin` then refreshes it, using the fetch freshness guard so typing does not fetch again.
  PRs come from gh, and while gh is unavailable that section shows the sidebar's warning.
- Arrows move, Return runs the selected item's action, and Esc cancels.
  A click selects an item and a double click runs it.
  Nothing is selected until something is typed.
  Then the best match is: the PR a number names, a branch named exactly what was typed in any case, or else the first item, and it follows the answers as they arrive.
  An item picked with the arrows, a click, or the start point field stays selected while it is listed.
  A selected item that already has a row shows "Open Row" in place of Create Row, and one in another tool's worktree offers Adopt.
  Opening or adopting leaves the row where it is, so the Group picker is off for them.
- A PR number not among the open PRs is looked up a quarter second after typing stops.
  `12` and `#12` share one lookup, and a lookup that failed is tried again when the text asks for it again.
  A lookup that has started finishes and is kept, so an older answer never stands in for newer text.
- The "New branch" line needs a valid branch name that no local or origin branch has in any case.
  A PR number, or any text starting with `#`, means a PR, so the line never offers a branch named like a PR while that PR is still on its way.
- A branch that got a row after the list was made opens that row when picked, as `branch_checked_out` names it.

Each action in the sheet maps to exactly one command:

| In the sheet | CLI |
|---|---|
| pick a PR | `canopy row new --pr 123` |
| pick a branch | `canopy row new feat/x --existing` |
| the "New branch" line | `canopy row new feat/x --from <base>` |
| an item that already has a row | `canopy row select feat/x` |
| adopt an item in another tool's worktree | `canopy row adopt <path>` |
| the two lists | `canopy pr list --json`, `canopy branch list --json` |

The primary button's help shows the command for the selected item, with `--repo`.

## Control API

`row.new` takes either a branch or a PR:

```json
{"v": 1, "id": "1", "method": "row.new", "params": {"branch": "feat/x", "existing": true}}
{"v": 1, "id": "2", "method": "row.new", "params": {"pr": "#7", "branch": "mine", "run": "claude"}}
```

- `pr` is a number or a string: `7`, `"7"`, `"#7"`, or a PR URL.
- With `pr`, `branch` is the local name.
  Without it, `branch` is required.
- A combination the CLI refuses fails with `bad_params`.

The result:

```json
{
  "row": {"repoPath": "...", "path": "...", "branch": "someone/feat-x", "class": "canopy"},
  "source": "origin",
  "pr": {"number": 7, "title": "Split checkout into steps", "url": "...", "state": "open", "updatedAt": "..."},
  "notes": [],
  "warnings": ["Maintainers cannot push to someone's fork, so git push will fail. ..."],
  "setup": {"status": "succeeded", "exitCode": 0},
  "pane": "p12"
}
```

`base` is present only for a new branch, and `pr` only with `--pr`.

`pr.list` takes `query` and `closed` and answers with the PRs, and `branch.list` takes `query` and `fetch` (default true) and answers with `{branches, defaultBase, warnings}`.
Both resolve the repo like `row.new`, and neither is written to the activity log.

New error codes:

| Code | When |
|---|---|
| `branch_not_found` | `--existing` and the name is neither a local branch nor on origin |
| `branch_exists` | `--branch` names a local branch that is not this PR's, or both of a fork PR's names are taken |
| `invalid_pr` | `--pr` is not a number, `#number`, or a PR URL of origin's repo |
| `pr_not_found` | GitHub has no PR with that number in origin's repo |

`branch_checked_out` keeps its code and now names where the branch is checked out.
A PR's fetch that fails ends with `git_failed`, and gh failures with the existing `not_github`, `gh_unavailable`, and `gh_failed`.

## Testing

- Git tests use a local bare repo as origin, with `refs/pull/<n>/head` pushed into it, and a second bare repo as the fork.
  Origin's URL is `https://github.com/<owner>/<name>.git`, and `GIT_CONFIG_COUNT` rewrites `https://github.com/` to the folder of bare repos, so nothing reaches the network.
- A stand-in gh answers GraphQL queries from a table, like the one `scripts/ui-fixture.sh` uses.
- `scripts/e2e.sh` covers `--pr` for a same-repo and a fork PR, `--existing`, and `source`, with the app launched so it finds the stand-in gh and the URL rewrite.

## Delivery

- **PR A**: CanopyCore and the CLI.
  `--pr`, `--existing`, `source`, the edge cases, forks, the PR binding and its badges, and the prune.
  The only UI change is badges on fork PR rows.
- **PR B**: the New Row sheet and the two list commands, with UI checks through `scripts/ui-fixture.sh`.
  PR A leaves the core ready for it: PR references parse in CanopyCore, a PR's details come from `GitHubCLI`, and the sheet's actions are the same `Workspace` calls the CLI makes.
