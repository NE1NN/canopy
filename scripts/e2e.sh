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
# Nothing here may reach the Canopy this script runs in, or the Claude Code settings every agent here runs with.
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH
export CLAUDE_CONFIG_DIR="$work/claude"
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

# Only apps on this run's home: other checkouts run dev builds of their own at the same time.
count_apps() {
    local count=0 pid
    for pid in $(pgrep -f "Canopy Dev.app/Contents/MacOS/Canopy" || true); do
        ps eww -p "$pid" -o command= | tr ' ' '\n' | grep -qxF "CANOPY_HOME=$CANOPY_HOME" && count=$((count + 1))
    done
    echo "$count"
}

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

step "canopy group and canopy row move arrange rows"
group_of() {
    "$cli" row list --repo demo --json |
        /usr/bin/python3 -c 'import json, sys; print({r["branch"]: r.get("group") for r in json.load(sys.stdin)}[sys.argv[1]])' "$1"
}
"$cli" group new Review --repo demo >/dev/null
"$cli" row new feat/grouped --repo demo --group review >/dev/null
"$cli" row list --repo demo | grep -Eq '^feat/grouped +Review +canopy ' || fail "row list has no GROUP column"
[[ "$(group_of feat/grouped)" == Review ]] || fail "row new --group did not put the row in the group"
"$cli" row move feat/plain --repo demo --group Review >/dev/null
"$cli" row move feat/plain --repo demo --before feat/grouped | grep -qx "Moved feat/plain before feat/grouped." ||
    fail "row move --before said something else"
"$cli" group list --repo demo --json | /usr/bin/python3 -c '
import json, sys
groups = json.load(sys.stdin)
assert [(g["name"], [r["branch"] for r in g["rows"]]) for g in groups] == [("Review", ["feat/plain", "feat/grouped"])], groups
' || fail "group list has the wrong rows"
"$cli" row move feat/plain --repo demo --group REVIEW | grep -qx "feat/plain is already in Review." ||
    fail "repeating row move --group was not a no-op"
"$cli" row move feat/plain --repo demo --no-group | grep -qx "Moved feat/plain out of Review." ||
    fail "row move --no-group said something else"
[[ "$(group_of feat/plain)" == None ]] || fail "feat/plain is still grouped"
if "$cli" row new feat/nogroup --repo demo --group Nope --json > "$work/nogroup.json" 2>/dev/null; then
    fail "expected failure"
fi
grep -q '"group_not_found"' "$work/nogroup.json" || fail "missing group_not_found"
[[ ! -d "$CANOPY_HOME/worktrees/demo/feat-nogroup" ]] || fail "a missing group still created the row"
if "$cli" group new " REVIEW " --repo demo --json > "$work/taken.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"group_exists"' "$work/taken.json" || fail "missing group_exists"
if "$cli" row move feat/grouped --repo demo --json > /dev/null 2>&1; then fail "row move without a destination"; fi
"$cli" group rename review "Code review" --repo demo | grep -qx "Renamed review to Code review." ||
    fail "group rename said something else"
"$cli" group rm "code REVIEW" --repo demo | grep -qx "Deleted group Code review. Its row is ungrouped." ||
    fail "group rm said something else"
[[ -d "$CANOPY_HOME/worktrees/demo/feat-grouped" ]] || fail "group rm touched a worktree"
[[ "$(group_of feat/grouped)" == None ]] || fail "group rm left the row grouped"
"$cli" log --type group | grep -q "Code review, 1 row" || fail "canopy log is missing group.removed"
"$cli" log --type row.moved | grep -q "none -> Review" || fail "canopy log is missing row.moved"
"$cli" agent-guide | grep -q "canopy group new" || fail "agent-guide is missing groups"
# Kept for the relaunch check at the end.
"$cli" group new Kept --repo demo >/dev/null
"$cli" row move feat/grouped --repo demo --group Kept >/dev/null

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

