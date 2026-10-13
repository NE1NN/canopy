#!/usr/bin/env bash
# Drives a dev build through remote rows on a host, on a throwaway CANOPY_HOME.
#
#   scripts/e2e-hosts.sh                  a host this Mac plays through scripts/fake-ssh, with Homebrew's tmux
#   scripts/e2e-hosts.sh --host <alias>   a real host from ~/.ssh/config, in a throwaway ~/canopy-e2e/<id> there
#
# It adds the host, makes a remote row with --run, types into it, and checks the host's report of its folder. In the
# remote pane it runs the host's canopy: row list, term list, a hook's report, web open, xdg-open of an artifact link,
# and row new. Dev servers started there are forwarded to this Mac, one on a port held here takes the next port, and
# canopy ports stop, with this Mac's port here or the host's typed in the remote pane, stops them on the host. It checks
# a second home on the same host keeps to its own tmux server, rejoins the session after the app quits and replays a
# hook's report kept meanwhile, rejoins after the connection drops, keeps keys typed while reconnecting, detaches the
# idle host and reconnects on Return, and removes the row and the host. The real host's throwaway folder, and the
# throwaway homes' tmux servers, own files, and worktrees there, are removed at the end, as are the dev servers.
# Apart from them, only the host's Claude Code settings change: host add writes Canopy's hooks there, which do nothing
# outside a Canopy pane.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: scripts/e2e-hosts.sh [--host <alias> [--with-box]]" >&2
    exit 2
}
alias=""
with_box=0
case "${1:-}" in
    "") with_box=1 ;;
    --host)
        [[ -n "${2:-}" ]] || usage
        alias="$2"
        case "${3:-}" in
            "") [[ $# == 2 ]] || usage ;;
            # Installs canopy-box and its systemd user service on the host, for this run's throwaway home only.
            --with-box) [[ $# == 3 ]] || usage; with_box=1 ;;
            *) usage ;;
        esac ;;
    *) usage ;;
esac
app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
[[ -x "$cli" ]] || { echo "build it first: make app" >&2; exit 1; }
work=$(mktemp -d -t cnp-hosts)
host_home=""
# Until the full cleanup below is ready.
trap 'rm -rf "$work" ${host_home:+"$host_home"}' EXIT
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
    # Short, so the pane's socket there, ~/.canopy/<home id>/app.sock, stays well under macOS's 104 bytes.
    host_home=$(mktemp -d /tmp/cnp-host.XXXXXX)
    export CANOPY_SSH="$PWD/scripts/fake-ssh" FAKE_SSH_HOME="$host_home"
    export FAKE_SSH_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    # The host's ss lists this Mac's sockets of processes working in the host's home, as a real host lists its own. A
    # link to a file that has run before, since this Mac's security scanner can hold a new file's first run.
    mkdir -p "$host_home/.fake-ssh-bin"
    ln -s "$PWD/scripts/fake-ss" "$host_home/.fake-ssh-bin/ss"
    touch "$host_home/.fake-ss-home-only"
    on_host() { "$CANOPY_SSH" -- "$alias" "$@"; }
    host_dir="$host_home/canopy-e2e/$id"
    # The fake host is this Mac, so it runs canopy-box built for macOS.
    swift build --product canopy-box >/dev/null
    export CANOPY_BOX_BINARY="$(swift build --show-bin-path)/canopy-box"
else
    on_host() { ssh -o BatchMode=yes "$alias" "$@"; }
    host_dir="$(on_host 'printf %s "$HOME"')/canopy-e2e/$id"
fi

# The dev servers' folder on the host, whose path, unique to this run, picks out the servers the run started there.
www="$host_dir/www"
listener=""
# Stops the local listener the run started, while its pid still runs it.
stop_listener() {
    if [[ -n "$listener" && "$(ps -ww -o command= -p "$listener" 2>/dev/null)" == *"canopy-e2e-listener-$id"* ]]; then
        kill "$listener" 2>/dev/null || true
    fi
    listener=""
}
server=""
cleanup() {
    local pid home name
    for home in "$CANOPY_HOME" "$work/home2"; do
        pid=$(CANOPY_HOME="$home" app_pid)
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    stop_listener
    on_host "pkill -f 'http[.]server [0-9]* --bind [^ ]* --directory $www'" >/dev/null 2>&1 || true
    for name in "$server" "${server2:-}"; do
        [[ -n "$name" ]] || continue
        # canopy-box, for this run's throwaway home only.
        on_host "systemctl --user disable --now ${name/canopy-/canopy-box-} >/dev/null 2>&1; rm -f ~/.config/systemd/user/${name/canopy-/canopy-box-}.service; pkill -f 'canopy-box serve --home-id ${name#canopy-}'" >/dev/null 2>&1 || true
        on_host "tmux -u -L $name kill-server; rm -f \"\${TMUX_TMPDIR:-/tmp}/tmux-\$(id -u)/$name\"" >/dev/null 2>&1 || true
        # The throwaway home's own files on the host, which no other home uses.
        [[ "$name" =~ ^canopy-[0-9a-f]{8}$ ]] && on_host "rm -rf ~/.canopy/${name#canopy-}" >/dev/null 2>&1 || true
    done
    # A run that failed before row rm leaves its worktrees, whose clone goes with the throwaway folder below.
    on_host 'cd ~/.canopy/worktrees/demo 2>/dev/null && rm -rf e2e-remote e2e-other e2e-second && cd .. && rmdir demo' \
        >/dev/null 2>&1 || true
    # The fake host's tmux server can outlive kill-server once its folder goes, so it is stopped by its config's path.
    if [[ -n "${host_home:-}" ]]; then pkill -9 -f "tmux -u -L canopy-[0-9a-f]* -f $host_home/" 2>/dev/null || true; fi
    on_host "rm -rf '$host_dir'" >/dev/null 2>&1 || true
    rm -rf "$work" ${host_home:+"$host_home"}
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
    [[ -n "$pid" ]] || fail "the app is not running, or did not say its pid"
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
# The master's control socket is named after this home's id, in the home or, when that is too long, in /tmp.
control_socket() {
    { ls "$CANOPY_HOME"/ssh/"${server#canopy-}"-* /tmp/canopy-"$(id -u)"/"${server#canopy-}"-* 2>/dev/null || true; } |
        grep -Ev '\.(env|links)$' | head -1
}
master_gone() { ! "${CANOPY_SSH:-/usr/bin/ssh}" -S "$control" -O check "$alias" >/dev/null 2>&1; }
connections() { "$cli" log --type host.connected --json | json 'len(d)'; }
connected_again() { (($(connections) > before)); }

step "a throwaway repo here, and its clone on $alias"
git init -q -b main "$work/demo"
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
on_host "set -e; mkdir -p '$host_dir/out'; git init -q --bare -b main '$host_dir/origin.git'; \
    git clone -q '$host_dir/origin.git' '$host_dir/demo' 2>/dev/null; \
    git -C '$host_dir/demo' -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init; \
    git -C '$host_dir/demo' push -q origin main; git -C '$host_dir/demo' remote set-head origin main"

step "host add checks the host and installs Canopy's files"
launch
"$cli" repo add "$work/demo" >/dev/null
# Kept on the Mac's relay at first, so the relay's own steps run, and canopy-box takes the host later on.
"$cli" host add "$alias" --repo "demo=$host_dir/demo" --no-box >/dev/null
server=$("$cli" host list --json | json '[h["tmuxServer"] for h in d if h["alias"] == "'"$alias"'"][0]')
[[ "$(host_state)" == connected ]] || fail "the host is $(host_state), not connected"
on_host "test -x ~/.canopy/${server#canopy-}/bin/canopy-host" || fail "canopy-host is not on the host"
on_host 'grep -q agent-hook "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"' ||
    fail "host add did not install Canopy's hooks in the host's Claude Code settings"
if "$cli" host add "$alias" --repo "demo=$host_dir/nowhere" 2>/dev/null; then fail "a missing clone was accepted"; fi

step "row new --on makes the worktree on the host and runs --run in its tmux session"
"$cli" row new "e2e/remote" --repo demo --on "$alias" --run 'echo remote-$((40 + 2))' >/dev/null
pane=$("$cli" term list --json | json '[t["pane"] for t in d if t["row"] == "e2e/remote"][0]')
wait_for 60 screen_has remote-42 || fail "--run did not reach the host"
remote=$("$cli" row list --json | json '[r["remotePath"] for r in d if r.get("branch") == "e2e/remote"][0]')
on_host "test \"\$(git -C '$remote' rev-parse --abbrev-ref HEAD)\" = e2e/remote" || fail "no worktree at $remote"
on_host "tmux -u -L $server has-session -t =$pane" || fail "no tmux session named $pane"
session=$pane
created_at() { on_host "tmux -u -L $server display-message -p -t '=$session:' '#{session_created}'"; }
session_count() { on_host "tmux -u -L $server list-sessions" | wc -l | tr -d ' '; }
started=$(created_at)

step "term send types into it, and the host reports its folder"
"$cli" term send "$pane" "cd /tmp && echo sent-\$((1 + 1))" --enter >/dev/null
wait_for 30 screen_has sent-2 || fail "term send did not reach the host"
folder_is_tmp() { "$cli" term list --json | json '[t["folder"] for t in d if t["pane"] == "'"$pane"'"][0]' | grep -Eqx '(/private)?/tmp'; }
wait_for 20 folder_is_tmp || fail "term list does not show the host's folder"

# The line typed for a command run in the remote pane's shell, as a person would type it. Its output and exit status
# go to files on the host, so nothing depends on reading them back off the screen.
typed() { # name, command
    local out="'$host_dir/out/$1'" status="'$host_dir/out/$1.status'"
    printf '{ %s; } > %s 2>&1; echo $? > %s.new && mv %s.new %s' "$2" "$out" "$status" "$status" "$status"
}
finished() { wait_for 60 on_host "test -f '$host_dir/out/$1.status'" || fail "$1 did not finish on the host"; }
in_pane() { # name, command
    "$cli" term send "$pane" "$(typed "$1" "$2")" --enter >/dev/null
    finished "$1"
}
output_of() { on_host "cat '$host_dir/out/$1'"; }
status_of() { on_host "cat '$host_dir/out/$1.status'"; }
quoted() { local text=${1//\'/\'\\\'\'}; printf "'%s'" "$text"; }
in_session() { # name, command: typed into the pane's session on the host itself, for while no pane shows it
    local target
    target=$(quoted "=$session:")
    on_host "tmux -u -L $server send-keys -t $target -l -- $(quoted "$(typed "$1" "$2")") &&
        tmux -u -L $server send-keys -t $target Enter"
    finished "$1"
}
succeeded() { [[ "$(status_of "$1")" == 0 ]] || fail "$1 exited with $(status_of "$1"): $(output_of "$1")"; }
agent_state() {
    "$cli" term list --json | json 'next(t.get("agent", "none") for t in d if t["pane"] == "'"$pane"'")'
}
hook_report() { # Stop's last message
    local event='{"session_id": "e2e", "hook_event_name": "Stop", "last_assistant_message": "'"$1"'"}'
    printf "printf '%%s' '%s' | canopy agent-hook" "$event"
}

step "in the remote pane, canopy lists the rows and the pane"
in_pane rows "cd '$remote' && canopy row list"
succeeded rows
output_of rows | grep -q "e2e/remote" || fail "canopy row list on the host does not list e2e/remote: $(output_of rows)"
in_pane terms "canopy term list"
succeeded terms
output_of terms | grep -q "^$pane " || fail "canopy term list on the host does not list $pane: $(output_of terms)"
in_pane loop "printf 'a\\nb\\nc\\n' | while read x; do canopy row list >/dev/null; echo got \$x; done"
succeeded loop
[[ "$(output_of loop | tr '\n' ' ')" == "got a got b got c " ]] ||
    fail "canopy in a loop over lines took the loop's input: $(output_of loop)"

step "a hook's report in the remote pane shows as the pane's agent state"
in_pane hook "$(hook_report 'Tests pass. Should I push it?')"
succeeded hook
[[ -z "$(output_of hook)" ]] || fail "agent-hook printed something: $(output_of hook)"
wait_for 10 eval '[[ "$(agent_state)" == waiting ]]' || fail "the pane's agent is $(agent_state), not waiting"
background='{"session_id": "e2e", "hook_event_name": "Stop", "last_assistant_message": "It runs.", "background_tasks": [{"type": "shell", "status": "running", "command": "npm test"}]}'
in_pane background-hook "printf '%s' '$background' | canopy agent-hook"
succeeded background-hook
# One read for both: the host's probe can clear the agent soon after, once it sees the hook's command has exited.
background_work() {
    "$cli" term list --json |
        json 'next((t.get("agent"), t.get("backgroundTasks")) for t in d if t["pane"] == "'"$pane"'") == ("background", ["npm test"])' |
        grep -q True
}
wait_for 10 background_work || fail "the pane's agent is $(agent_state), and term list does not name its background work"

step "web open and xdg-open of an artifact link in the remote pane open pages in the remote row"
pages() { "$cli" web list --repo demo --row e2e/remote --json | json '" ".join(p["url"] for p in d)'; }
in_pane web "canopy web open https://example.com/e2e"
succeeded web
[[ "$(pages)" == *"https://example.com/e2e"* ]] || fail "web open did not open the page in e2e/remote: $(pages)"
# The artifact takes the panel's place, as a second web open does.
in_pane artifact "xdg-open https://claude.ai/artifact/e2e-artifact"
succeeded artifact
[[ "$(pages)" == *"https://claude.ai/artifact/e2e-artifact"* ]] || fail "xdg-open did not open the artifact: $(pages)"

step "row new typed in the remote pane makes a row on the same host"
in_pane second "canopy row new e2e/second"
succeeded second
second=$("$cli" row list --json | json '[r.get("remotePath", "") for r in d if r.get("branch") == "e2e/second"][0]')
[[ -n "$second" ]] || fail "row new on the host did not make a remote row: $(output_of second)"
on_host "test \"\$(git -C '$second' rev-parse --abbrev-ref HEAD)\" = e2e/second" || fail "no worktree at $second"
stand_in_second=$("$cli" row list --json | json '[r["path"] for r in d if r.get("branch") == "e2e/second"][0]')
"$cli" row rm "$stand_in_second" --force --delete-branch >/dev/null
on_host "test ! -e '$second'" || fail "the second row's worktree is still on the host"

step "a dev server typed in the remote pane is forwarded to this Mac, and answers from the host"
# Ports bound on both loopbacks and closed at once, which fails when either is taken.
binds='import socket, sys
for port in map(int, sys.argv[1:]):
    for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        s = socket.socket(family)
        s.bind((address, port))
        s.close()'
# Four ports in a row, free here and on the host, below both machines' ephemeral ranges, which start at 32768 on Linux
# and 49152 on macOS, so a run never meets the author's own servers: two servers, and the next port each can move to.
base=""
for _ in $(seq 1 50); do
    try=$((20000 + RANDOM % 12000))
    ports="$try $((try + 1)) $((try + 2)) $((try + 3))"
    # shellcheck disable=SC2086
    if /usr/bin/python3 -c "$binds" $ports 2>/dev/null && on_host "python3 -c '$binds' $ports" 2>/dev/null; then
        base=$try
        break
    fi
done
[[ -n "$base" ]] || fail "no four free ports in a row here and on the host"
on_host "mkdir -p '$www' && printf %s '$id-from-host' > '$www/marker'"
serve() { # port, address: in the remote pane's shell, in the background, so the pane's shell is its parent
    in_pane "serve-$1" "cd '$remote'; python3 -m http.server $1 --bind $2 --directory '$www' & true"
    succeeded "serve-$1"
}
serving() { on_host "pgrep -f 'http[.]server $1 --bind [^ ]* --directory $www' >/dev/null"; }
ports_json() { "$cli" ports list --all --json; }
# The Mac port canopy ports gives the remote row's port, empty while it has none.
mac_port() {
    ports_json | json 'next((str(p["localPort"]) for p in d if p["port"] == '"$1"' and p.get("host") == "'"$alias"'"
        and p["row"] == "e2e/remote" and p.get("localPort")), "")'
}
forwarded() { [[ -n "$(mac_port "$1")" ]]; }
listed() { ports_json | json 'any(p["port"] == '"$1"' for p in d)' | grep -qx True; }
from_host() { [[ "$(curl -s --max-time 5 "http://localhost:$1/marker")" == "$id-from-host" ]]; }
web=$base
serve "$web" ::1
wait_for 60 forwarded "$web" || fail "port $web on the host was not forwarded: $(ports_json)"
web_mac=$(mac_port "$web")
# The fake host is this Mac, where the server itself holds its port, so its forward takes the next one.
if [[ -z "$host_home" && "$web_mac" != "$web" ]]; then fail "port $web, free here, was forwarded to $web_mac"; fi
from_host "$web_mac" || fail "localhost:$web_mac did not answer from the host's server"

step "a port held on this Mac makes the forward take the next one"
held=$((base + 2))
# shellcheck disable=SC2016
(cd / && exec /usr/bin/python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_INET6)
s.bind(("::1", int(sys.argv[1])))
s.listen()
time.sleep(600)' "$held" "canopy-e2e-listener-$id" </dev/null >/dev/null 2>"$work/listener.err") &
listener=$!
disown
taken() { ! /usr/bin/python3 -c "$binds" "$1"; }
# A fresh python3 can wait 20 s or more for this Mac's endpoint security scanner under load, for the listener and for
# each check alike, so this waits well past that.
wait_for 120 taken "$held" || fail "the local listener did not take port $held ($(kill -0 "$listener" 2>/dev/null && echo running || echo exited): $(cat "$work/listener.err"))"
serve "$held" 127.0.0.1
wait_for 60 forwarded "$held" || fail "port $held on the host was not forwarded: $(ports_json)"
held_mac=$(mac_port "$held")
[[ "$held_mac" != "$held" ]] || fail "port $held was forwarded to the port this Mac's listener holds"
from_host "$held_mac" || fail "localhost:$held_mac did not answer from the host's server"

step "canopy ports stop with the Mac port, here, stops the server on the host"
stop_listener
"$cli" ports stop "$held_mac" --all >/dev/null || fail "ports stop $held_mac failed"
wait_for 10 eval '! serving "$held"' || fail "the server on port $held still runs on the host"
wait_for 30 eval '! listed "$held"' || fail "canopy ports still lists port $held: $(ports_json)"

step "canopy ports stop typed in the remote pane stops the server on the host, and its forward goes"
in_pane stop "canopy ports stop $web"
succeeded stop
output_of stop | grep -q "on port $web on $alias" || fail "ports stop said: $(output_of stop)"
wait_for 10 eval '! serving "$web"' || fail "the server on port $web still runs on the host"
wait_for 30 eval '! listed "$web"' || fail "canopy ports still lists port $web: $(ports_json)"
wait_for 30 eval '! curl -s --max-time 2 -o /dev/null "http://localhost:$web_mac/"' ||
    fail "localhost:$web_mac still answers after the server stopped"

step "a second home on the same host has its own tmux server, sessions, and files"
home2() { CANOPY_HOME="$work/home2" "$@"; }
CANOPY_HOME="$work/home2" launch
home2 "$cli" repo add "$work/demo" >/dev/null
home2 "$cli" host add "$alias" --repo "demo=$host_dir/demo" --no-box >/dev/null 2>&1
server2=$(home2 "$cli" host list --json | json '[h["tmuxServer"] for h in d if h["alias"] == "'"$alias"'"][0]')
[[ "$server2" != "$server" ]] || fail "both homes use the tmux server $server"
on_host "test -x ~/.canopy/${server2#canopy-}/bin/canopy-host && test -x ~/.canopy/${server#canopy-}/bin/canopy-host" ||
    fail "the homes do not each have their own canopy-host"
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

step "quitting and relaunching joins the same session, and replays a hook's report kept meanwhile"
"$cli" term send "$pane" "echo before-quit-\$((2 + 2))" --enter >/dev/null
wait_for 30 screen_has before-quit-4 || fail "the marker did not show"
control=$(control_socket)
[[ -n "$control" ]] || fail "no control socket for this home"
stop_app
# A master outlives a killed app by a moment, forwarding to a socket no one serves.
wait_for 20 master_gone || fail "the master outlived the app"
# The pane's ssh and the connection's forward went with the app, but the session runs on. The report is typed into the
# session on the host itself, so it runs in the session's shell with the session's variables, as Claude's hook would.
in_session hook-away "$(hook_report 'Done.')"
succeeded hook-away
[[ -z "$(output_of hook-away)" ]] || fail "agent-hook printed something with the app away: $(output_of hook-away)"
kept="~/.canopy/${server#canopy-}/pending/$session.json"
on_host "test -f $kept" || fail "agent-hook did not keep its report on the host while the app was away"
launch
"$cli" row select e2e/remote --repo demo >/dev/null
pane=$("$cli" term list --json | json '[t["pane"] for t in d if t["row"] == "e2e/remote"][0]')
[[ "$pane" == "$session" ]] || fail "the relaunched pane is $pane, not $session, which its session's CANOPY_PANE names"
wait_for 90 screen_has before-quit-4 || fail "the relaunched pane did not rejoin its session"
[[ "$(created_at)" == "$started" && "$(session_count)" == 1 ]] || fail "relaunching started another session"
wait_for 10 eval '[[ "$(agent_state)" == done ]]' || fail "the kept report did not show: the agent is $(agent_state)"
on_host "test ! -e $kept" || fail "the kept report is still on the host after the pane reattached"

step "a dropped connection reconnects to the same session"
control=$(control_socket)
[[ -n "$control" ]] || fail "no control socket for this home"
before=$(connections)
"${CANOPY_SSH:-/usr/bin/ssh}" -S "$control" -O exit "$alias" >/dev/null 2>&1 || true
wait_for 30 screen_has "reconnecting" || fail "the pane did not say it was reconnecting"
# Typed ahead while the pane reconnects, it reaches the session once ssh attaches, as in any terminal.
"$cli" term send "$pane" "echo ahead-\$((5 + 5))" --enter >/dev/null
wait_for 90 connected_again || fail "the host did not reconnect"
sleep 2
"$cli" term send "$pane" "echo after-drop-\$((3 + 3))" --enter >/dev/null
wait_for 60 screen_has after-drop-6 || fail "the pane did not come back after the drop"
[[ "$(created_at)" == "$started" && "$(session_count)" == 1 ]] || fail "the session after the drop is not the same one"
wait_for 60 screen_has ahead-10 || fail "keys typed while reconnecting were lost"

step "an idle host detaches, and Return reconnects"
"$cli" host add "$alias" --idle-detach 1 >/dev/null
wait_for 150 state_is detached || fail "the host did not detach"
wait_for 10 screen_has "can sleep. Press Return to reconnect" || fail "the pane does not say it detached"
"$cli" host add "$alias" --idle-detach 30 >/dev/null
"$cli" term send "$pane" "" --enter >/dev/null
wait_for 90 state_is connected || fail "Return did not reconnect"
"$cli" term send "$pane" "echo back-\$((4 + 4))" --enter >/dev/null
wait_for 60 screen_has back-8 || fail "the pane did not rejoin after Return"

if ((with_box)); then
    step "host upgrade hands the host to canopy-box, which takes the session as it runs"
    phone_port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    [[ "$alias" == fake-box ]] && on_host "mkdir -p ~/.canopy/${server#canopy-}/box && echo '127.0.0.1 $phone_port' > ~/.canopy/${server#canopy-}/box/phone-listen"
    "$cli" host upgrade "$alias" > "$work/upgrade.out" 2> "$work/upgrade.err" \
        || fail "host upgrade failed: $(cat "$work/upgrade.err")"
    box_sock="~/.canopy/${server#canopy-}/box/box.sock"
    on_host "test -S $box_sock" || fail "canopy-box does not listen on the host"
    [[ "$(created_at)" == "$started" && "$(session_count)" == 1 ]] \
        || fail "upgrading touched the session: made $(created_at), not $started, with $(session_count) sessions. Box state: $(on_host "cat ~/.canopy/${server#canopy-}/box/state.json"). Activity: $("$cli" log --json | json '" ".join(e["type"] for e in d[-15:])'). Processes: $(ps -Ao pid,command | grep -E "canopy-box|tmux -u -L $server" | grep -v grep)"
    "$cli" host list --json | json '[h["box"] for h in d if h["alias"] == "'"$alias"'"][0]' | grep -qx True \
        || fail "host list does not say the host is upgraded"

    step "a hook in the pane reaches canopy-box, and its agent shows here"
    in_pane hook-box "$(hook_report 'Over to you?')"
    succeeded hook-box
    wait_for 20 eval '[[ "$(agent_state)" == waiting ]]' || fail "the box's agent is $(agent_state), not waiting"

    if [[ "$alias" == fake-box ]]; then
        step "a phone pairs with canopy-box through the Mac, and reads and answers the box's agent"
        phone="/usr/bin/python3 -I $PWD/scripts/phone-client.py"
        "$cli" phone pair --on "$alias" --json > "$work/pair.json" || fail "phone pair --on failed"
        link=$(json 'd["link"]' < "$work/pair.json")
        case "$link" in *kind=box*) ;; *) fail "the box's pairing link does not say it is a box: $link" ;; esac
        $phone pair "$link" e2e-phone "$work/box-token" > "$work/box-paired.json" \
            || fail "the phone could not pair with canopy-box"
        [ "$(json 'd["kind"]' < "$work/box-paired.json")" = box ] || fail "canopy-box does not tell the phone it is a box"
        $phone wait-inbox "$link" "$work/box-token" "any(a['pane'] == '$session' and a['state'] == 'waiting' for r in inbox['rows'] for a in r['agents'])" 20 >/dev/null \
            || fail "the box's inbox does not show the waiting pane"
        $phone call "$link" "$work/box-token" phone.reply '{"pane": "'"$session"'", "text": "from-phone"}' >/dev/null \
            || fail "the phone's reply to the box was refused"
        wait_for 20 screen_has from-phone || fail "the phone's reply did not reach the box's pane"
        step "a wake key reaches the phone with the instance canopy-box reads from the instance metadata service"
        (exec /usr/bin/python3 -I "$PWD/scripts/fake-aws.py" --port-file "$work/aws.port" --lifetime 600 \
            </dev/null >/dev/null 2>&1) &
        aws_pid=$!
        wait_for 10 test -s "$work/aws.port" || fail "the fake instance metadata service did not start"
        on_host "echo '127.0.0.1 $(cat "$work/aws.port")' > ~/.canopy/${server#canopy-}/box/imds"
        printf 'AKIAFAKEWAKEKEY\nwake-secret-e2e\n' | "$cli" host wake-key "$alias" >/dev/null || fail "host wake-key failed"
        wake_instance() {
            $phone hello-json "$link" "$work/box-token" | json '(d.get("wake") or {}).get("instanceID", "")'
        }
        wait_for 20 eval '[[ "$(wake_instance)" == i-0fake0box00000001 ]]' \
            || fail "the phone's hello does not carry the wake key: $($phone hello-json "$link" "$work/box-token")"
        if grep -rq wake-secret-e2e "$CANOPY_HOME/activity" 2>/dev/null \
            || on_host "grep -q wake-secret-e2e ~/.canopy/${server#canopy-}/box/activity.jsonl" 2>/dev/null; then
            fail "the wake key's secret was logged"
        fi
        "$cli" host wake-key "$alias" --clear >/dev/null || fail "host wake-key --clear failed"
        wait_for 20 eval '[[ -z "$(wake_instance)" ]]' || fail "a cleared wake key still reaches the phone"
        [[ "$(ps -o command= -p "$aws_pid" 2>/dev/null)" == *fake-aws.py* ]] && kill "$aws_pid"
        step "a task from the phone makes a row on the box running the command the Mac set, with the brief whole"
        "$cli" phone agent --on "$alias" "printf '%s|' > '$work/box-task.out'" >/dev/null \
            || fail "phone agent --on could not set the box's command"
        box_agent() { $phone hello-json "$link" "$work/box-token" | json 'd.get("agentCommand", "")'; }
        wait_for 20 eval '[[ "$(box_agent)" == *box-task.out* ]]' \
            || fail "the box's hello does not carry the command: $(box_agent)"
        /usr/bin/python3 - "$work" <<'PY'
import json, sys
brief = "Fix it's \"login\" $(touch pwned) `touch pwned`\nand then $HOME\u0015touch pwned\r\tdone"
open(sys.argv[1] + "/box-brief.txt", "w").write(brief)
json.dump({"repo": "demo", "branch": "e2e/box-task", "brief": brief}, open(sys.argv[1] + "/box-task.json", "w"))
PY
        $phone call "$link" "$work/box-token" phone.newRow "$(cat "$work/box-task.json")" > "$work/box-task-made.json" \
            || fail "phone.newRow on the box failed: $(cat "$work/box-task-made.json")"
        box_task_row=$(json 'd["path"]' < "$work/box-task-made.json")
        box_task_ran() { [[ "$(cat "$work/box-task.out" 2>/dev/null)" == "$(cat "$work/box-brief.txt")|" ]]; }
        wait_for 20 box_task_ran || fail "the box's agent did not get the brief whole: $(cat "$work/box-task.out" 2>/dev/null)"
        on_host "test ! -e '$box_task_row/pwned'" || fail "the brief ran in the box's shell"
        box_task_here() { "$cli" row list --json | json '[r["path"] for r in d if r.get("branch") == "e2e/box-task"][0]'; }
        wait_for 30 box_task_here || fail "the row the phone made on the box does not show here"
        "$cli" phone remove e2e-phone --on "$alias" >/dev/null || fail "phone remove --on failed"
        [[ "$($phone hello "$link" "$work/box-token")" != ok ]] || fail "a removed phone still says hello to the box"
    fi

    step "row new --run in the pane makes a row on the box, whose pane shows here as a tab"
    box_sessions() { on_host "tmux -u -L $server list-sessions -F '#{session_name}'" | grep -c '^b' || true; }
    sessions_on_box=$(box_sessions)
    in_pane row-box "canopy row new e2e/boxed --run 'echo boxed-\$((6 * 7))'"
    succeeded row-box
    boxed_row() { "$cli" row list --json | json '[r["path"] for r in d if r.get("branch") == "e2e/boxed"][0]'; }
    wait_for 30 boxed_row || fail "the row made on the box does not show here"
    boxed_pane() { "$cli" term list --all --json | json '[t["pane"] for t in d if t["row"] == "e2e/boxed"][0]'; }
    wait_for 30 boxed_pane || fail "the box's pane does not show here as a tab"
    "$cli" row select e2e/boxed --repo demo >/dev/null
    boxed_says() { "$cli" term read "$(boxed_pane)" --lines 50 | grep -q boxed-42; }
    wait_for 60 boxed_says || fail "the box's pane did not run its command"
    boxed_session=$("$cli" term list --all --json | json '[t["pane"] for t in d if t["row"] == "e2e/boxed"][0]')
    [[ "$(box_sessions)" == $((sessions_on_box + 1)) ]] \
        || fail "the box has $(box_sessions) panes of its own, not $((sessions_on_box + 1))"
    "$cli" term close "$boxed_session" --force >/dev/null || fail "the box's pane could not be closed here"
    box_pane_gone() { [[ "$(box_sessions)" == "$sessions_on_box" ]]; }
    wait_for 20 box_pane_gone || fail "closing the box's pane here did not end its session on the host"

    step "host upgrade --undo gives the host back, and hooks reach this Mac again"
    sessions_before=$(session_count)
    "$cli" host upgrade "$alias" --undo >/dev/null 2> "$work/undo.err" || fail "--undo failed: $(cat "$work/undo.err")"
    stopped() { ! on_host "test -S $box_sock"; }
    wait_for 20 stopped || fail "canopy-box still listens after --undo"
    [[ "$(created_at)" == "$started" && "$(session_count)" == "$sessions_before" ]] \
        || fail "--undo touched the sessions: $(session_count), not $sessions_before"
    in_pane hook-undo "$(hook_report 'Done.')"
    succeeded hook-undo
    wait_for 20 eval '[[ "$(agent_state)" == done ]]' || fail "after --undo the agent is $(agent_state), not done"
    "$cli" row rm e2e/boxed --repo demo --force --delete-branch >/dev/null || fail "the box's row could not be removed"
    if [[ "$alias" == fake-box ]]; then
        "$cli" row rm e2e/box-task --repo demo --force --delete-branch >/dev/null \
            || fail "the row the phone made on the box could not be removed"
    fi
fi

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

if ((with_box)); then
    step "host add runs canopy-box on a new host from the start, and host rm stops it"
    "$cli" host add "$alias" --repo "demo=$host_dir/demo" > "$work/readd.out" 2> "$work/readd.err" \
        || fail "host add failed: $(cat "$work/readd.err")"
    "$cli" host list --json | json '[h["box"] for h in d if h["alias"] == "'"$alias"'"][0]' | grep -qx True \
        || fail "a new host is not upgraded: $(cat "$work/readd.err")"
    on_host "test -S $box_sock" || fail "canopy-box does not listen on the new host"
    "$cli" host rm "$alias" >/dev/null 2> "$work/rm.err" || fail "host rm failed: $(cat "$work/rm.err")"
    [[ ! -s "$work/rm.err" ]] || fail "host rm warned: $(cat "$work/rm.err")"
    box_stopped() { ! on_host "test -S $box_sock"; }
    wait_for 20 box_stopped || fail "canopy-box still listens after host rm"
fi

echo
echo "e2e-hosts passed against $alias"
