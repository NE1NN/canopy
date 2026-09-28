#!/usr/bin/env bash
# Opens the dev build on a throwaway home that has something in every part of the window, for UI checks and shots:
# three repos, rows with open, draft, merged, and closed PRs, other worktrees, running programs, listening ports,
# and a split tab. Nothing outside the throwaway folder is touched.
#
#   scripts/ui-fixture.sh [dark|light]   launch it and print its pid
#   scripts/ui-fixture.sh stop           quit it and delete its folder
#
# PR badges come from a stand-in gh, which the app finds first on its login PATH through a fixture ZDOTDIR.
# Writing "logged-out" to $work/bin/gh-mode makes it answer like a gh with no login.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Canopy Dev.app"
cli="$app/Contents/Resources/bin/canopy"
state="$PWD/build/ui-fixture.env"

if [[ "${1:-}" == stop ]]; then
    [[ -f "$state" ]] || exit 0
    # shellcheck source=/dev/null
    source "$state"
    kill "$pid" 2>/dev/null || true
    # Only a folder this script made: named by mktemp -t cnp, and holding the stand-in gh and the fixture ZDOTDIR.
    if [[ "$(basename "$work")" != cnp.* || ! -x "$work/bin/gh" || ! -d "$work/zdot" ]]; then
        echo "not deleting $work: it does not look like a fixture folder" >&2
        exit 1
    fi
    rm -rf "$work"
    rm -f "$state"
    exit 0
fi

[[ -x "$cli" ]] || { echo "build it first: make app" >&2; exit 1; }
# The socket path must stay under 104 bytes, so the home goes in a short temporary folder.
work=$(mktemp -d -t cnp)
export CANOPY_HOME="$work/home"

mkdir -p "$work/bin" "$work/zdot"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/python3
import json, os, re, sys
mode = os.path.join(os.path.dirname(__file__), "gh-mode")
if os.path.exists(mode) and open(mode).read().strip() == "logged-out":
    sys.stderr.write("gh: To get started with GitHub CLI, please run:  gh auth login\n")
    sys.exit(4)
query = next(a[6:] for a in sys.argv if a.startswith("query="))
prs = {
    "feat/onboarding-flow": (142, "Onboarding in three steps", "OPEN", True),
    "fix/login-redirect": (139, "Keep the page after logging in", "MERGED", False),
    "feat/checkout-redesign": (145, "Split checkout into steps", "OPEN", False),
    "spike/new-parser": (131, "Try a new parser", "CLOSED", False),
}
repo = {}
for key, branch in re.findall(r'(b\d+): pullRequests\(headRefName: "([^"]*)"', query):
    nodes = []
    if branch in prs:
        number, title, state, draft = prs[branch]
        nodes.append({"number": number, "title": title, "url": f"https://github.com/acme/web-app/pull/{number}",
                      "state": state, "isDraft": draft, "updatedAt": "2026-09-28T01:00:00Z",
                      "isCrossRepository": False})
    repo[key] = {"nodes": nodes}
print(json.dumps({"data": {"repository": repo}}))
GH
chmod +x "$work/bin/gh"
cat > "$work/zdot/.zshrc" <<ZSHRC
export PATH="$work/bin:\$PATH"
ZSHRC

for repo in web-app api-server docs; do
    git init -q -b main "$work/$repo"
    git -C "$work/$repo" -c user.email=ui@example.com -c user.name=ui commit -q --allow-empty -m init
done

# Either appearance, whatever the Mac is set to.
if [[ "${1:-dark}" == light ]]; then args=(-NSRequiresAquaSystemAppearance YES); else args=(-AppleInterfaceStyle Dark); fi
(ZDOTDIR="$work/zdot" SHELL=/bin/zsh exec "$app/Contents/MacOS/Canopy" "${args[@]}" </dev/null >/dev/null 2>&1) &
# Written at once, so `stop` can clean up even if a later step fails. The subshell execs, so $! is the app.
printf 'pid=%s\nwork=%s\n' "$!" "$work" > "$state"
for _ in $(seq 1 100); do
    [[ -S "$CANOPY_HOME/canopy.sock" ]] && break
    sleep 0.1
done

for repo in web-app api-server docs; do "$cli" repo add "$work/$repo" >/dev/null; done
"$cli" row new feat/onboarding-flow --repo web-app >/dev/null
"$cli" row new fix/login-redirect --repo web-app >/dev/null
"$cli" row new feat/checkout-redesign --repo web-app >/dev/null
"$cli" row new feat/rate-limits --repo api-server >/dev/null
git -C "$work/web-app" worktree add -q -b hotfix/cart-total "$work/elsewhere/cart-total"
git -C "$work/web-app" worktree add -q -b spike/new-parser "$work/elsewhere/new-parser"
# Remotes come after the rows, so creating the rows does not fetch. The stand-in gh answers for them.
git -C "$work/web-app" remote add origin https://github.com/acme/web-app.git
git -C "$work/api-server" remote add origin https://github.com/acme/api-server.git
"$cli" row select feat/checkout-redesign --repo web-app >/dev/null
sleep 1

# A plain prompt keeps the machine's user and host names out of shots.
plain="PROMPT='%F{blue}%B%1~%b%f %# '; clear"
agent="$plain; "'printf "\n\033[36m●\033[0m Read \033[90msrc/checkout/\033[0mForm.tsx\n\033[36m●\033[0m Update \033[90msrc/checkout/\033[0mForm.tsx  \033[32m+48\033[0m \033[31m-21\033[0m\n\033[36m●\033[0m Bash \033[90mbun test checkout\033[0m\n  \033[32m✓\033[0m 18 passed\n\nThe form now has three steps.\n"; sleep 600'
row=(--repo web-app --row feat/checkout-redesign)
first=$("$cli" term list --all --json | /usr/bin/python3 -c \
    'import json, sys; print([t["pane"] for t in json.load(sys.stdin) if t["row"] == "feat/checkout-redesign"][0])')
"$cli" term send "$first" "$agent" --enter >/dev/null
"$cli" term new "${row[@]}" --run "$plain; python3 -m http.server 5173" >/dev/null
"$cli" term new "${row[@]}" --run "$plain; git status -sb" >/dev/null
"$cli" term new "${row[@]}" --tab agent --run "$plain; sleep 600" >/dev/null
"$cli" term new "${row[@]}" --tab "Terminal 2" --run "$plain" >/dev/null
"$cli" term new --repo web-app --row feat/onboarding-flow --run "$plain; sleep 600" >/dev/null
"$cli" term new --repo api-server --row feat/rate-limits --run "$plain; python3 -m http.server 8080" >/dev/null
"$cli" row select feat/checkout-redesign --repo web-app >/dev/null

# shellcheck source=/dev/null
source "$state"
echo "pid $pid, CANOPY_HOME=$CANOPY_HOME"
