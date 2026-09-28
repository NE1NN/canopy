#!/usr/bin/env bash
# DIAGNOSTIC ONLY: records test events, xcodebuild processes, and the timed tests' elapsed times on CI.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p diag

swift build --build-tests $(scripts/test-flags.sh) > diag/build.txt 2>&1
LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build $(scripts/test-flags.sh) \
    --experimental-event-stream-output diag/events.jsonl --experimental-event-stream-version 0 > diag/test-output.txt 2>&1 &
tests=$!

(
    while kill -0 "$tests" 2>/dev/null; do
        {
            echo "=== $(date +%s) $(uptime | sed 's/.*load/load/') procs=$(ps -A | wc -l)"
            ps -Ao pid,ppid,etime,pcpu,state,command | grep -E 'xcodebuild|xcrun' | grep -v grep | cut -c1-220
        } >> diag/ps.txt
        sleep 1
    done
) &

for _ in $(seq 1 480); do
    if ! kill -0 "$tests" 2>/dev/null; then
        wait "$tests"
        code=$?
        cat diag/test-output.txt
        exit $code
    fi
    sleep 1
done
kill "$tests" 2>/dev/null
cat diag/test-output.txt
exit 1
