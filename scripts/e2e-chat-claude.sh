#!/usr/bin/env bash
# Drives a real Claude Code (Haiku) through a chat's session, started through the login shell as a chat tab starts it:
# streaming, Allow, a denial followed by what to do instead, a message queued during a command, an interrupt, and
# resuming the session. It uses the Claude Code login and settings of whoever runs it, so it is not part of CI.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v claude >/dev/null 2>&1; then
    echo "e2e-chat-claude skipped: Claude Code is not installed"
    exit 0
fi
unset CANOPY_PANE CANOPY_CLI CANOPY_REPO CANOPY_ROW CANOPY_ROW_PATH CANOPY_PLUGIN CANOPY_ITEM CANOPY_HOST CLAUDE_CONFIG_DIR
# The flags are separate words on purpose, as the Makefile uses them.
# shellcheck disable=SC2046
CANOPY_REAL_CLAUDE=1 LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test $(scripts/test-flags.sh) --filter ChatRealClaudeTests
