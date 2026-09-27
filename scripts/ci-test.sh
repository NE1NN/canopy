#!/usr/bin/env bash
# Runs the tests. If they are still running after 8 minutes, prints every thread's stack in the test process and
# fails, so a hang on CI shows where it is stuck instead of running into the job's time limit.
set -uo pipefail
cd "$(dirname "$0")/.."

make test &
tests=$!
for _ in $(seq 1 480); do
    if ! kill -0 "$tests" 2>/dev/null; then
        wait "$tests"
        exit $?
    fi
    sleep 1
done

echo "Tests are still running after 8 minutes. Stacks of the test processes follow."
for pid in $(pgrep -f 'swiftpm-testing-helper|xctest|CanopyPackageTests'); do
    echo "=== pid $pid: $(ps -o command= -p "$pid" | cut -c1-120)"
    sample "$pid" 2 -mayDie 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p' | head -300
done
kill "$tests" 2>/dev/null
exit 1
