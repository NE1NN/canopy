#!/usr/bin/env bash
# Drives a real Claude Code (Haiku) in a dev build's pane through the phone listener, with scripts/phone-claude-e2e.py
# standing in for the iPhone app: the trust dialog, a long reply, an AskUserQuestion, and permission prompts allowed and
# denied. It uses the Claude Code login and settings of whoever runs it, so it is not part of CI; run it after make app.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v claude >/dev/null 2>&1; then
    echo "e2e-phone-claude skipped: Claude Code is not installed"
    exit 0
fi

app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
work=$(mktemp -d -t canopy-claude)
export CANOPY_HOME="$work/home"
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH CANOPY_PLUGIN CANOPY_ITEM CANOPY_HOST CLAUDE_CONFIG_DIR
port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
export CANOPY_PHONE_LISTEN="127.0.0.1:$port"

app_pid() {
    "$cli" status --json 2>/dev/null | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("pid", ""))' || true
}

cleanup() {
    local pid
    pid=$(app_pid)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    # Claude Code's transcripts of this run, under the throwaway folder's name.
    local projects
    projects="$HOME/.claude/projects/$(printf '%s' "$(cd "$work" && pwd -P)/demo" | tr '/.' '--')"
    [[ "$projects" == *canopy-claude* ]] && rm -rf "$projects"
    rm -rf "$work"
}
trap cleanup EXIT

git init -q -b main "$work/demo"
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
"$cli" repo add "$work/demo" >/dev/null
link=$("$cli" phone pair --json | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["link"])')
/usr/bin/python3 -I scripts/phone-client.py pair "$link" "e2e iPhone" "$work/token" >/dev/null
pane=$("$cli" term new --repo demo --row main --run "claude --model haiku --permission-mode default" --json |
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
echo "Claude Code runs in $pane, in $work/demo"
/usr/bin/python3 -I scripts/phone-claude-e2e.py "$link" "$work/token" "$pane" "$work/demo"
