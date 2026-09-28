#!/usr/bin/env bash
# DIAGNOSTIC ONLY: samples the test process every few seconds to find what stalls the suite on CI.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p diag
sysctl hw.ncpu hw.activecpu kern.wq_max_constrained_threads kern.wq_max_threads > diag/sysctl.txt 2>&1

make test &
tests=$!

(
    start=""
    n=0
    for _ in $(seq 1 900); do
        pid=$(pgrep -o -f 'swiftpm-testing-helper|xctest')
        if [ -z "$pid" ]; then
            [ -n "$start" ] && [ $(( $(date +%s) - start )) -gt 20 ] && ! kill -0 "$tests" 2>/dev/null && break
            sleep 0.2
            continue
        fi
        [ -z "$start" ] && start=$(date +%s)
        t=$(( $(date +%s) - start ))
        [ "$t" -gt 120 ] && break
        n=$((n + 1))
        out="diag/sample-$(printf %02d $n)-t$t.txt"
        {
            echo "=== sample $n at +${t}s pid $pid: $(ps -o command= -p "$pid" | cut -c1-160)"
            top -l 1 -n 12 -o cpu -stats pid,command,cpu,th,state 2>/dev/null | tail -14
        } > "$out"
        sample "$pid" 1 1 -mayDie >> "$out" 2>&1
        sleep 2
    done
) &
sampler=$!

for _ in $(seq 1 480); do
    if ! kill -0 "$tests" 2>/dev/null; then
        wait "$tests"
        code=$?
        wait "$sampler"
        exit $code
    fi
    sleep 1
done
kill "$tests" 2>/dev/null
exit 1
