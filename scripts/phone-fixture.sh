#!/usr/bin/env bash
# A dev build for the iPhone app to pair with over loopback, in place of Tailscale, on a throwaway home: a canopy repo
# with rows whose agents are in every state the inbox shows, and a ticket row from a stand-in ticket-manager. Each agent
# is scripts/fake-claude.py, which writes Claude Code's transcript format and reports through canopy agent-hook, so
# replies and answers from the phone land as they would with Claude Code: a question, a permission prompt, done,
# working, background, and an idle row. Nothing outside the throwaway folder is touched.
#
#   scripts/phone-fixture.sh start   launch it; prints the port it listens on (PHONE_FIXTURE_PORT picks it)
#   scripts/phone-fixture.sh link    a fresh pairing link
#   scripts/phone-fixture.sh panes   each scenario's pane, as JSON
#   scripts/phone-fixture.sh calls   what phones did to its panes, from the activity log
#   scripts/phone-fixture.sh stop    quit it and delete its folder
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
state="$PWD/build/phone-fixture.env"

load() {
    [[ -f "$state" ]] || { echo "phone-fixture is not running" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$state"
    export CANOPY_HOME="$work/home"
}

case "${1:-start}" in
stop)
    [[ -f "$state" ]] || exit 0
    load
    # Only the dev build this script started: a pid can be reused once that app has quit.
    if [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == *"Canopy Dev.app/Contents/MacOS/Canopy" ]]; then
        # Disconnecting deletes this home's token from the Keychain.
        "$cli" ticket disconnect --force >/dev/null 2>&1 || true
        kill "$pid" 2>/dev/null || true
        # The app writes to its home as it quits, so the folder goes only once it has.
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
    if [[ -n "${tm_pid:-}" && "$(ps -p "$tm_pid" -o command= 2>/dev/null)" == *ticket-manager-stand-in.py* ]]; then
        kill "$tm_pid" 2>/dev/null || true
    fi
    if [[ "$(basename "$work")" != cnphone.* || ! -d "$work/home" ]]; then
        echo "not deleting $work: it does not look like a phone fixture folder" >&2
        exit 1
    fi
    rm -rf "$work"
    rm -f "$state"
    exit 0
    ;;
link)
    load
    "$cli" phone pair --json | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["link"])'
    exit 0
    ;;
panes)
    load
    cat "$work/panes.json"
    exit 0
    ;;
calls)
    load
    "$cli" log --type phone.call --json
    exit 0
    ;;
start) ;;
*)
    echo "usage: scripts/phone-fixture.sh [start|link|panes|calls|stop]" >&2
    exit 2
    ;;
esac

[[ -x "$cli" ]] || { echo "build the dev app first: make app" >&2; exit 1; }
[[ -f "$state" ]] && "$0" stop
work=$(mktemp -d -t cnphone)
export CANOPY_HOME="$work/home"
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH CANOPY_PLUGIN CANOPY_ITEM CANOPY_HOST
# PHONE_FIXTURE_PORT starts it again where a phone already knows to look, as when a Mac restarts.
port=${PHONE_FIXTURE_PORT:-$(/usr/bin/python3 -c \
    'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}
mkdir -p "$work/transcripts" "$work/zdot" "$work/claude"

# A plain prompt, whatever the author's own zsh setup prints.
printf "PROMPT='%%F{8}\$%%f '\nunsetopt PROMPT_SP\n" > "$work/zdot/.zshrc"

git init -q -b main "$work/canopy"
git -C "$work/canopy" -c user.email=fixture@example.com -c user.name=fixture commit -q --allow-empty -m init

# A stand-in ticket-manager, as scripts/ui-fixture.sh runs it. It stops after four hours if `stop` never runs.
/usr/bin/python3 scripts/ticket-manager-stand-in.py seed --fixtures Tests/CanopyTicketsTests/Fixtures/canopy-api \
    --out "$work/tm" --ui
(exec /usr/bin/python3 scripts/ticket-manager-stand-in.py serve --data "$work/tm" --token phone-fixture-token \
    --port-file "$work/tm/port" --log "$work/tm/requests.log" --lifetime 14400 </dev/null >/dev/null 2>&1) &
tm_pid=$!
for _ in $(seq 1 100); do
    [[ -f "$work/tm/port" ]] && break
    sleep 0.1
done

(CANOPY_PHONE_LISTEN="127.0.0.1:$port" CLAUDE_CONFIG_DIR="$work/claude" ZDOTDIR="$work/zdot" SHELL=/bin/zsh \
    CANOPY_TRASH_FOLDER="$work/trash" exec "$app/Contents/MacOS/Canopy" </dev/null >/dev/null 2>&1) &
# Written at once, so `stop` can clean up even if a later step fails. The subshell execs, so $! is the app.
printf 'pid=%s\nwork=%s\ntm_pid=%s\nport=%s\n' "$!" "$work" "$tm_pid" "$port" > "$state"
for _ in $(seq 1 100); do
    [[ -S "$CANOPY_HOME/canopy.sock" ]] && break
    sleep 0.1
done

"$cli" repo add "$work/canopy" >/dev/null
for row in fix/port-scan-drain fix/control-lost-requests feat/port-labels feat/ios-companion fix/hand-checks; do
    "$cli" row new "$row" --repo canopy >/dev/null
done
printf 'phone-fixture-token' | "$cli" ticket connect "http://127.0.0.1:$(cat "$work/tm/port")" \
    --web 'https://tickets.example.com/tickets/{id}' >/dev/null
"$cli" ticket new 853 >/dev/null

agent() {
    local scenario=$1
    shift
    local run
    run=$(printf 'clear; exec /usr/bin/python3 -I %q %q %q %q' "$PWD/scripts/fake-claude.py" "$cli" "$scenario" \
        "$work/transcripts/$scenario.jsonl")
    "$cli" term new "$@" --run "$run" --json |
        /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])'
}
ticket_row=$("$cli" row list --json | /usr/bin/python3 -c \
    'import json, sys; print([r["path"] for r in json.load(sys.stdin) if r.get("plugin")][0])')
{
    printf '{'
    printf '"drain": "%s", ' "$(agent drain --row fix/port-scan-drain --repo canopy)"
    printf '"lost": "%s", ' "$(agent lost --row fix/control-lost-requests --repo canopy)"
    printf '"labels": "%s", ' "$(agent labels --row feat/port-labels --repo canopy)"
    printf '"companion": "%s", ' "$(agent companion --row feat/ios-companion --repo canopy)"
    printf '"ticket": "%s", ' "$(agent ticket --row "$ticket_row")"
    printf '"main": "%s"' "$(agent main --row main --repo canopy)"
    printf '}\n'
} > "$work/panes.json"

echo "listening on 127.0.0.1:$port, CANOPY_HOME=$CANOPY_HOME"
