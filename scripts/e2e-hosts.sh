#!/usr/bin/env bash
# Drives a dev build through remote rows on a host, on a throwaway CANOPY_HOME.
#
#   scripts/e2e-hosts.sh                  a host this Mac plays through scripts/fake-ssh, with Homebrew's tmux
#   scripts/e2e-hosts.sh --host <alias>   a real host from ~/.ssh/config, in a throwaway ~/canopy-e2e/<id> there
#
# It adds the host, makes a remote row with --run, types into it, checks the host's report of its folder, checks a
# second home on the same host keeps to its own tmux server, rejoins the session after the app quits and after the
# connection drops, drops keys typed while reconnecting, detaches the idle host and reconnects on Return, and removes
# the row and the host. The real host's throwaway folder and this home's tmux server there are removed at the
# end, and nothing else on the host is touched.
set -euo pipefail
cd "$(dirname "$0")/.."

alias=""
if [[ "${1:-}" == --host ]]; then alias="$2"; fi
app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
[[ -x "$cli" ]] || { echo "build it first: make app" >&2; exit 1; }
work=$(mktemp -d -t cnp-hosts)
export CANOPY_HOME="$work/home"
export CANOPY_TRASH_FOLDER="$work/trash"
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH CANOPY_PLUGIN CANOPY_ITEM CANOPY_HOST
export CLAUDE_CONFIG_DIR="$work/claude"
id="e2e-$(date +%s)"

step() { printf '\n==> %s\n' "$*"; }
fail() {
    echo "FAIL: $*" >&2
    "$cli" host list --json >&2 2>/dev/null || true
    "$cli" term list --json >&2 2>/dev/null || true
    [[ -n "${pane:-}" ]] && "$cli" term read "$pane" --lines 15 >&2 2>/dev/null || true
    "$cli" log --type host.connected --type host.detached --type host.unreachable --type host.woken >&2 2>/dev/null || true
    exit 1
}
json() { /usr/bin/python3 -c "import json, sys; d = json.load(sys.stdin); print($1)"; }
app_pid() { "$cli" status --json 2>/dev/null | json 'd.get("pid", "")' || true; }

if [[ -z "$alias" ]]; then
    alias=fake-box
    command -v tmux >/dev/null || [[ -x /opt/homebrew/bin/tmux ]] || fail "the fake host needs tmux: brew install tmux"
    host_home="$work/host"
    mkdir -p "$host_home"
    export CANOPY_SSH="$PWD/scripts/fake-ssh" FAKE_SSH_HOME="$host_home"
    export FAKE_SSH_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    on_host() { "$CANOPY_SSH" -- "$alias" "$@"; }
    host_dir="$host_home/canopy-e2e/$id"
else
    on_host() { ssh -o BatchMode=yes "$alias" "$@"; }
    host_dir="$(on_host 'printf %s "$HOME"')/canopy-e2e/$id"
fi

