#!/usr/bin/env bash
# Drives a dev build the way the iPhone app will, with scripts/phone-client.py standing in for the phone, against a
# throwaway CANOPY_HOME. The dev build listens on loopback through CANOPY_PHONE_LISTEN in place of Tailscale.
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
phone="/usr/bin/python3 -I $PWD/scripts/phone-client.py"
work=$(mktemp -d -t canopy-phone)
export CANOPY_HOME="$work/home"
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH CANOPY_PLUGIN CANOPY_ITEM CANOPY_HOST
export CLAUDE_CONFIG_DIR="$work/claude"
port=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
export CANOPY_PHONE_LISTEN="127.0.0.1:$port"

app_pid() {
    "$cli" status --json 2>/dev/null | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("pid", ""))' || true
}

hold_pid=""
cleanup() {
    local pid
    [[ -n "$hold_pid" ]] && kill "$hold_pid" 2>/dev/null || true
    pid=$(app_pid)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "a repo with a row, and the dev build listening on loopback"
git init -q -b main "$work/demo"
git -C "$work/demo" -c user.email=e2e@example.com -c user.name=e2e commit -q --allow-empty -m init
"$cli" repo add "$work/demo" >/dev/null
"$cli" row new feat/phone --repo demo >/dev/null
"$cli" phone status | tee "$work/status.txt"
grep -qx "Listening for phones on 127.0.0.1:$port." "$work/status.txt" || fail "phone status did not say where it listens"
grep -qx "No phones are paired. Run canopy phone pair to pair one." "$work/status.txt" || fail "phone status counted phones"

step "a phone pairs with the code from canopy phone pair"
"$cli" phone pair --json > "$work/pair.json"
link=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["link"])' "$work/pair.json")
[[ "$link" == "canopy-phone://pair?host=127.0.0.1&port=$port&code="* ]] || fail "the link is $link"
$phone pair "$link" "e2e iPhone" "$work/token" | tee "$work/paired.json"
grep -q '"phone": "e2e iPhone"' "$work/paired.json" || fail "the phone did not pair"
"$cli" phone list | grep -q "^e2e iPhone " || fail "phone list does not show the phone"

step "the code works once"
if $phone pair "$link" "again" "$work/token2" > "$work/again.json"; then fail "the code paired twice"; fi
grep -q '"bad_pairing_code"' "$work/again.json" || fail "a used code was not bad_pairing_code"

step "a wrong token is unpaired"
echo "not-a-token" > "$work/wrong"
[[ "$($phone hello "$link" "$work/wrong")" == "unpaired" ]] || fail "a wrong token said hello"
[[ "$($phone hello "$link" "$work/token")" == "ok" ]] || fail "the paired phone could not say hello"

step "the phone may not call methods off its list"
for method in row.remove repo.remove term.send hooks.install; do
    if $phone call "$link" "$work/token" "$method" > "$work/refused.json"; then fail "$method was allowed"; fi
    grep -q '"method_not_allowed"' "$work/refused.json" || fail "$method was not method_not_allowed"
done

step "phone.rows lists the repo's rows"
$phone call "$link" "$work/token" phone.rows > "$work/rows.json"
/usr/bin/python3 - "$work/rows.json" <<'PY' || fail "phone.rows did not list main and feat/phone"
import json, sys
sections = json.load(open(sys.argv[1]))["sections"]
assert [s["name"] for s in sections] == ["demo"], sections
assert [r["name"] for r in sections[0]["rows"]] == ["main", "feat/phone"], sections
assert sections[0]["rows"][0]["isMain"] is True
PY

step "the inbox follows an agent's state"
pane=$("$cli" term new --row feat/phone --repo demo --json | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["pane"])')
$phone wait-inbox "$link" "$work/token" \
    "any(a['pane'] == '$pane' and a['state'] == 'waiting' for r in inbox['rows'] for a in r['agents'])" 20 \
    > "$work/inbox.json" &
waiter=$!
sleep 1
"$cli" term state "$pane" waiting >/dev/null
wait "$waiter" || fail "the inbox never showed $pane waiting"
"$cli" term state "$pane" done >/dev/null
$phone wait-inbox "$link" "$work/token" \
    "any(a['pane'] == '$pane' and a['state'] == 'done' and a['unseen'] for r in inbox['rows'] for a in r['agents'])" 20 \
    >/dev/null || fail "the inbox never showed $pane done and unseen"

step "a task from the phone makes a row here running the Mac's agent command with the brief whole"
"$cli" phone agent | grep -q "the standard command" || fail "phone agent does not say the standard command runs"
"$cli" phone agent "printf '%s|' > '$work/task.out'" >/dev/null || fail "phone agent could not set the command"
$phone hello-json "$link" "$work/token" | grep -q "task.out" || fail "the phone's hello does not carry the agent command"
/usr/bin/python3 - "$work" <<'PY'
import json, sys
brief = "Fix it's \"login\" $(touch pwned) `touch pwned`\nand then $HOME\u0015touch pwned\r\tdone"
open(sys.argv[1] + "/brief.txt", "w").write(brief)
json.dump({"repo": "demo", "branch": "e2e/phone-task", "brief": brief}, open(sys.argv[1] + "/task.json", "w"))
PY
$phone call "$link" "$work/token" phone.newRow "$(cat "$work/task.json")" > "$work/task-made.json" \
    || fail "phone.newRow failed: $(cat "$work/task-made.json")"
task_pane=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pane"])' "$work/task-made.json")
task_row=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["path"])' "$work/task-made.json")
task_ran() { [[ -f "$work/task.out" ]] && [[ "$(cat "$work/task.out")" == "$(cat "$work/brief.txt")|" ]]; }
for _ in $(seq 1 100); do task_ran && break; sleep 0.2; done
task_ran || fail "the agent did not get the brief whole: $(cat "$work/task.out" 2>/dev/null)"
[[ ! -e "$task_row/pwned" && ! -e "$work/home/pwned" ]] || fail "the brief ran in the shell"
"$cli" term list --all --json | /usr/bin/python3 -c 'import json, sys; t = [p for p in json.load(sys.stdin) if p["pane"] == sys.argv[1]]; assert t and t[0]["row"] == "e2e/phone-task", t' "$task_pane" \
    || fail "the task's pane is not in its row here"
"$cli" log --type phone.call | grep -q "phone.newRow" || fail "the log has no phone.newRow call"

step "removing the phone closes its connection at once and revokes its token"
$phone hold "$link" "$work/token" "$work/held" &
hold_pid=$!
for _ in $(seq 1 50); do [[ -f "$work/held" ]] && break; sleep 0.1; done
[[ -f "$work/held" ]] || fail "the held connection never subscribed"
"$cli" phone list | grep -q "^e2e iPhone .* yes$" || fail "phone list does not show the phone connected"
"$cli" phone remove "e2e iPhone" | grep -qx "Removed e2e iPhone." || fail "phone remove said something else"
for _ in $(seq 1 50); do kill -0 "$hold_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$hold_pid" 2>/dev/null && fail "the removed phone's connection stayed open"
wait "$hold_pid" || fail "the held connection ended badly"
hold_pid=""
[[ "$($phone hello "$link" "$work/token")" == "unpaired" ]] || fail "the removed phone's token still works"
"$cli" phone list | grep -qx "No phones are paired." || fail "phone list still shows the phone"

step "the activity log names the phone"
"$cli" log --type phone.paired | grep -q "e2e iPhone" || fail "the log has no phone.paired"
"$cli" log --type phone.removed | grep -q "e2e iPhone" || fail "the log has no phone.removed"

echo
echo "e2e-phone passed"
