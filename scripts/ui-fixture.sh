#!/usr/bin/env bash
# Opens the dev build on a throwaway home that has something in every part of the window, for UI checks and shots: three
# repos, one of them folded, rows with open, draft, merged, and closed PRs, two groups, one folded, other worktrees,
# running programs, listening ports, a split tab, agents in every state, and the fixture plugin's section with its
# warning, rows with every kind of accessory, a missing item, and a worktree row linked to one of them, and the Tickets
# section with rows backed by a stand-in ticket-manager: a waiting ticket, a long conversation with every kind of
# message, and a closed ticket, with a fix row linked to one. Nothing outside the throwaway folder is touched, and
# nothing reaches ticket-manager or Discord. Links the window opens are written to $work/opened-urls instead of opening
# a browser.
#
#   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
#   scripts/ui-fixture.sh stop           quit it and delete its folder
#
# PR badges, the New Row sheet's PRs, and the clone sheet's repo list come from a stand-in gh, which the app finds first
# on its login PATH through a fixture ZDOTDIR. It clones acme/billing and acme/design-system from local bare repos in
# $work/remotes, and fails like gh for any other repo. Writing "logged-out" to $work/bin/gh-mode makes it answer like a
# gh with no login, and writing a number of seconds to $work/bin/clone-seconds makes clones show git's progress for that
# long. web-app and api-server have origins on GitHub, which the app's git reaches in $work/remotes through a URL
# rewrite: web-app's has open PRs with and without rows, one from a fork, and branches that are only on origin, only
# here, behind, ahead, and diverged.
#
# UI_FIXTURE_HOOKS_OFFER=1 gives it a Claude Code config folder of its own, so it offers to install its hooks.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
state="$PWD/build/ui-fixture.env"

if [[ "${1:-}" == stop ]]; then
    [[ -f "$state" ]] || exit 0
    # shellcheck source=/dev/null
    source "$state"
    # Only the dev build this script started: a pid can be reused once that app has quit.
    if [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == *"Canopy Dev.app/Contents/MacOS/Canopy" ]]; then
        # Disconnecting deletes this home's token from the Keychain.
        CANOPY_HOME="$work/home" "$cli" ticket disconnect --force >/dev/null 2>&1 || true
        kill "$pid" 2>/dev/null || true
    fi
    if [[ -n "${tm_pid:-}" && "$(ps -p "$tm_pid" -o command= 2>/dev/null)" == *ticket-manager-stand-in.py* ]]; then
        kill "$tm_pid" 2>/dev/null || true
    fi
    # Only a folder this script made: named by mktemp -t cnp, and holding the stand-in gh and the fixture ZDOTDIR.
    if [[ "$(basename "$work")" != cnp.* || ! -x "$work/bin/gh" || ! -d "$work/zdot" ]]; then
        echo "not deleting $work: it does not look like a fixture folder" >&2
        exit 1
    fi
    rm -rf "$work"
    rm -f "$state"
    exit 0
fi

[[ -x "$cli" ]] || { echo "build it first: make app" >&2; exit 1; }
# The socket path must stay under 104 bytes, so the home goes in a short temporary folder.
work=$(mktemp -d -t cnp)
export CANOPY_HOME="$work/home"
# The app offers to install Claude Code's hooks, and must only ever find the fixture's settings.
export CLAUDE_CONFIG_DIR="$work/claude"
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH CANOPY_PLUGIN CANOPY_ITEM
if [[ "${UI_FIXTURE_HOOKS_OFFER:-}" == 1 ]]; then mkdir -p "$CLAUDE_CONFIG_DIR"; fi

mkdir -p "$work/bin" "$work/zdot"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/python3
import json, os, re, sys
mode = os.path.join(os.path.dirname(__file__), "gh-mode")
if os.path.exists(mode) and open(mode).read().strip() == "logged-out":
    sys.stderr.write("gh: To get started with GitHub CLI, please run:  gh auth login\n")
    sys.exit(4)
