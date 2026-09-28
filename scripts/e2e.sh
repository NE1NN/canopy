#!/usr/bin/env bash
# Drives a dev build through the canopy CLI against a throwaway CANOPY_HOME.
# Leaves a screenshot in build/e2e/ for a visual check.
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
shots="$PWD/build/e2e"
work=$(mktemp -d -t canopy-e2e)
export CANOPY_HOME="$work/home"
mkdir -p "$shots"

app_pid() {
    "$cli" status --json 2>/dev/null | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("pid", ""))' || true
}

cleanup() {
    local pid
    pid=$(app_pid)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "fixture repo with an origin"
git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/demo" 2>/dev/null
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
git -C "$work/demo" push -q origin main
git -C "$work/demo" remote set-head origin main

count_apps() { { pgrep -f "Canopy Dev.app/Contents/MacOS/Canopy" || true; } | wc -l; }

step "two CLI calls at once launch exactly one app"
running_before=$(count_apps)
"$cli" repo list >/dev/null &
"$cli" repo list >/dev/null &
wait
sleep 2
running_after=$(count_apps)
(( running_after - running_before == 1 )) || fail "expected 1 new app, got $((running_after - running_before))"

step "CLI registers the repo"
"$cli" repo add "$work/demo" --json
[[ -n "$(app_pid)" ]] || fail "app did not start"

step "relative paths resolve against the caller's folder"
(cd "$work/demo" && "$cli" repo add . --json) | grep -q '"name" : "demo"' || fail "repo add . did not resolve"

step "canopy row new creates a branch and worktree"
"$cli" row new feat/e2e --repo demo --select --json
[[ -d "$CANOPY_HOME/worktrees/demo/feat-e2e" ]] || fail "worktree folder missing"

step "a worktree made with plain git shows up"
git -C "$work/demo" worktree add -q -b feat/plain "$CANOPY_HOME/worktrees/demo/feat-plain"
for _ in $(seq 1 30); do
    "$cli" row list --repo demo | grep -q feat/plain && break
    sleep 0.1
done
"$cli" row list --repo demo | grep -q feat/plain || fail "plain git worktree did not appear"

step "running inside a row resolves the repo from the folder"
(cd "$CANOPY_HOME/worktrees/demo/feat-plain" && "$cli" row new feat/from-cwd --json) >/dev/null

step "listing"
"$cli" row list

step "screenshot"
sleep 1
swift scripts/window-shot.swift "$(app_pid)" "$shots/rows.png"
echo "saved $shots/rows.png"

step "canopy row rm removes the worktree and branch"
"$cli" row rm feat/e2e --repo demo --delete-branch
[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-e2e" ]] || fail "worktree folder still exists"
if git -C "$work/demo" show-ref --verify --quiet refs/heads/feat/e2e; then fail "branch still exists"; fi

step "setup runs with the row's variables, then --run types a command into a new terminal"
mkdir -p "$work/demo/.canopy"
cat > "$work/demo/.canopy/config.json" <<'EOF'
{
  "setup": [
    "printf '%s\\n' \"$CANOPY_ROOT_PATH\" \"$CANOPY_REPO\" \"$CANOPY_ROW\" \"$TERM_PROGRAM\" > \"$CANOPY_ROOT_PATH/../setup-$(basename \"$CANOPY_ROW_PATH\").env\""
  ],
  "teardown": ["echo \"$CANOPY_ROW\" >> \"$CANOPY_ROOT_PATH/../teardown.log\""]
}
EOF
git -C "$work/demo" add .canopy
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q -m "canopy config"
git -C "$work/demo" push -q origin main
"$cli" row new feat/setup --repo demo --select --run 'echo "$CANOPY_PANE" > "$CANOPY_ROOT_PATH/../ran"' --json \
    > "$work/setup.json"
grep -q '"status" : "succeeded"' "$work/setup.json" || fail "setup did not succeed"
pane=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pane"])' "$work/setup.json")
env_file="$work/setup-feat-setup.env"
[[ "$(sed -n 1p "$env_file")" == "$(cd "$work/demo" && pwd -P)" ]] || fail "CANOPY_ROOT_PATH is wrong"
[[ "$(sed -n 2,4p "$env_file" | tr '\n' ' ')" == "demo feat/setup Canopy " ]] || fail "setup variables are wrong"
for _ in $(seq 1 100); do
    [[ "$(cat "$work/ran" 2>/dev/null)" == "$pane" ]] && break
    sleep 0.1
done
[[ "$(cat "$work/ran" 2>/dev/null)" == "$pane" ]] || fail "--run did not reach pane $pane"
sleep 1
swift scripts/window-shot.swift "$(app_pid)" "$shots/terminal.png"
echo "saved $shots/terminal.png"

step "--no-setup skips setup"
"$cli" row new feat/no-setup --repo demo --no-setup --json | grep -q '"status" : "skipped"' || fail "setup not skipped"
[[ ! -e "$work/setup-feat-no-setup.env" ]] || fail "setup ran anyway"

step "failed setup keeps the row, skips --run, and exits 1"
git -C "$work/demo" switch -q -c broken-config
printf '{"setup": ["exit 5"], "teardown": ["exit 6"]}\n' > "$work/demo/.canopy/config.json"
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q -am "broken config"
git -C "$work/demo" switch -q main
if "$cli" row new feat/broken --repo demo --from broken-config --run 'touch "$CANOPY_ROOT_PATH/../never"' --json \
    > "$work/broken.json" 2>/dev/null; then
    fail "expected failure"
fi
grep -q '"exitCode" : 5' "$work/broken.json" || fail "setup exit code missing"
[[ -d "$CANOPY_HOME/worktrees/demo/feat-broken" ]] || fail "row was not kept"
sleep 1
[[ ! -e "$work/never" ]] || fail "--run ran after failed setup"

step "failed teardown keeps the row until --force"
if "$cli" row rm feat/broken --repo demo --json > "$work/teardown.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"teardown_failed"' "$work/teardown.json" || fail "missing teardown_failed"
[[ -d "$CANOPY_HOME/worktrees/demo/feat-broken" ]] || fail "row removed despite failed teardown"
"$cli" row rm feat/broken --repo demo --force >/dev/null
[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-broken" ]] || fail "--force did not remove the row"

step "teardown runs before the row goes"
"$cli" row rm feat/setup --repo demo >/dev/null
grep -qx feat/setup "$work/teardown.log" || fail "teardown did not run"
[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-setup" ]] || fail "row still exists"

step "an agent can remove the row it runs in"
"$cli" row new feat/self --repo demo --no-setup --run "'$cli' row rm" >/dev/null
for _ in $(seq 1 150); do
    [[ -d "$CANOPY_HOME/worktrees/demo/feat-self" ]] || break
    sleep 0.1
done
[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-self" ]] || fail "the row's own agent could not remove it"
grep -qx feat/self "$work/teardown.log" || fail "teardown did not run for the self-removed row"

step "canopy term opens, types into, reads, lists, and closes terminals"
"$cli" row new feat/term --repo demo --no-setup >/dev/null
pane=$("$cli" term new --repo demo --row feat/term --run 'echo from-term' --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
wait_for_text() {
    for _ in $(seq 1 100); do
        "$cli" term read "$pane" | grep -q "$1" && return 0
        sleep 0.1
    done
    return 1
}
wait_for_text from-term || fail "term read did not show the --run output"
"$cli" term send "$pane" 'echo sent-text' --enter >/dev/null
wait_for_text sent-text || fail "term send did not reach the terminal"
"$cli" term list --repo demo --row feat/term --json | grep -q "\"$pane\"" || fail "term list is missing $pane"
"$cli" term close "$pane" >/dev/null
if "$cli" term list --all --json | grep -q "\"$pane\""; then fail "closed terminal is still listed"; fi
"$cli" agent-guide | grep -q "canopy term read" || fail "agent-guide is missing term read"

step "canopy pr says when a repo's origin is not on GitHub"
if "$cli" pr feat/term --repo demo --json > "$work/pr-local.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"not_github"' "$work/pr-local.json" || fail "missing not_github"
"$cli" agent-guide | grep -q "canopy pr" || fail "agent-guide is missing canopy pr"

step "canopy pr finds a real PR through gh"
# The newest merged PR of this checkout's own GitHub repo whose branch has no other PR, so it is the row's PR.
pick='group_by(.headRefName) | map(select(length == 1 and .[0].state == "MERGED") | .[0]) | max_by(.number)
    | if . == null then empty else "\(.number) \(.headRefName)" end'
if merged=$(gh pr list --state all --limit 100 --json number,headRefName,state --jq "$pick" 2>/dev/null) &&
    [[ -n "$merged" ]]; then
    read -r number branch <<< "$merged"
    git init -q -b main "$work/ghdemo"
    git -C "$work/ghdemo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
    git -C "$work/ghdemo" remote add origin "$(git remote get-url origin)"
    "$cli" repo add "$work/ghdemo" >/dev/null
    git -C "$work/ghdemo" worktree add -q -b "$branch" "$CANOPY_HOME/worktrees/ghdemo/merged"
    for _ in $(seq 1 30); do
        "$cli" row list --repo ghdemo | grep -q "$branch" && break
        sleep 0.1
    done
    "$cli" pr "$branch" --repo ghdemo --refresh --json > "$work/pr.json"
    grep -q "\"number\" : $number" "$work/pr.json" || fail "canopy pr did not find PR $number"
    grep -q '"state" : "merged"' "$work/pr.json" || fail "PR $number is not shown as merged"
    "$cli" row select "$branch" --repo ghdemo >/dev/null
    sleep 1
    swift scripts/window-shot.swift "$(app_pid)" "$shots/pr.png"
    echo "saved $shots/pr.png"
else
    echo "skipped: needs gh logged in and an origin on GitHub with a merged PR"
fi

step "errors are machine-readable"
if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"

step "errors before any reply are machine-readable too"
if CANOPY_APP=/nonexistent CANOPY_HOME="$work/nobody" "$cli" row list --json > "$work/err2.json" 2>/dev/null; then
    fail "expected failure"
fi
grep -q '"app_unavailable"' "$work/err2.json" || fail "no JSON error when the app cannot be launched"

echo
echo "e2e passed"
