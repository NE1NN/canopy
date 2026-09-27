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

step "CLI launches the app and registers the repo"
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

step "errors are machine-readable"
if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"

echo
echo "e2e passed"
