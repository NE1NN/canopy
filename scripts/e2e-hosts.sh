#!/usr/bin/env bash
# Drives a dev build through remote rows on a host, on a throwaway CANOPY_HOME.
#
#   scripts/e2e-hosts.sh                  a host this Mac plays through scripts/fake-ssh, with Homebrew's tmux
#   scripts/e2e-hosts.sh --host <alias>   a real host from ~/.ssh/config, in a throwaway ~/canopy-e2e/<id> there
#
# It adds the host, makes a remote row with --run, types into it, checks the host's report of its folder, rejoins the
# session after the app quits and after the connection drops, detaches the idle host and reconnects on Return, and
# removes the row and the host. The real host's throwaway folder and this home's tmux server there are removed at the
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
    local pid
    pid=$(app_pid)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    if [[ -n "$server" ]]; then on_host "tmux -u -L $server kill-server" >/dev/null 2>&1 || true; fi
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

stop_app() {
    local pid
    pid=$(app_pid)
    kill "$pid"
    for _ in $(seq 1 100); do
        [[ -z "$(app_pid)" ]] && return 0
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

step "term send types into it, and the host reports its folder"
"$cli" term send "$pane" "cd /tmp && echo sent-\$((1 + 1))" --enter >/dev/null
wait_for 30 screen_has sent-2 || fail "term send did not reach the host"
folder_is_tmp() { "$cli" term list --json | json '[t["folder"] for t in d if t["pane"] == "'"$pane"'"][0]' | grep -Eqx '(/private)?/tmp'; }
wait_for 20 folder_is_tmp || fail "term list does not show the host's folder"

step "quitting and relaunching joins the same session"
"$cli" term send "$pane" "echo before-quit-\$((2 + 2))" --enter >/dev/null
wait_for 30 screen_has before-quit-4 || fail "the marker did not show"
stop_app
launch
"$cli" row select e2e/remote --repo demo >/dev/null
pane=$("$cli" term list --json | json '[t["pane"] for t in d if t["row"] == "e2e/remote"][0]')
wait_for 90 screen_has before-quit-4 || fail "the relaunched pane did not rejoin its session"

step "a dropped connection reconnects to the same session"
control=$(ls "$CANOPY_HOME"/ssh/* 2>/dev/null | grep -v '\.env$' | head -1)
[[ -n "$control" ]] || control=$(ls /tmp/canopy-"$(id -u)"/* 2>/dev/null | grep -v '\.env$' | head -1)
before=$(connections)
"${CANOPY_SSH:-/usr/bin/ssh}" -S "$control" -O exit "$alias" >/dev/null 2>&1 || true
wait_for 90 connected_again || fail "the host did not reconnect"
sleep 2
"$cli" term send "$pane" "echo after-drop-\$((3 + 3))" --enter >/dev/null
wait_for 60 screen_has after-drop-6 || fail "the pane did not come back after the drop"
screen_has before-quit-4 || fail "the session after the drop is not the same one"

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
gone() { ! on_host "tmux -u -L $server has-session -t =$pane" 2>/dev/null; }
wait_for 20 gone || fail "the session is still on the host"
on_host "test ! -e '$remote'" || fail "the worktree is still on the host"
[[ ! -e "$stand_in" ]] || fail "the stand-in is still here"

step "host rm forgets the host"
"$cli" host rm "$alias" >/dev/null
[[ "$("$cli" host list --json | json 'len(d)')" == 0 ]] || fail "the host is still listed"

echo
echo "e2e-hosts passed against $alias"