here = os.path.dirname(__file__)
if sys.argv[1:3] == ["repo", "clone"]:
    import subprocess, time
    repo, folder = sys.argv[3], sys.argv[4]
    repo = repo.removeprefix("https://github.com/").removesuffix(".git")
    remote = os.path.join(here, "..", "remotes", repo + ".git")
    if not os.path.isdir(remote):
        sys.stderr.write(f"GraphQL: Could not resolve to a Repository with the name '{repo}'. (repository)\n")
        sys.exit(1)
    seconds_file = os.path.join(here, "clone-seconds")
    seconds = float(open(seconds_file).read()) if os.path.exists(seconds_file) else 0
    for step in range(51):
        sys.stderr.write(f"Receiving objects: {step * 2:3d}% ({step * 37}/1850), {step * 0.4:.2f} MiB | 2.10 MiB/s\r")
        sys.stderr.flush()
        time.sleep(seconds / 50)
    subprocess.run(["git", "clone", "-q", "file://" + os.path.abspath(remote), folder], check=True)
    subprocess.run(["git", "-C", folder, "remote", "set-url", "origin", f"https://github.com/{repo}.git"], check=True)
    sys.exit(0)
query = next(a[6:] for a in sys.argv if a.startswith("query="))
if "viewer" in query:
    from datetime import datetime, timedelta, timezone
    def pushed(hours):
        return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    repos = [
        ("acme/web-app", "Storefront and checkout", True, 2),
        ("acme/api-server", "REST API and background jobs", True, 5),
        ("acme/billing", "Invoices, plans, and payment webhooks", True, 26),
        ("acme/mobile-app", "iOS and Android app", True, 75),
        ("acme/design-system", "Shared UI components", False, 150),
        ("acme/docs", "The public docs site", False, 500),
        ("ne1nn/dotfiles", "zsh, git, and editor settings", False, 340),
        ("ne1nn/advent-of-code", None, False, 1500),
    ]
    nodes = [{"nameWithOwner": n, "description": d, "isPrivate": p, "pushedAt": pushed(h)} for n, d, p, h in repos]
    print(json.dumps({"data": {"viewer": {"repositories": {"nodes": nodes}}}}))
    sys.exit(0)
from datetime import datetime, timedelta, timezone
def ago(hours):
    return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
# number, title, state, draft, head branch, author, the fork it comes from, and hours since it was updated.
PRS = {"acme/web-app": [
    (145, "Split checkout into steps", "OPEN", False, "feat/checkout-redesign", "maya", None, 1),
    (147, "Filter search results by price", "OPEN", False, "feat/search-filters", "priya", None, 3),
    (142, "Onboarding in three steps", "OPEN", True, "feat/onboarding-flow", "sam", None, 5),
    (148, "Round cart totals to the cent", "OPEN", False, "fix/cart-rounding", "jordan", "jordan", 20),
    (150, "Refresh the README", "OPEN", True, "docs/readme-refresh", "alex", None, 50),
    (139, "Keep the page after logging in", "MERGED", False, "fix/login-redirect", "sam", None, 30),
    (131, "Try a new parser", "CLOSED", False, "spike/new-parser", "maya", None, 200),
]}
owner, name = re.search(r'repository\(owner: "([^"]*)", name: "([^"]*)"\)', query).groups()
prs = PRS.get(f"{owner}/{name}", [])
def node(pr):
    number, title, state, draft, head, author, fork, hours = pr
    return {"number": number, "title": title, "url": f"https://github.com/{owner}/{name}/pull/{number}",
            "state": state, "isDraft": draft, "updatedAt": ago(hours), "headRefName": head,
            "isCrossRepository": fork is not None, "author": {"login": author}}
def find(number):
    return next((pr for pr in prs if pr[0] == int(number)), None)
def unresolved(number):
    sys.stderr.write(f"gh: Could not resolve to a PullRequest with the number of {number}.\n")
    sys.exit(1)
if "maintainerCanModify" in query:
    import subprocess
    number = re.search(r"pullRequest\(number: (\d+)\)", query).group(1)
    pr = find(number)
    if pr is None:
        print(json.dumps({"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": None}}}))
        unresolved(number)
    bare = os.path.join(here, "..", "remotes", owner, name + ".git")
    oid = subprocess.run(["git", "--git-dir", bare, "rev-parse", f"refs/pull/{number}/head"],
                         capture_output=True, text=True).stdout.strip()
    fork = pr[6]
    head = dict(node(pr), headRefOid=oid, headRef={"name": pr[4]}, baseRefName="main", maintainerCanModify=True,
                headRepository={"name": name}, headRepositoryOwner={"login": fork or owner})
    print(json.dumps({"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": head}}}))
    sys.exit(0)
