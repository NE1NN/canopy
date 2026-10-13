#!/usr/bin/env bash
# Builds the iPhone app signed for your team and installs it on the iPhone plugged into this Mac (or on its Wi-Fi).
# Usage: scripts/ios-install.sh [team id]
#
# Without a team ID it uses the team of this Mac's Apple Development certificate, which Xcode makes under
# Settings > Apple Accounts > Manage Certificates. A free Apple ID works: the app then expires after 7 days, and
# make ios-install renews it.
set -euo pipefail
cd "$(dirname "$0")/.."

team=${1:-}
if [[ -z "$team" ]]; then
    teams=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | awk '/BEGIN CERT/{cert=""} {cert=cert $0 "\n"} /END CERT/{printf "%s", cert | "openssl x509 -noout -subject"; close("openssl x509 -noout -subject")}' \
        | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | sort -u) || true
    case $(printf '%s' "$teams" | grep -c .) in
        1) team=$teams ;;
        0)
            echo "no Apple Development certificate: in Xcode, Settings > Apple Accounts, add your Apple ID," >&2
            echo "then Manage Certificates > + > Apple Development" >&2
            exit 2
            ;;
        *)
            echo "this Mac has certificates for more than one team; pick one: make ios-install TEAM=<team id>" >&2
            echo "$teams" >&2
            exit 2
            ;;
    esac
fi

devices=$(mktemp -t canopy-devices)
trap 'rm -f "$devices"' EXIT
xcrun devicectl list devices --json-output "$devices" >/dev/null
read -r device udid developer_mode < <(/usr/bin/python3 - "$devices" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
# Simulators are listed too. A phone Xcode can reach has a transport, by cable or Wi-Fi; one it only remembers has none.
phones = [d for d in devices if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d["hardwareProperties"].get("reality") == "physical"
          and d.get("connectionProperties", {}).get("transportType")]
if phones:
    phone = phones[0]
    print(phone["identifier"], phone["hardwareProperties"]["udid"],
          phone.get("deviceProperties", {}).get("developerModeStatus", "unknown"))
else:
    print("- - -")
PY
)
if [[ "$device" == - ]]; then
    echo "no iPhone found: plug it in, unlock it, and tap Trust" >&2
    exit 1
fi
if [[ "$developer_mode" == disabled ]]; then
    echo "Developer Mode is off on the iPhone: Settings > Privacy & Security > Developer Mode" >&2
    exit 1
fi

# Building for this phone, rather than any iPhone, lets Xcode add it to the team, which a free team needs before it
# can make a provisioning profile.
xcodebuild -project Apps/CanopyiOS/Canopy.xcodeproj -scheme Canopy -configuration Release \
    -destination "id=$udid" -derivedDataPath build/ios-device \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$team" -quiet build
xcrun devicectl device install app --device "$device" build/ios-device/Build/Products/Release-iphoneos/Canopy.app
echo "installed Canopy on the iPhone, signed for team $team"
