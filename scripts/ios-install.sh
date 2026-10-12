#!/usr/bin/env bash
# Builds the iPhone app signed for your team and installs it on the iPhone plugged into this Mac (or paired with it).
# Usage: scripts/ios-install.sh <team id>
#
# The team ID is in Xcode > Settings > Accounts, next to your Apple ID, or in Xcode's Signing & Capabilities tab once you
# pick your team there. A free Apple ID works: the app then expires after 7 days, and make ios-install renews it.
set -euo pipefail
cd "$(dirname "$0")/.."
team=${1:-}
if [[ -z "$team" ]]; then
    echo "usage: make ios-install TEAM=<your Apple team ID>" >&2
    exit 2
fi
xcodebuild -project Apps/CanopyiOS/Canopy.xcodeproj -scheme Canopy -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/ios-device -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team" -quiet build
devices=$(mktemp -t canopy-devices)
trap 'rm -f "$devices"' EXIT
xcrun devicectl list devices --json-output "$devices" >/dev/null
device=$(/usr/bin/python3 - "$devices" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [d for d in devices if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
print(phones[0]["identifier"] if phones else "")
PY
)
if [[ -z "$device" ]]; then
    echo "no iPhone found: plug it in, unlock it, and trust this Mac" >&2
    exit 1
fi
xcrun devicectl device install app --device "$device" build/ios-device/Build/Products/Release-iphoneos/Canopy.app
echo "installed Canopy on $device"