if "pullRequests(states:" in query:
    states = re.search(r"pullRequests\(states: \[([A-Z, ]*)\]", query).group(1).split(", ")
    nodes = sorted((node(pr) for pr in prs if pr[2] in states), key=lambda n: n["updatedAt"], reverse=True)
    print(json.dumps({"data": {"repository": {"pullRequests": {"nodes": nodes}}}}))
    sys.exit(0)
repo = {}
for key, branch in re.findall(r'(b\d+): pullRequests\(headRefName: "([^"]*)"', query):
    repo[key] = {"nodes": [node(pr) for pr in prs if pr[4] == branch and pr[6] is None]}
for key, number in re.findall(r"(b\d+): pullRequest\(number: (\d+)\)", query):
    if find(number) is None:
        unresolved(number)
    repo[key] = node(find(number))
print(json.dumps({"data": {"repository": repo}}))
GH
chmod +x "$work/bin/gh"
cat > "$work/zdot/.zshrc" <<ZSHRC
export PATH="$work/bin:\$PATH"
ZSHRC

# A time some hours or days ago, such as 3H or 2d, for commits.
ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }
for repo in web-app api-server docs; do
    git init -q -b main "$work/$repo"
    GIT_AUTHOR_DATE=$(ago 6d) GIT_COMMITTER_DATE=$(ago 6d) \
        git -C "$work/$repo" -c user.email=ui@example.com -c user.name=ui commit -q --allow-empty -m init
done
for repo in billing design-system; do
    git clone -q --bare "$work/web-app" "$work/remotes/acme/$repo.git"
done

# A stand-in ticket-manager with ticket-manager's own fixtures and tickets for UI checks, on this Mac alone. It stops
# after four hours if `stop` never runs.
python3 scripts/ticket-manager-stand-in.py seed --fixtures Tests/CanopyTicketsTests/Fixtures/canopy-api --out "$work/tm" --ui
(exec python3 scripts/ticket-manager-stand-in.py serve --data "$work/tm" --token ui-fixture-token \
    --port-file "$work/tm/port" --log "$work/tm/requests.log" --lifetime 14400 </dev/null >/dev/null 2>&1) &
tm_pid=$!
for _ in $(seq 1 100); do
    [[ -f "$work/tm/port" ]] && break
    sleep 0.1
done
tm_url="http://127.0.0.1:$(cat "$work/tm/port")"

# The fixture plugin is on, with a warning under its header and one item it pretends is gone.
mkdir -p "$CANOPY_HOME"
cat > "$CANOPY_HOME/config.json" <<'CONFIG'
{
  "plugins": {
    "fixture": {
      "warning": "These items are made up. Run `canopy plugin disable fixture` to hide them.",
      "missing": ["fx-3"]
    }
  }
}
CONFIG