server=""
cleanup() {
    local pid home name
    for home in "$CANOPY_HOME" "$work/home2"; do
        pid=$(CANOPY_HOME="$home" app_pid)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    for name in "$server" "${server2:-}"; do
        if [[ -n "$name" ]]; then on_host "tmux -u -L $name kill-server" >/dev/null 2>&1 || true; fi
    done
    # The fake host's tmux server can outlive kill-server once its folder goes, so it is stopped by its config's path.
    if [[ -n "${host_home:-}" ]]; then pkill -9 -f "tmux -u -L canopy-[0-9a-f]* -f $host_home/" 2>/dev/null || true; fi
    on_host "rm -rf '$host_dir'" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

launch() {
    (exec "$app/Contents/MacOS/Canopy" </dev/null >/dev/null 2>&1) &
    # Quit with kill later, which bash would otherwise report.
    disown
    for _ in $(seq 1 100); do
        [[ -S "$CANOPY_HOME/canopy.sock" ]] && return 0
        sleep 0.1
    done
    fail "the app did not start"
}

# Waits for the process, not its socket: the app closes the socket first, and still holds the home while it quits.
stop_app() {
    local pid
    pid=$(app_pid)
    kill "$pid"
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    fail "the app did not quit"
}

wait_for() { # seconds, then a command that must succeed
    local seconds=$1
    shift
    for _ in $(seq 1 $((seconds * 4))); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}

screen_has() { "$cli" term read "$pane" --lines 200 | grep -q "$1"; }
host_state() { "$cli" host list --json | json '[h["state"] for h in d if h["alias"] == "'"$alias"'"][0]'; }
state_is() { [[ "$(host_state)" == "$1" ]]; }
connections() { "$cli" log --type host.connected --json | json 'len(d)'; }
connected_again() { (($(connections) > before)); }

step "a throwaway repo here, and its clone on $alias"
git init -q -b main "$work/demo"
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
on_host "set -e; mkdir -p '$host_dir'; git init -q --bare -b main '$host_dir/origin.git'; \
    git clone -q '$host_dir/origin.git' '$host_dir/demo' 2>/dev/null; \
    git -C '$host_dir/demo' -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init; \
    git -C '$host_dir/demo' push -q origin main; git -C '$host_dir/demo' remote set-head origin main"

step "host add checks the host and installs Canopy's files"
launch
"$cli" repo add "$work/demo" >/dev/null
"$cli" host add "$alias" --repo "demo=$host_dir/demo" >/dev/null
server=$("$cli" host list --json | json '[h["tmuxServer"] for h in d if h["alias"] == "'"$alias"'"][0]')
[[ "$(host_state)" == connected ]] || fail "the host is $(host_state), not connected"
on_host 'test -x ~/.canopy/bin/canopy-host' || fail "canopy-host is not on the host"
if "$cli" host add "$alias" --repo "demo=$host_dir/nowhere" 2>/dev/null; then fail "a missing clone was accepted"; fi

step "row new --on makes the worktree on the host and runs --run in its tmux session"
"$cli" row new "e2e/remote" --repo demo --on "$alias" --run 'echo remote-$((40 + 2))' >/dev/null
pane=$("$cli" term list --json | json '[t["pane"] for t in d if t["row"] == "e2e/remote"][0]')
wait_for 60 screen_has remote-42 || fail "--run did not reach the host"
remote=$("$cli" row list --json | json '[r["remotePath"] for r in d if r.get("branch") == "e2e/remote"][0]')
on_host "test \"\$(git -C '$remote' rev-parse --abbrev-ref HEAD)\" = e2e/remote" || fail "no worktree at $remote"
on_host "tmux -u -L $server has-session -t =$pane" || fail "no tmux session named $pane"
# The session keeps its name when relaunching gives the pane a new one.
session=$pane
created_at() { on_host "tmux -u -L $server display-message -p -t '=$session:' '#{session_created}'"; }
session_count() { on_host "tmux -u -L $server list-sessions" | wc -l | tr -d ' '; }
started=$(created_at)

step "term send types into it, and the host reports its folder"
"$cli" term send "$pane" "cd /tmp && echo sent-\$((1 + 1))" --enter >/dev/null
wait_for 30 screen_has sent-2 || fail "term send did not reach the host"
folder_is_tmp() { "$cli" term list --json | json '[t["folder"] for t in d if t["pane"] == "'"$pane"'"][0]' | grep -Eqx '(/private)?/tmp'; }
wait_for 20 folder_is_tmp || fail "term list does not show the host's folder"

step "a second home on the same host has its own tmux server and sessions"
home2() { CANOPY_HOME="$work/home2" "$@"; }
CANOPY_HOME="$work/home2" launch
home2 "$cli" repo add "$work/demo" >/dev/null
home2 "$cli" host add "$alias" --repo "demo=$host_dir/demo" >/dev/null 2>&1
server2=$(home2 "$cli" host list --json | json '[h["tmuxServer"] for h in d if h["alias"] == "'"$alias"'"][0]')
[[ "$server2" != "$server" ]] || fail "both homes use the tmux server $server"
home2 "$cli" row new "e2e/other" --repo demo --on "$alias" --run 'echo other-$((1 + 1))' >/dev/null
pane2=$(home2 "$cli" term list --json | json '[t["pane"] for t in d if t["row"] == "e2e/other"][0]')
other_has() { home2 "$cli" term read "$pane2" --lines 200 | grep -q "$1"; }
wait_for 60 other_has other-2 || fail "--run did not reach the host from the second home"
[[ "$(on_host "tmux -u -L $server list-sessions -F '#{session_name}'")" == "$session" ]] ||
    fail "the first home's server has sessions it did not make"
[[ "$(on_host "tmux -u -L $server2 list-sessions -F '#{session_name}'")" == "$pane2" ]] ||
    fail "the second home's server has sessions it did not make"
"$cli" term list --json | json '[t["row"] for t in d]' | grep -q "e2e/other" && fail "the first home lists the other's pane"
stand_in2=$(home2 "$cli" row list --json | json '[r["path"] for r in d if r.get("branch") == "e2e/other"][0]')
home2 "$cli" row rm "$stand_in2" --force --delete-branch >/dev/null
home2 "$cli" host rm "$alias" >/dev/null
CANOPY_HOME="$work/home2" stop_app
on_host "tmux -u -L $server2 kill-server" >/dev/null 2>&1 || true

step "quitting and relaunching joins the same session"
"$cli" term send "$pane" "echo before-quit-\$((2 + 2))" --enter >/dev/null
wait_for 30 screen_has before-quit-4 || fail "the marker did not show"
stop_app
launch
"$cli" row select e2e/remote --repo demo >/dev/null
pane=$("$cli" term list --json | json '[t["pane"] for t in d if t["row"] == "e2e/remote"][0]')
wait_for 90 screen_has before-quit-4 || fail "the relaunched pane did not rejoin its session"
[[ "$(created_at)" == "$started" && "$(session_count)" == 1 ]] || fail "relaunching started another session"

step "a dropped connection reconnects to the same session"
# The master's control socket is named after this home's id, in the home or, when that is too long, in /tmp.
control=$({ ls "$CANOPY_HOME"/ssh/"${server#canopy-}"-* /tmp/canopy-"$(id -u)"/"${server#canopy-}"-* 2>/dev/null || true; } |
    grep -v '\.env$' | head -1)
[[ -n "$control" ]] || fail "no control socket for this home"
before=$(connections)
"${CANOPY_SSH:-/usr/bin/ssh}" -S "$control" -O exit "$alias" >/dev/null 2>&1 || true
# Keys typed while the pane says it is reconnecting were meant for that message, not for the session.
wait_for 30 screen_has "reconnecting" || fail "the pane did not say it was reconnecting"
"$cli" term send "$pane" "echo leaked-\$((5 + 5))" --enter >/dev/null
wait_for 90 connected_again || fail "the host did not reconnect"
sleep 2
"$cli" term send "$pane" "echo after-drop-\$((3 + 3))" --enter >/dev/null
wait_for 60 screen_has after-drop-6 || fail "the pane did not come back after the drop"
[[ "$(created_at)" == "$started" && "$(session_count)" == 1 ]] || fail "the session after the drop is not the same one"
! screen_has leaked-10 || fail "keys typed while reconnecting reached the session"

step "an idle host detaches, and Return reconnects"
"$cli" host add "$alias" --idle-detach 1 >/dev/null
wait_for 150 state_is detached || fail "the host did not detach"
wait_for 10 screen_has "can sleep. Press Return to reconnect" || fail "the pane does not say it detached"
"$cli" host add "$alias" --idle-detach 30 >/dev/null
"$cli" term send "$pane" "" --enter >/dev/null
wait_for 90 state_is connected || fail "Return did not reconnect"
"$cli" term send "$pane" "echo back-\$((4 + 4))" --enter >/dev/null
wait_for 60 screen_has back-8 || fail "the pane did not rejoin after Return"

step "row rm ends the session, removes the worktree, and forgets the row"
stand_in=$("$cli" row list --json | json '[r["path"] for r in d if r.get("branch") == "e2e/remote"][0]')
"$cli" row rm "$stand_in" --force --delete-branch >/dev/null
gone() { ! on_host "tmux -u -L $server has-session -t =$session" 2>/dev/null; }
wait_for 20 gone || fail "the session is still on the host"
on_host "test ! -e '$remote'" || fail "the worktree is still on the host"
[[ ! -e "$stand_in" ]] || fail "the stand-in is still here"

step "host rm forgets the host"
"$cli" host rm "$alias" >/dev/null
[[ "$("$cli" host list --json | json 'len(d)')" == 0 ]] || fail "the host is still listed"

echo
echo "e2e-hosts passed against $alias"
