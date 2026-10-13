#!/usr/bin/env bash
# Builds Canopy and assembles a signed .app bundle in build/.
# Usage: scripts/bundle.sh <debug|release> <dev|release>
set -euo pipefail
cd "$(dirname "$0")/.."

configuration=${1:-debug}
flavor=${2:-dev}
identity=${CANOPY_SIGN_IDENTITY:-Canopy Dev}

case "$flavor" in
    dev) app_name="Canopy Dev"; bundle_id="com.ne1nn.Canopy.dev"; canopy_home="~/.canopy-dev" ;;
    release) app_name="Canopy"; bundle_id="com.ne1nn.Canopy"; canopy_home="~/.canopy" ;;
    *) echo "unknown flavor: $flavor" >&2; exit 2 ;;
esac

if [[ "$identity" != "-" ]] && ! security find-identity -v -p codesigning | grep -q "\"$identity\""; then
    echo "error: signing identity \"$identity\" not found. Run: make signing-cert" >&2
    echo "       (or CANOPY_SIGN_IDENTITY=- for an ad hoc signature)" >&2
    exit 1
fi

swift build -c "$configuration" --product CanopyApp
swift build -c "$configuration" --product canopy
bin=$(swift build -c "$configuration" --show-bin-path)
version=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/CanopyWire/CanopyVersion.swift)

app="build/$app_name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
cp "$bin/CanopyApp" "$app/Contents/MacOS/Canopy"
cp "$bin/canopy" "$app/Contents/Resources/bin/canopy"
# canopy-box for hosts, built in Docker. Without Docker the app still builds, and hosts cannot be upgraded.
rebuilt=0
if docker info >/dev/null 2>&1; then
    make box
    rebuilt=1
else
    echo "warning: Docker is not running, so canopy-box is not rebuilt for hosts." >&2
fi
# Hosts install the bundled canopy-box whenever its hash differs, so one older than its sources would replace a newer
# build there. Left out, hosts keep the one they have.
stale=""
if ((!rebuilt)) && [[ -x build/box/x86_64/canopy-box ]]; then
    stale=$(find Sources/CanopyBox Sources/CanopyBoxKit Sources/CanopyAgents Sources/CanopyServer Sources/CanopyWire \
        Sources/CanopySystem Sources/CanopyGit Sources/CSystemShims Package.swift Package.resolved \
        -newer build/box/x86_64/canopy-box -type f -print -quit 2>/dev/null)
fi
if [[ -n "$stale" ]]; then
    echo "warning: build/box is older than canopy-box's sources ($stale), so this app leaves it out rather than" \
        "install it over newer builds on hosts. Start Docker, or run make box." >&2
elif [[ -x build/box/x86_64/canopy-box && -x build/box/aarch64/canopy-box ]]; then
    for arch in x86_64 aarch64; do
        mkdir -p "$app/Contents/Resources/box/$arch"
        cp "build/box/$arch/canopy-box" "$app/Contents/Resources/box/$arch/canopy-box"
    done
else
    echo "warning: no canopy-box in build/box, so this app cannot upgrade hosts. Run make box." >&2
fi
sed -e "s|@APP_NAME@|$app_name|g" \
    -e "s|@BUNDLE_ID@|$bundle_id|g" \
    -e "s|@CANOPY_HOME@|$canopy_home|g" \
    -e "s|@VERSION@|$version|g" \
    Resources/Info.plist.in > "$app/Contents/Info.plist"

codesign --force --sign "$identity" --identifier "$bundle_id.cli" "$app/Contents/Resources/bin/canopy"
codesign --force --sign "$identity" --identifier "$bundle_id" "$app"
echo "built $app"