# Either appearance, whatever the Mac is set to.
if [[ "${1:-dark}" == light ]]; then args=(-NSRequiresAquaSystemAppearance YES); else args=(-AppleInterfaceStyle Dark); fi
# git may only use local repos, so a clone that falls back to plain git fails instead of reaching the network.
# The URL rewrite sends the app's git for https://github.com/ to the bare repos in $work/remotes.
(ZDOTDIR="$work/zdot" SHELL=/bin/zsh GIT_ALLOW_PROTOCOL=file GIT_CONFIG_COUNT=1 CANOPY_FIXTURE_PLUGIN=1 \
    CANOPY_TRASH_FOLDER="$work/trash" CANOPY_OPENED_URLS="$work/opened-urls" \
    GIT_CONFIG_KEY_0="url.$work/remotes/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ \
    exec "$app/Contents/MacOS/Canopy" "${args[@]}" </dev/null >/dev/null 2>&1) &
# Written at once, so `stop` can clean up even if a later step fails. The subshell execs, so $! is the app.
printf 'pid=%s\nwork=%s\ntm_pid=%s\n' "$!" "$work" "$tm_pid" > "$state"
for _ in $(seq 1 100); do
    [[ -S "$CANOPY_HOME/canopy.sock" ]] && break
    sleep 0.1
done

for repo in web-app api-server docs; do "$cli" repo add "$work/$repo" >/dev/null; done
"$cli" row new feat/onboarding-flow --repo web-app >/dev/null
"$cli" row new fix/login-redirect --repo web-app >/dev/null
"$cli" row new feat/checkout-redesign --repo web-app >/dev/null
"$cli" row new chore/bump-deps --repo web-app >/dev/null
"$cli" row new feat/rate-limits --repo api-server >/dev/null
"$cli" group new Review --repo web-app >/dev/null
"$cli" group new Later --repo web-app >/dev/null
"$cli" row move feat/checkout-redesign --repo web-app --group Review >/dev/null
"$cli" row move feat/onboarding-flow --repo web-app --group Review >/dev/null
"$cli" row move chore/bump-deps --repo web-app --group Later >/dev/null
# Fixture rows, and a worktree row made from one's terminal, which links it to that item.
for item in 1 2 6 3; do "$cli" plugin new fixture "$item" >/dev/null; done
CANOPY_PLUGIN=fixture CANOPY_ITEM=fx-1 "$cli" row new fix/sign-in-loop --repo web-app >/dev/null
git -C "$work/web-app" worktree add -q -b hotfix/cart-total "$work/elsewhere/cart-total"
git -C "$work/web-app" worktree add -q -b spike/new-parser "$work/elsewhere/new-parser"
# Remotes come after the rows, so creating the rows does not fetch. Origins start as copies of the repos, rows and
# all, and the stand-in gh answers for them.
git clone -q --bare "$work/web-app" "$work/remotes/acme/web-app.git"
git clone -q --bare "$work/api-server" "$work/remotes/acme/api-server.git"
git clone -q --bare "$work/web-app" "$work/remotes/jordan/web-app.git"
git clone -q "$work/remotes/acme/web-app.git" "$work/seed" 2>/dev/null
seed() { git -C "$work/seed" -c user.email=ui@example.com -c user.name=ui "$@"; }
# Pushes a branch of commits made at the times given, such as 3H or 2d, to acme/web-app, or to another repo.
push_branch() { # branch, remote, times...
    local branch=$1 remote=$2 when
    shift 2
    seed switch -q -c "$branch" origin/main
    for when in "$@"; do
        GIT_AUTHOR_DATE=$(ago "$when") GIT_COMMITTER_DATE=$(ago "$when") seed commit -q --allow-empty -m "$branch"
    done
    seed push -q "$remote" "$branch"
}
push_branch feat/search-filters origin 9H 6H 4H
push_branch docs/readme-refresh origin 2d
push_branch chore/ci-cache origin 26H
push_branch refactor/cart-state origin 3d 30H
push_branch feat/dark-mode origin 4d
push_branch fix/cart-rounding "$work/remotes/jordan/web-app.git" 21H
# GitHub keeps every PR's head at refs/pull/<number>/head of the base repo.
for pr in 145:feat/checkout-redesign 147:feat/search-filters 142:feat/onboarding-flow 150:docs/readme-refresh \
    139:fix/login-redirect 131:spike/new-parser 148:fix/cart-rounding; do
    branch=${pr#*:}
    tip=$(seed rev-parse --verify -q "refs/heads/$branch" || seed rev-parse "refs/remotes/origin/$branch")
    seed push -q origin "$tip:refs/pull/${pr%%:*}/head"
done
git -C "$work/web-app" remote add origin https://github.com/acme/web-app.git
git -C "$work/api-server" remote add origin https://github.com/acme/api-server.git
for repo in web-app api-server; do
    git -C "$work/$repo" -c "url.$work/remotes/.insteadOf=https://github.com/" fetch -q origin
    git -C "$work/$repo" remote set-head origin main
done
# Local branches that are behind origin's, ahead, diverged, and only here, made without checking them out.
local_commit() { # parent, time, message
    GIT_AUTHOR_DATE=$(ago "$2") GIT_COMMITTER_DATE=$(ago "$2") \
        git -C "$work/web-app" -c user.email=ui@example.com -c user.name=ui commit-tree -p "$1" -m "$3" "$1^{tree}"
}
git -C "$work/web-app" branch feat/search-filters origin/feat/search-filters~2
git -C "$work/web-app" branch feat/dark-mode "$(local_commit origin/feat/dark-mode 2H "Dark mode toggle")"
git -C "$work/web-app" branch refactor/cart-state "$(local_commit origin/refactor/cart-state~1 7H "Cart state")"
git -C "$work/web-app" branch fix/typo-footer "$(local_commit main 45M "Footer typo")"
"$cli" pr feat/onboarding-flow --repo web-app --refresh >/dev/null
"$cli" pr feat/rate-limits --repo api-server --refresh >/dev/null || true
"$cli" row select feat/checkout-redesign --repo web-app >/dev/null
sleep 1

# A plain prompt keeps the machine's user and host names out of shots.
plain="PROMPT='%F{blue}%B%1~%b%f %# '; clear"
agent="$plain; "'printf "\n\033[36m●\033[0m Read \033[90msrc/checkout/\033[0mForm.tsx\n\033[36m●\033[0m Update \033[90msrc/checkout/\033[0mForm.tsx  \033[32m+48\033[0m \033[31m-21\033[0m\n\033[36m●\033[0m Bash \033[90mbun test checkout\033[0m\n  \033[32m✓\033[0m 18 passed\n\nThe form now has three steps.\n"; sleep 600'
row=(--repo web-app --row feat/checkout-redesign)
first=$("$cli" term list --all --json | /usr/bin/python3 -c \
    'import json, sys; print([t["pane"] for t in json.load(sys.stdin) if t["row"] == "feat/checkout-redesign"][0])')
"$cli" term send "$first" "$agent" --enter >/dev/null
"$cli" term new "${row[@]}" --run "$plain; python3 -m http.server 5173" >/dev/null
"$cli" term new "${row[@]}" --run "$plain; git status -sb" >/dev/null
"$cli" term new "${row[@]}" --tab agent --run "$plain; sleep 600" >/dev/null
"$cli" term new "${row[@]}" --tab "Terminal 2" --run "$plain" >/dev/null
"$cli" term new --repo web-app --row feat/onboarding-flow --run "$plain; sleep 600" >/dev/null
"$cli" term new --repo api-server --row feat/rate-limits --run "$plain; python3 -m http.server 8080" >/dev/null
"$cli" term new --repo web-app --row fix/login-redirect --run "$plain" >/dev/null
"$cli" term new --repo web-app --row chore/bump-deps --run "$plain" >/dev/null
"$cli" row select feat/checkout-redesign --repo web-app >/dev/null

fixture_row() {
    "$cli" row list --json | /usr/bin/python3 -c \
        'import json, sys; print([r["path"] for r in json.load(sys.stdin) if r.get("item") == sys.argv[1]][0])' "$1"
}
"$cli" term new --row "$(fixture_row fx-1)" --run "$plain; cat item.md" >/dev/null
"$cli" term new --row "$(fixture_row fx-1)" --run "$plain; sleep 600" >/dev/null
"$cli" term new --row "$(fixture_row fx-2)" --run "$plain; sleep 600" >/dev/null

# Tickets, connected to the stand-in, with rows for a waiting ticket, a long conversation, and a closed ticket, their
# terminals, and a fix row linked to the first.
printf 'ui-fixture-token' | "$cli" ticket connect "$tm_url" --web 'https://tickets.example.com/tickets/{id}' >/dev/null
for ticket in 853 855 851; do "$cli" ticket new "$ticket" --run "$plain" >/dev/null; done
"$cli" row new fix/shadowban-check --repo web-app --ticket 853 >/dev/null
"$cli" term new --row "$(fixture_row 0000000000000000000010011tickets)" --run "$plain; cat ticket.md | head -5" >/dev/null
"$cli" row select feat/checkout-redesign --repo web-app >/dev/null

# Agents in every state, reported the way agents without Claude Code's hooks report them.
pane_in() {
    "$cli" term list --all --json | /usr/bin/python3 -c \
        'import json, sys; print([t["pane"] for t in json.load(sys.stdin) if t["row"] == sys.argv[1] and t["tab"] == sys.argv[2]][0])' \
        "$1" "$2"
}
"$cli" term state "$first" working >/dev/null
"$cli" term state "$(pane_in feat/checkout-redesign agent)" done >/dev/null
"$cli" term state "$(pane_in feat/onboarding-flow Terminal)" working >/dev/null
"$cli" term state "$(pane_in fix/login-redirect Terminal)" waiting >/dev/null
"$cli" term state "$(pane_in feat/rate-limits Terminal)" working >/dev/null
"$cli" term state "$(pane_in beta Terminal)" waiting >/dev/null
# The folded Later group shows its done dot on the group's header, and the folded api-server repo its working dot,
# while the ports panel still lists feat/rate-limits' port.
"$cli" term state "$(pane_in chore/bump-deps Terminal)" done >/dev/null
"$cli" group collapse Later --repo web-app >/dev/null
"$cli" repo collapse api-server >/dev/null

# shellcheck source=/dev/null
source "$state"
echo "pid $pid, CANOPY_HOME=$CANOPY_HOME"
