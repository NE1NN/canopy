#!/usr/bin/env bash
# A dev build for the iPhone app to pair with over loopback, in place of Tailscale, on a throwaway home: a canopy repo
# with rows whose agents are in every state the inbox shows, and a ticket row from a stand-in ticket-manager. Each agent
# is scripts/fake-claude.py, which writes Claude Code's transcript format and reports through canopy agent-hook, so
# replies and answers from the phone land as they would with Claude Code: a question, a permission prompt, done,
# working, background, and an idle row. Nothing outside the throwaway folder is touched.
# A second server for the phone is a box: a fake host, this Mac through scripts/fake-ssh under a throwaway home, named
# devbox, upgraded to canopy-box, with a repo and a done agent of its own. PHONE_FIXTURE_BOX=0 leaves it out.
#
#   scripts/phone-fixture.sh start   launch it; prints the ports it listens on (PHONE_FIXTURE_PORT and
#                                    PHONE_FIXTURE_BOX_PORT pick them)
#   scripts/phone-fixture.sh link    a fresh pairing link; `link box` for the box
#   scripts/phone-fixture.sh ec2     the fake EC2 endpoint that wakes the box, which has a wake key
#   scripts/phone-fixture.sh stop-box, start-box   stop the box's canopy-box, as when it powers off, and start it
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
        # Disconnecting deletes this home's token from the Keychain, and clearing the box's wake key its key.
        "$cli" ticket disconnect --force >/dev/null 2>&1 || true
        "$cli" host wake-key devbox --clear >/dev/null 2>&1 || true
        kill "$pid" 2>/dev/null || true
        # The app writes to its home as it quits, so the folder goes only once it has.
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
    if [[ -n "${tm_pid:-}" && "$(ps -p "$tm_pid" -o command= 2>/dev/null)" == *ticket-manager-stand-in.py* ]]; then
        kill "$tm_pid" 2>/dev/null || true
    fi
    if [[ -n "${aws_pid:-}" && "$(ps -p "$aws_pid" -o command= 2>/dev/null)" == *fake-aws.py* ]]; then
        kill "$aws_pid" 2>/dev/null || true
    fi
    # The box's daemon and tmux server, found by this fixture's own host home and home id.
    if [[ "${host_home:-}" == /tmp/cnp-box.* && -n "${box_id:-}" ]]; then
        pkill -f "canopy-box serve --home-id $box_id" 2>/dev/null || true
        pkill -9 -f "tmux -u -L canopy-$box_id" 2>/dev/null || true
        rm -rf "$host_home"
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
    on=()
    [[ "${2:-}" == box ]] && on=(--on devbox)
    "$cli" phone pair ${on[@]+"${on[@]}"} --json | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["link"])'
    exit 0
    ;;
ec2)
    load
    echo "http://127.0.0.1:$(cat "$work/aws.port")/"
    exit 0
    ;;
stop-box)
    load
    pkill -f "canopy-box serve --home-id $box_id" || true
    exit 0
    ;;
start-box)
    load
    FAKE_SSH_HOME="$host_home" FAKE_SSH_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" scripts/fake-ssh -- devbox \
        "nohup ~/.canopy/$box_id/bin/canopy-box serve --home-id $box_id </dev/null >/dev/null 2>&1 &"
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
free_port() { /usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
port=${PHONE_FIXTURE_PORT:-$(free_port)}
box=${PHONE_FIXTURE_BOX:-1}
box_port=${PHONE_FIXTURE_BOX_PORT:-$(free_port)}
host_home=""
if ((box)); then
    command -v tmux >/dev/null || [[ -x /opt/homebrew/bin/tmux ]] || { echo "the box needs tmux: brew install tmux" >&2; exit 1; }
    # Short, so the box's sockets stay under macOS's 104 bytes.
    host_home=$(mktemp -d /tmp/cnp-box.XXXXXX)
    export CANOPY_SSH="$PWD/scripts/fake-ssh" FAKE_SSH_HOME="$host_home"
    export FAKE_SSH_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    mkdir -p "$host_home/.fake-ssh-bin" "$host_home/transcripts"
    ln -s "$PWD/scripts/fake-ss" "$host_home/.fake-ssh-bin/ss"
    touch "$host_home/.fake-ss-home-only"
    # The fake host is this Mac, so it runs canopy-box built for macOS.
    swift build --product canopy-box >/dev/null
    export CANOPY_BOX_BINARY="$(swift build --show-bin-path)/canopy-box"
fi
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
printf 'pid=%s\nwork=%s\ntm_pid=%s\nport=%s\nhost_home=%s\nbox_port=%s\n' "$!" "$work" "$tm_pid" "$port" \
    "$host_home" "$box_port" > "$state"
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

if ((box)); then
    git init -q -b main "$work/solis"
    git -C "$work/solis" -c user.email=fixture@example.com -c user.name=fixture commit -q --allow-empty -m init
    git clone -q "$work/solis" "$host_home/solis"
    "$cli" repo add "$work/solis" >/dev/null
    "$cli" host add devbox --repo "solis=$host_home/solis" >/dev/null
    box_id=$("$cli" host list --json | /usr/bin/python3 -c \
        'import json, sys; print([h["tmuxServer"] for h in json.load(sys.stdin) if h["alias"] == "devbox"][0])')
    box_id=${box_id#canopy-}
    printf 'box_id=%s\n' "$box_id" >> "$state"
    mkdir -p "$host_home/.canopy/$box_id/box"
    echo "127.0.0.1 $box_port" > "$host_home/.canopy/$box_id/box/phone-listen"
    # The box's instance metadata and EC2, whose StartInstances starts the box's daemon again.
    (exec /usr/bin/python3 -I scripts/fake-aws.py --port-file "$work/aws.port" --log "$work/aws.log" \
        --on-start "$PWD/scripts/phone-fixture.sh start-box" </dev/null >/dev/null 2>&1) &
    printf 'aws_pid=%s\n' "$!" >> "$state"
    for _ in $(seq 1 100); do
        [[ -s "$work/aws.port" ]] && break
        sleep 0.1
    done
    echo "127.0.0.1 $(cat "$work/aws.port")" > "$host_home/.canopy/$box_id/box/imds"
    "$cli" host upgrade devbox >/dev/null
    printf 'AKIAFAKEWAKEKEY\nfixture-wake-secret\n' | "$cli" host wake-key devbox >/dev/null
    # New task on the box runs the stand-in, which starts on the brief; each pane writes a transcript of its own.
    "$cli" phone agent --on devbox "clear; exec /usr/bin/python3 -I $(printf %q "$PWD/scripts/fake-claude.py") \
$(printf %q "$host_home/.local/bin/canopy") task $(printf %q "$host_home/transcripts")/task-\$\$.jsonl" >/dev/null
    run=$(printf 'clear; exec /usr/bin/python3 -I %q %q migrate %q' "$PWD/scripts/fake-claude.py" \
        "$host_home/.local/bin/canopy" "$host_home/transcripts/migrate.jsonl")
    "$cli" row new feat/usage-migration --repo solis --on devbox --run "$run" >/dev/null
fi

echo "listening on 127.0.0.1:$port$( ((box)) && echo ", the box on 127.0.0.1:$box_port"), CANOPY_HOME=$CANOPY_HOME"