step "term send --enter presses Return as a keystroke of its own, with no paste markers"
# Puts its terminal in raw mode, turns on bracketed paste as Claude Code and vim do, and logs each read, with Return
# as <0d>.
cat > "$work/reads.pl" <<'PERL'
system("stty raw -echo");
open(my $log, ">>", $ARGV[0]) or die;
$log->autoflush(1);
$| = 1;
print "\e[?2004hready\r\n";
while (sysread(STDIN, my $bytes, 65536)) {
    $bytes =~ s/([^ -~])/sprintf("<%02x>", ord $1)/ge;
    print $log "$bytes\n";
}
PERL
recorder=$("$cli" term new --repo demo --row feat/term --run "exec perl '$work/reads.pl' '$work/reads.log'" --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
wait_for_reads() {
    for _ in $(seq 1 100); do
        [[ "$(cat "$work/reads.log" 2>/dev/null)" == "$1" ]] && return 0
        sleep 0.1
    done
    echo "reads were: $(cat "$work/reads.log" 2>/dev/null)" >&2
    return 1
}
for _ in $(seq 1 100); do
    "$cli" term read "$recorder" | grep -q ready && break
    sleep 0.1
done
"$cli" term read "$recorder" | grep -q ready || fail "the read recorder did not start"
message="A message of more than sixty-four bytes, which Claude Code once kept as a new line"
"$cli" term send "$recorder" "$message" --enter >/dev/null
wait_for_reads "$message"$'\n'"<0d>" || fail "Return did not come in a read of its own"
"$cli" term send "$recorder" "" --enter >/dev/null
wait_for_reads "$message"$'\n'"<0d>"$'\n'"<0d>" || fail "a lone --enter did not send Return"
"$cli" term close "$recorder" --force >/dev/null
"$cli" agent-guide | grep -q "keystroke of its own" || fail "agent-guide does not say how --enter presses Return"

step "canopy ports lists a server started in a row's terminal, and stops it"
# A free port below the system's random range, where Canopy looks for servers.
listen='my $s; for (1..200) { $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => 20000 + int(rand(20000))) and last } $s or die; sleep 300'
server=$("$cli" term new --repo demo --row feat/term --run "cd / && perl -MIO::Socket::INET -e '$listen'" --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
port=""
for _ in $(seq 1 100); do
    port=$("$cli" ports --repo demo --row feat/term --json |
        /usr/bin/python3 -c 'import json, sys; ports = json.load(sys.stdin); print(ports[0]["port"] if ports else "")')
    [[ -n "$port" ]] && break
    sleep 0.1
done
[[ -n "$port" ]] || fail "canopy ports did not list the server"
"$cli" ports --all | grep -q "^$port " || fail "ports --all is missing $port"
"$cli" ports stop "$port" | grep -q "Stopped perl" || fail "ports stop did not stop the server"
if "$cli" ports --all --json | grep -q "\"port\" : $port,"; then fail "port $port is still listed"; fi
"$cli" term close "$server" >/dev/null
"$cli" agent-guide | grep -q "canopy ports stop" || fail "agent-guide is missing ports"

step "Claude Code's hooks report into a pane, and agents wait on it"
agent=$("$cli" term new --repo demo --row feat/term --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
hook() {
    printf '%s' "$1" | CANOPY_PANE="$agent" "$cli" agent-hook > "$work/hook.out" 2>&1 || fail "agent-hook exited non-zero"
    [[ ! -s "$work/hook.out" ]] || fail "agent-hook printed something"
}
agent_state() {
    "$cli" term list --repo demo --row feat/term --json | /usr/bin/python3 -c \
        "import json, sys; print(next(t.get('agent', 'none') for t in json.load(sys.stdin) if t['pane'] == '$agent'))"
}
hook '{"session_id": "e2e", "hook_event_name": "SessionStart", "source": "startup"}'
hook '{"session_id": "e2e", "hook_event_name": "UserPromptSubmit", "prompt": "fix it"}'
[[ "$(agent_state)" == working ]] || fail "UserPromptSubmit did not make the pane working"
"$cli" term list --repo demo --row feat/term | grep "^$agent " | grep -q " working " || fail "term list has no AGENT column"
hook '{"session_id": "nested", "hook_event_name": "Stop", "last_assistant_message": "Done."}'
[[ "$(agent_state)" == working ]] || fail "another session's report moved the pane"
"$cli" term wait "$agent" --for done --timeout 30s --json > "$work/wait.json" &
waiter=$!
sleep 1
hook '{"session_id": "e2e", "hook_event_name": "Stop", "last_assistant_message": "Fixed it, and the tests pass."}'
wait "$waiter" || fail "term wait failed"
grep -q '"state" : "done"' "$work/wait.json" || fail "term wait did not report done"
hook '{"session_id": "e2e", "hook_event_name": "UserPromptSubmit", "prompt": "and the docs"}'
hook '{"session_id": "e2e", "hook_event_name": "Stop", "last_assistant_message": "Docs updated.\n\nShould I push it?"}'
[[ "$(agent_state)" == waiting ]] || fail "a turn ending on a question did not make the pane waiting"
"$cli" term state "$agent" none >/dev/null
[[ "$(agent_state)" == none ]] || fail "term state none did not clear the pane"
if "$cli" term wait "$agent" --timeout 1s --json > "$work/timeout.json" 2>/dev/null; then fail "expected a timeout"; fi
grep -q '"wait_timeout"' "$work/timeout.json" || fail "missing wait_timeout"
CANOPY_PANE="$agent" "$cli" term state done | grep -qx "$agent done" || fail "term state did not default to CANOPY_PANE"
"$cli" log --type agent --json > "$work/agent-log.json"
/usr/bin/python3 - "$work/agent-log.json" "$agent" <<'EOF' || fail "agent events are missing from the log"
import json, sys
events = [e for e in json.load(open(sys.argv[1])) if e["data"].get("pane") == sys.argv[2]]
types = [e["type"] for e in events]
want = ["agent.working", "agent.done", "agent.working", "agent.waiting", "agent.cleared", "agent.done"]
if types != want:
    sys.exit(f"got {types}")
if any(e["source"] != "cli" for e in events):
    sys.exit("agent events are not the CLI's")
EOF
if "$cli" log --type cli.call --json | grep -q '"term.state"'; then fail "term.state was logged as a CLI call"; fi
printf '{"session_id": "x", "hook_event_name": "Stop"}' | CANOPY_PANE=p1 CANOPY_HOME="$work/nobody" "$cli" agent-hook ||
    fail "agent-hook failed while its app was not running"
[[ ! -e "$work/nobody" ]] || fail "agent-hook started an app"
printf '{"session_id": "x", "hook_event_name": "Stop"}' | env -u CANOPY_PANE "$cli" agent-hook || fail "agent-hook failed outside Canopy"
"$cli" term close "$agent" >/dev/null
"$cli" agent-guide | grep -q "canopy term wait" || fail "agent-guide is missing term wait"

step "canopy hooks adds its hooks to Claude Code's settings and takes only its own out"
settings="$CLAUDE_CONFIG_DIR/settings.json"
if "$cli" hooks status >/dev/null; then fail "hooks status succeeded before install"; fi
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{\n  "model": "opus"\n}\n' > "$settings"
cp "$settings" "$work/settings.before"
"$cli" hooks install --json | grep -q '"state" : "installed"' || fail "hooks install did not install"
"$cli" hooks status >/dev/null || fail "hooks status failed after install"
grep -q 'agent-hook' "$settings" || fail "the settings file has no agent-hook"
"$cli" hooks uninstall >/dev/null
cmp -s "$settings" "$work/settings.before" || fail "uninstall did not give back the settings file"
"$cli" hooks install --settings "$work/other-settings.json" >/dev/null
grep -q 'agent-hook' "$work/other-settings.json" || fail "hooks install --settings wrote elsewhere"
"$cli" agent-guide | grep -q "canopy hooks install" || fail "agent-guide is missing canopy hooks"

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

step "canopy log shows what happened, with who did it"
"$cli" log --json > "$work/log.json"
/usr/bin/python3 - "$work/log.json" <<'EOF' || fail "canopy log is missing events"
import json, sys
events = json.load(open(sys.argv[1]))
seen = {(e["type"], e["source"]) for e in events}
need = {("repo.added", "cli"), ("row.created", "cli"), ("row.created", "git"), ("row.removed", "cli"),
        ("term.opened", "cli"), ("cli.call", "cli")}
missing = need - seen
if missing:
    sys.exit(f"missing {sorted(missing)}")
if any(e["type"] == "cli.call" and e["data"]["method"] in ("row.list", "term.read") for e in events):
    sys.exit("read-only calls were logged")
EOF
"$cli" log --type row.created | grep -q "feat/plain" || fail "canopy log does not show the plain git row"

step "commands that finish in a zsh terminal are logged"
if [[ "$(dscl . -read "/Users/$USER" UserShell | awk '{print $2}')" == */zsh ]]; then
    "$cli" term new --repo demo --row feat/term --run '(exit 7)' >/dev/null
    for _ in $(seq 1 100); do
        "$cli" log --type term.command | grep -q "exit 7 in .*: (exit 7)" && break
        sleep 0.1
    done
    "$cli" log --type term.command | grep -q "exit 7 in .*: (exit 7)" || fail "the command was not logged"
    [[ -f "$CANOPY_HOME/shell/zsh/.zshenv" ]] || fail "the zsh shim is missing"
else
    echo "skipped: the login shell is not zsh"
fi
"$cli" agent-guide | grep -q "canopy log" || fail "agent-guide is missing canopy log"

step "errors are machine-readable"
if "$cli" row new "bad name" --repo demo --json > "$work/err.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"invalid_branch"' "$work/err.json" || fail "missing error code"

step "errors before any reply are machine-readable too"
if CANOPY_APP=/nonexistent CANOPY_HOME="$work/nobody" "$cli" row list --json > "$work/err2.json" 2>/dev/null; then
    fail "expected failure"
fi
grep -q '"app_unavailable"' "$work/err2.json" || fail "no JSON error when the app cannot be launched"

stop_app() {
    kill "$(app_pid)"
    for _ in $(seq 1 50); do
        [[ -z "$(app_pid)" ]] && break
        sleep 0.1
    done
    [[ -z "$(app_pid)" ]] || fail "the app did not quit"
}

step "groups come back after a relaunch"
stop_app
"$cli" group list --repo demo --json | /usr/bin/python3 -c '
import json, sys
groups = json.load(sys.stdin)
assert [(g["name"], [r["branch"] for r in g["rows"]]) for g in groups] == [("Kept", ["feat/grouped"])], groups
' || fail "groups did not survive a relaunch"

step "canopy log works while Canopy is not running"
stop_app
"$cli" log --type repo.added | grep -q demo || fail "canopy log needs the app"
[[ -z "$(app_pid)" ]] || fail "canopy log launched the app"

step "canopy repo clone clones owner/repo through gh into repos/<owner>/<name>"
# A stand-in gh clones from local bare repos and points origin at GitHub, as gh would, so nothing reaches the network.
# The app finds it first on its login PATH through a ZDOTDIR, so this part launches the app itself.
mkdir -p "$work/bin" "$work/zdot"
cat > "$work/bin/gh" <<'GH'
#!/bin/bash
remotes="$(cd "$(dirname "$0")/.." && pwd)/remotes"
# PR lookups for the repos above find no PRs.
[[ "$1 $2" == "api graphql" ]] && { echo '{"data": {"repository": {}}}'; exit 0; }
[[ "$1 $2" == "repo clone" ]] || { echo "gh: the stand-in only clones" >&2; exit 1; }
repo="${3#https://github.com/}"
repo="${repo%.git}"
if [[ ! -d "$remotes/$repo.git" ]]; then
    echo "GraphQL: Could not resolve to a Repository with the name '$repo'. (repository)" >&2
    exit 1
fi
git clone "${@:6}" "file://$remotes/$repo.git" "$4" || exit 1
git -C "$4" remote set-url origin "https://github.com/$repo.git"
GH
chmod +x "$work/bin/gh"
printf 'export PATH="%s/bin:$PATH"\n' "$work" > "$work/zdot/.zshrc"
for repo in acme/app other/app team/lib; do
    git clone -q --bare "$work/demo" "$work/remotes/$repo.git"
done
# git may only use local repos, so a clone that falls back to plain git fails instead of reaching the network.
(ZDOTDIR="$work/zdot" SHELL=/bin/zsh GIT_ALLOW_PROTOCOL=file \
    exec "$app/Contents/MacOS/Canopy" </dev/null >/dev/null 2>&1) &
# Stopped later, and bash would otherwise report the job it killed.
disown
for _ in $(seq 1 100); do
    [[ -n "$(app_pid)" ]] && break
    sleep 0.1
done
[[ -n "$(app_pid)" ]] || fail "the app did not start"
json_field() { /usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$@"; }
repos="$(cd "$CANOPY_HOME" && pwd -P)/repos"
"$cli" repo clone acme/app --json > "$work/clone.json"
[[ "$(json_field "$work/clone.json" path)" == "$repos/acme/app" ]] || fail "acme/app is not in repos/acme/app"
[[ "$(git -C "$repos/acme/app" remote get-url origin)" == https://github.com/acme/app.git ]] || fail "wrong origin"
git -C "$repos/acme/app" log --oneline -1 | grep -q "canopy config" || fail "the clone has no commits"

step "cloning it again registers the folder it made"
"$cli" repo clone https://github.com/acme/app --json > "$work/again.json"
[[ "$(json_field "$work/again.json" path)" == "$repos/acme/app" ]] || fail "the second clone went somewhere else"
[[ "$("$cli" repo list | grep -c "repos/acme/app")" == 1 ]] || fail "acme/app is registered twice"

step "two repos named app show their owners"
"$cli" repo clone other/app >/dev/null
"$cli" repo list | grep -q "^acme/app " || fail "acme/app is not named by its owner"
"$cli" repo list | grep -q "^other/app " || fail "other/app is not named by its owner"

step "other URLs clone with git, and --into takes a folder relative to the caller"
(cd "$work" && "$cli" repo clone "file://$work/remotes/team/lib.git" --into ./lib-copy --json) > "$work/lib.json"
[[ "$(json_field "$work/lib.json" path)" == "$(cd "$work" && pwd -P)/lib-copy" ]] || fail "--into was not used"

step "a failed clone exits 1 and leaves nothing behind"
if "$cli" repo clone acme/nope --json > "$work/nope.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"clone_failed"' "$work/nope.json" || fail "missing clone_failed"
[[ "$(ls -A "$repos/acme")" == app ]] || fail "the failed clone left $(ls -A "$repos/acme")"

step "a folder holding something else is refused and left alone"
mkdir -p "$repos/acme/taken"
touch "$repos/acme/taken/notes.txt"
if "$cli" repo clone acme/taken --json > "$work/taken.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"folder_taken"' "$work/taken.json" || fail "missing folder_taken"
[[ -f "$repos/acme/taken/notes.txt" ]] || fail "the folder's contents were touched"

step "screenshot"
"$cli" row select main --repo acme/app >/dev/null
sleep 1
swift scripts/window-shot.swift "$(app_pid)" "$shots/clone.png"
echo "saved $shots/clone.png"

step "terminals take ZDOTDIR from the login session, not from whatever launched Canopy, and still log commands"
# A Terminal window would not get the ZDOTDIR this app was launched with, whose .zshrc puts the stand-in gh on PATH.
# This guards against passing the app's own ZDOTDIR on. Testing the login session's would mean changing the Mac's.
check="[[ \${ZDOTDIR-} != '$work/zdot' && \${commands[gh]-} != '$work/bin/gh' ]] && echo zdotdir-\$((40 + 2))"
pane=$("$cli" term new --repo acme/app --row main --run "$check" --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
wait_for_text zdotdir-42 || fail "the terminal read the ZDOTDIR the app was launched with"
for _ in $(seq 1 50); do
    "$cli" log --type term.command | grep -q 'zdotdir-' && break
    sleep 0.1
done
"$cli" log --type term.command | grep -q 'zdotdir-' || fail "the terminal's command was not logged"

step "repo rm unregisters a clone and leaves its folder"
"$cli" repo rm acme/app >/dev/null
[[ -d "$repos/acme/app/.git" ]] || fail "repo rm deleted the clone"

step "clones are in the activity log"
"$cli" log --json > "$work/clone-log.json"
/usr/bin/python3 - "$work/clone-log.json" <<'EOF' || fail "canopy log is missing the clone"
import json, sys
events = json.load(open(sys.argv[1]))
added = [e for e in events if e["type"] == "repo.added" and e["data"].get("clonedFrom") == "acme/app"]
calls = [e for e in events if e["type"] == "cli.call" and e["data"]["method"] == "repo.clone"]
if len(added) != 1 or added[0]["source"] != "cli":
    sys.exit(f"repo.added for acme/app: {added}")
if len(calls) < 5 or not any(c["data"].get("error") == "clone_failed" for c in calls):
    sys.exit(f"repo.clone calls: {calls}")
EOF
"$cli" agent-guide | grep -q "canopy repo clone" || fail "agent-guide is missing repo clone"

step "row new --pr checks out a PR's branch, from the repo and from a fork"
# The app running now answers gh from the clone steps' stand-in, so this part starts one of its own.
kill "$(app_pid)"
for _ in $(seq 1 50); do
    [[ -z "$(app_pid)" ]] && break
    sleep 0.1
done
[[ -z "$(app_pid)" ]] || fail "the app did not quit"
# A GitHub on this machine: bare repos in $work/remotes, which git reaches at https://github.com/ through a URL rewrite,
# and a stand-in gh that answers from the PRs in $work/prs. The app gets both only when this script launches it.
mkdir -p "$work/prbin" "$work/przdot" "$work/prs"
git clone -q --bare "$work/demo" "$work/remotes/acme/shop.git"
git clone -q --bare "$work/demo" "$work/remotes/someone/shop.git"
git clone -q "$work/remotes/acme/shop.git" "$work/prwork"
author() { git -C "$work/prwork" -c user.email=e2e@example.com -c user.name=e2e "$@"; }
author switch -q -c feat/checkout
author commit -q --allow-empty -m "checkout in steps"
author push -q origin feat/checkout feat/checkout:refs/pull/21/head
author switch -q -c feat/fork main
author commit -q --allow-empty -m "a fix from a fork"
author push -q "$work/remotes/someone/shop.git" feat/fork
author push -q origin feat/fork:refs/pull/22/head
write_pr() { # number, head branch, head owner, maintainerCanModify, state (default OPEN)
    /usr/bin/python3 - "$work/prs/$1.json" "$1" "$2" "$3" "$4" "${5:-OPEN}" "$(author rev-parse "$2")" <<'EOF'
import json, sys
path, number, branch, owner, editable, state, oid = sys.argv[1:]
json.dump({"number": int(number), "title": f"PR {number}", "url": f"https://github.com/acme/shop/pull/{number}",
           "state": state, "isDraft": False, "updatedAt": f"2026-09-28T00:00:{number}Z", "headRefName": branch,
           "headRefOid": oid, "headRef": {"name": branch}, "baseRefName": "main",
           "isCrossRepository": owner != "acme", "maintainerCanModify": editable == "true",
           "headRepository": {"name": "shop"}, "headRepositoryOwner": {"login": owner},
           "author": {"login": owner}}, open(path, "w"))
EOF
}
write_pr 21 feat/checkout acme false
write_pr 22 feat/fork someone true
cat > "$work/prbin/gh" <<'GH'
#!/usr/bin/python3
import json, os, re, sys
prs = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prs")
query = next(a[6:] for a in sys.argv if a.startswith("query="))
def load(number):
    path = os.path.join(prs, f"{number}.json")
    return json.load(open(path)) if os.path.exists(path) else None
if "maintainerCanModify" in query:
    number = re.search(r"pullRequest\(number: (\d+)\)", query).group(1)
    pr = load(number)
    print(json.dumps({"data": {"repository": {"defaultBranchRef": {"name": "main"}, "pullRequest": pr}}}))
    if pr is None:
        sys.stderr.write(f"gh: Could not resolve to a PullRequest with the number of {number}.\n")
        sys.exit(1)
    sys.exit(0)
def node(pr):
    return {key: pr[key] for key in ("number", "title", "url", "state", "isDraft", "updatedAt", "isCrossRepository")}
everything = [load(name[:-5]) for name in os.listdir(prs)]
if "pullRequests(states:" in query:
    states = re.search(r"pullRequests\(states: \[([A-Z, ]*)\]", query).group(1).split(", ")
    nodes = [dict(node(pr), headRefName=pr["headRefName"], author=pr["author"])
             for pr in everything if pr["state"] in states]
    nodes.sort(key=lambda n: n["updatedAt"], reverse=True)
    print(json.dumps({"data": {"repository": {"pullRequests": {"nodes": nodes}}}}))
    sys.exit(0)
repo = {}
for alias, number in re.findall(r"(b\d+): pullRequest\(number: (\d+)\)", query):
    if load(number) is None:
        # Like gh: GitHub fails the whole query, and gh exits 1.
        print(json.dumps({"data": {"repository": {alias: None}}}))
        sys.stderr.write(f"gh: Could not resolve to a PullRequest with the number of {number}.\n")
        sys.exit(1)
    repo[alias] = node(load(number))
for alias, branch in re.findall(r'(b\d+): pullRequests\(headRefName: "([^"]*)"', query):
    repo[alias] = {"nodes": [node(pr) for pr in everything if pr["headRefName"] == branch]}
print(json.dumps({"data": {"repository": repo}}))
GH
chmod +x "$work/prbin/gh"
printf 'export PATH="%s/prbin:$PATH"\n' "$work" > "$work/przdot/.zshrc"
(ZDOTDIR="$work/przdot" SHELL=/bin/zsh GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$work/remotes/.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/ exec "$app/Contents/MacOS/Canopy" </dev/null >/dev/null 2>&1) &
# cleanup stops it, and bash would otherwise report the job it killed.
disown
for _ in $(seq 1 100); do
    [[ -n "$(app_pid)" ]] && break
    sleep 0.1
done
[[ -n "$(app_pid)" ]] || fail "the app did not start"
git clone -q "$work/remotes/acme/shop.git" "$work/shop"
git -C "$work/shop" remote set-url origin https://github.com/acme/shop.git
"$cli" repo add "$work/shop" >/dev/null
field() { /usr/bin/python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."): v = v[int(key)] if isinstance(v, list) else v[key]
print(v)' "$@"; }
"$cli" group new Review --repo shop >/dev/null
"$cli" row new --pr 21 --repo shop --group Review --no-setup --json > "$work/pr21.json"
[[ "$(field "$work/pr21.json" row.branch)" == feat/checkout ]] || fail "PR 21 is not on feat/checkout"
[[ "$(field "$work/pr21.json" source)" == origin ]] || fail "PR 21's branch did not come from origin"
[[ "$(field "$work/pr21.json" pr.number)" == 21 ]] || fail "the result does not name PR 21"
[[ "$(field "$work/pr21.json" row.group)" == Review ]] || fail "row new --pr --group did not put the row in Review"
row21="$(field "$work/pr21.json" row.path)"
[[ "$(git -C "$row21" rev-parse --abbrev-ref '@{upstream}')" == origin/feat/checkout ]] || fail "PR 21 tracks the wrong branch"
"$cli" row new --pr https://github.com/acme/shop/pull/22/files --repo shop --no-setup --select > "$work/pr22.txt"
grep -q "^Checked out PR #22 as feat/fork in " "$work/pr22.txt" || fail "row new --pr printed $(cat "$work/pr22.txt")"
[[ "$(git -C "$work/shop" config branch.feat/fork.pushRemote)" == https://github.com/someone/shop.git ]] ||
    fail "the fork PR does not push to the fork"
[[ "$(git -C "$work/shop" log -1 --format=%s feat/fork)" == "a fix from a fork" ]] || fail "the fork's commit is missing"

step "a fork PR's row gets its badge"
"$cli" pr feat/fork --repo shop --refresh --json > "$work/pr22-badge.json"
[[ "$(field "$work/pr22-badge.json" pr.number)" == 22 ]] || fail "the fork PR row has no PR"
sleep 1
swift scripts/window-shot.swift "$(app_pid)" "$shots/pr-fork.png"
echo "saved $shots/pr-fork.png"

step "row new says which branch it used, and --existing refuses a name that matches nothing"
git -C "$work/shop" branch feat/local
"$cli" row new feat/local --repo shop --no-setup | grep -q "^Checked out feat/local in " || fail "feat/local was not checked out"
"$cli" row new feat/brand-new --repo shop --no-setup | grep -q "^Created new branch feat/brand-new from origin/main in " ||
    fail "feat/brand-new does not say it is new"
if "$cli" row new feat/typo --repo shop --existing --json > "$work/typo.json" 2>/dev/null; then fail "expected failure"; fi
grep -q '"branch_not_found"' "$work/typo.json" || fail "missing branch_not_found"
if git -C "$work/shop" show-ref --verify --quiet refs/heads/feat/typo; then fail "--existing created a branch"; fi
"$cli" agent-guide | grep -q "row new --pr" || fail "agent-guide is missing row new --pr"

step "pr list shows the repo's PRs and the row that has each"
author switch -q -c fix/old main
author commit -q --allow-empty -m "an old fix"
author push -q origin fix/old fix/old:refs/pull/23/head
write_pr 23 fix/old acme false CLOSED
"$cli" pr list --repo shop --json > "$work/prs.json"
/usr/bin/python3 - "$work/prs.json" "$row21" <<'EOF' || fail "pr list is wrong"
import json, sys
prs, row21 = json.load(open(sys.argv[1])), sys.argv[2]
assert [pr["number"] for pr in prs] == [22, 21], prs
assert prs[1]["row"]["path"] == row21 and prs[1]["row"]["class"] == "canopy", prs[1]
assert prs[0]["fork"] and prs[0]["row"]["branch"] == "feat/fork" and prs[0]["author"] == "someone", prs[0]
EOF
"$cli" pr list --repo shop | grep -Eq '^#21 +open .* in row +PR 21$' || fail "pr list printed $("$cli" pr list --repo shop)"
"$cli" pr list --repo shop --query SOMEONE --json > "$work/someone.json"
[[ "$(field "$work/someone.json" 0.number)" == 22 ]] || fail "pr list --query did not find PR 22 by its author"
"$cli" pr list --repo shop --closed --json | grep -q '"number" : 23' || fail "pr list --closed is missing PR 23"
# Saved first, so a failing canopy fails the run rather than passing a check that something is absent.
"$cli" pr list --repo shop --json > "$work/open.json"
if grep -q '"number" : 23' "$work/open.json"; then fail "pr list shows the closed PR 23"; fi
"$cli" pr list --repo shop --query '#23' --json > "$work/pr23.json"
[[ "$(field "$work/pr23.json" 0.state)" == closed && "$(field "$work/pr23.json" 0.row)" == None ]] ||
    fail "pr list --query '#23' did not look up the closed PR"

step "pr show is the default of canopy pr"
"$cli" pr show feat/checkout --repo shop --json > "$work/show.json"
[[ "$(field "$work/show.json" pr.number)" == 21 ]] || fail "pr show did not show PR 21"
"$cli" pr feat/checkout --repo shop --json > "$work/show-default.json"
[[ "$(field "$work/show-default.json" pr.number)" == 21 ]] || fail "canopy pr alone did not show PR 21"

step "branch list shows local and origin branches, and fetches first"
author push -q origin main:refs/heads/feat/just-pushed
"$cli" branch list --repo shop --no-fetch > "$work/no-fetch.txt"
if grep -q feat/just-pushed "$work/no-fetch.txt"; then fail "branch list --no-fetch fetched"; fi
"$cli" branch list --repo shop --json > "$work/branches.json"
/usr/bin/python3 - "$work/branches.json" "$row21" <<'EOF' || fail "branch list is wrong"
import json, sys
branches, row21 = {b["name"]: b for b in json.load(open(sys.argv[1]))}, sys.argv[2]
assert branches["feat/just-pushed"]["where"] == "origin" and branches["feat/just-pushed"]["row"] is None, branches
assert branches["feat/checkout"]["where"] == "both" and branches["feat/checkout"]["row"]["path"] == row21, branches
assert branches["feat/local"]["where"] == "local" and branches["feat/local"]["row"]["class"] == "canopy", branches
assert branches["main"]["row"]["class"] == "main", branches
EOF
"$cli" branch list --repo shop --query "just push" | grep -Eq '^feat/just-pushed +origin ' ||
    fail "branch list --query printed $("$cli" branch list --repo shop --query "just push")"
"$cli" agent-guide | grep -q "canopy branch list" || fail "agent-guide is missing branch list"

echo
echo "e2e passed"
