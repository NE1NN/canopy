#!/usr/bin/env bash
# Runs the tests. If they are still running after 12 minutes, prints every thread's stack in the test process and
# fails, so a hang on CI shows where it is stuck instead of running into the job's time limit.
set -uo pipefail
cd "$(dirname "$0")/.."

# Swift Testing otherwise starts every test at once. Hundreds of tests that each start git, python3, tmux, or a pty
# on the runner's 3 CPUs held each other back for 45 seconds, past the tests' own limits.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=8

make test &
tests=$!
for _ in $(seq 1 720); do
    if ! kill -0 "$tests" 2>/dev/null; then
        wait "$tests"
        exit $?
    fi
    sleep 1
done

echo "Tests are still running after 12 minutes. Stacks of the test processes follow."
for pid in $(pgrep -f 'swiftpm-testing-helper|xctest|CanopyPackageTests'); do
    echo "=== pid $pid: $(ps -o command= -p "$pid" | cut -c1-120)"
    sample "$pid" 2 -mayDie 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p' | head -300
done
kill "$tests" 2>/dev/null
exit 1
