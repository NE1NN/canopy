#!/usr/bin/env bash
# Runs the iPhone app's screen tour (Apps/CanopyiOS/CanopyUITests/ScreenTour.swift) in the iOS Simulator against
# scripts/phone-fixture.sh, in light and dark, and saves a screenshot of every screen. It then checks on the Mac side,
# through the activity log, that the answers and the reply the tour sent reached their panes. Run make app first.
#
#   scripts/ios-shots.sh [light|dark|both] [out-dir]     shots go to build/ios-shots/<appearance>/ by default
#
# IOS_SHOTS_DEVICE names the Simulator, "iPhone 17" unless set.
set -euo pipefail
cd "$(dirname "$0")/.."
appearances=${1:-both}
[[ "$appearances" == both ]] && appearances="light dark"
out=${2:-build/ios-shots}
device=${IOS_SHOTS_DEVICE:-iPhone 17}
derived="$PWD/build/ios"

udid=$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime]
print(next(d["udid"] for d in devices if d["name"] == sys.argv[1]))' "$device")
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""
xcodebuild -project Apps/CanopyiOS/Canopy.xcodeproj -scheme Canopy -destination "id=$udid" \
    -derivedDataPath "$derived" build-for-testing -quiet

watcher=""
cleanup() {
    [[ -n "$watcher" ]] && kill "$watcher" 2>/dev/null || true
    scripts/phone-fixture.sh stop || true
}
trap cleanup EXIT

for appearance in $appearances; do
    echo "==> the tour in $appearance"
    xcrun simctl ui "$udid" appearance "$appearance"
    scripts/phone-fixture.sh start
    # shellcheck source=/dev/null
    port=$(source build/phone-fixture.env && echo "$port")
    box_port=$(source build/phone-fixture.env && echo "$box_port")
    requests=$(mktemp -d -t cnshots)
    calls="$requests/calls.json"
    # The tour asks for what only the Mac can do: stopping its Canopy and the box, and starting new ones that never
    # paired, where the phone looks for them.
    (
        while true; do
            if [[ -f "$requests/stop-mac" ]]; then
                scripts/phone-fixture.sh calls > "$calls"
                scripts/phone-fixture.sh panes > "$requests/panes.json"
                scripts/phone-fixture.sh stop
                rm -f "$requests/stop-mac"
            fi
            if [[ -f "$requests/stop-box" ]]; then
                scripts/phone-fixture.sh stop-box
                rm -f "$requests/stop-box"
            fi
            if [[ -f "$requests/restart-mac" ]]; then
                PHONE_FIXTURE_PORT=$port PHONE_FIXTURE_BOX_PORT=$box_port scripts/phone-fixture.sh start >/dev/null
                # Only once it is all set up, so the script knows when it can stop it.
                rm -f "$requests/restart-mac"
            fi
            sleep 0.3
        done
    ) &
    watcher=$!
    results="$requests/tour.xcresult"
    # xcodebuild hands TEST_RUNNER_ variables in its own environment to the tour, without the prefix.
    status=0
    TEST_RUNNER_CANOPY_TOUR_LINK="$(scripts/phone-fixture.sh link)" \
        TEST_RUNNER_CANOPY_TOUR_BOX_LINK="$(scripts/phone-fixture.sh link box)" TEST_RUNNER_CANOPY_TOUR_DIR="$requests" \
        TEST_RUNNER_CANOPY_TOUR_EC2="$(scripts/phone-fixture.sh ec2)" \
        xcodebuild -project Apps/CanopyiOS/Canopy.xcodeproj -scheme Canopy -destination "id=$udid" \
        -derivedDataPath "$derived" test-without-building -only-testing:CanopyUITests/ScreenTour \
        -resultBundlePath "$results" -collect-test-diagnostics never -quiet || status=$?
    # The tour ends once the phone is back at Pairing, which can be before the new Mac has finished setting up.
    for _ in $(seq 1 600); do
        [[ -f "$requests/stop-mac" || -f "$requests/restart-mac" ]] || break
        sleep 0.1
    done
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    watcher=""
    scripts/phone-fixture.sh stop
    if [[ $status -ne 0 ]]; then
        xcrun xcresulttool get test-results tests --path "$results" | /usr/bin/python3 -c '
import json, sys
def failures(node):
    for child in node.get("children", []):
        if child.get("nodeType") == "Failure Message":
            print("FAIL:", child["name"])
        failures(child)
for node in json.load(sys.stdin)["testNodes"]:
    failures(node)'
        echo "the tour failed; its results are in $results" >&2
        exit 1
    fi

    rm -rf "${out:?}/$appearance"
    mkdir -p "$out/$appearance"
    xcrun xcresulttool export attachments --path "$results" --output-path "$requests/attachments" >/dev/null
    /usr/bin/python3 - "$requests/attachments" "$out/$appearance" <<'PY'
import json, os, re, shutil, sys
source, target = sys.argv[1:3]
# Only the tour's own shots, named like 02-inbox; Xcode adds its own snapshots and recordings.
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test["attachments"]:
        name = attachment["suggestedHumanReadableName"].split("_")[0]
        if re.fullmatch(r"\d\d-[a-z-]+", name):
            shutil.copy(os.path.join(source, attachment["exportedFileName"]), os.path.join(target, name + ".png"))
PY
    /usr/bin/python3 - "$calls" "$requests/panes.json" <<'PY'
import json, sys
calls = [call["data"] for call in json.load(open(sys.argv[1]))]
panes = json.load(open(sys.argv[2]))
expected = [
    {"method": "phone.answer", "pane": panes["companion"], "answer": {"options": [[0]]}},
    {"method": "phone.reply", "pane": panes["companion"], "text": "Use port 6974, and keep the token in the Keychain."},
    {"method": "phone.answer", "pane": panes["ticket"], "answer": {"allow": True}},
]
seen = [{key: call.get(key) for key in want} for call, want in zip(calls, expected)]
assert len(calls) == len(expected) and seen == expected, f"the Mac saw {calls}, not {expected}"
print("the Mac saw the tour's answer, reply, and Allow, each in its pane")
PY
    rm -rf "$requests"
    ls "$out/$appearance"
done
