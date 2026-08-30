#!/bin/bash
# Build, install, and launch WebDriverAgent on a physical iPhone.
#
#   ./scripts/wda.sh install   # build + install the runner app (once per device/Xcode update)
#   ./scripts/wda.sh run       # launch the WDA server (keep running while you control the phone)
#   ./scripts/wda.sh ip        # print the phone's Wi-Fi IP for MirrorDeck's Enable Control field
#
# Signing uses your own Apple Developer team, detected from the keychain.
# Override with TEAM_ID=... and BUNDLE_PREFIX=... in the environment.
set -euo pipefail
cd "$(dirname "$0")/.."

# The 10-character code in parentheses. Prefer "Developer ID Application",
# where it is reliably the Team ID; on "Apple Development" identities it can be
# a personal user identifier instead, which provisioning would reject.
detect_team() {
    local ids
    ids="$(security find-identity -v -p codesigning 2>/dev/null)"
    printf '%s\n' "$ids" | grep "Developer ID Application" \
        | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | head -1 && return
    printf '%s\n' "$ids" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | head -1
}

TEAM_ID="${TEAM_ID:-$(detect_team)}"
if [ -z "$TEAM_ID" ]; then
    cat >&2 <<'MSG'
No Apple Developer team found.

WebDriverAgent runs on the phone as a signed test bundle, so it needs your own
Apple Developer account. Open Xcode -> Settings -> Accounts, add your Apple ID,
then re-run. To choose a specific team explicitly:

    TEAM_ID=XXXXXXXXXX ./scripts/wda.sh install
MSG
    exit 1
fi

# Neutral default; WDA ships com.facebook.* identifiers, which cannot be
# registered under another team. Set BUNDLE_PREFIX if this one is taken.
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.mirrordeck}"
WDA_DIR="vendor/WebDriverAgent"
DERIVED="${DERIVED:-$PWD/.build/wda-dd}"

# Default to the first available (paired, reachable) iPhone.
resolve_device() {
    if [ -n "${DEVICE_UDID:-}" ]; then echo "$DEVICE_UDID"; return; fi
    xcrun devicectl list devices --json-output /tmp/mirrordeck-devices.json >/dev/null 2>&1
    python3 - <<'PY'
import json, sys
devices = json.load(open('/tmp/mirrordeck-devices.json'))['result']['devices']
for d in devices:
    hardware, properties = d.get('hardwareProperties', {}), d.get('deviceProperties', {})
    if hardware.get('deviceType') == 'iPhone' and d.get('connectionProperties', {}).get('pairingState') == 'paired':
        print(hardware['udid']); sys.exit(0)
sys.exit('No paired iPhone found. Connect/unlock the phone and retry.')
PY
}

xctestrun_path() {
    ls "$DERIVED"/Build/Products/WebDriverAgentRunner_iphoneos*.xctestrun 2>/dev/null | head -1
}

# WDA ships with com.facebook.* bundle IDs, which can't be registered under
# another team. Rewrite them in the project rather than passing
# PRODUCT_BUNDLE_IDENTIFIER on the command line, which would collapse every
# target onto one identifier.
patch_bundle_ids() {
    python3 - "$WDA_DIR/WebDriverAgent.xcodeproj/project.pbxproj" "$BUNDLE_PREFIX" <<'PY'
import sys
path, prefix = sys.argv[1], sys.argv[2]
source = open(path).read()
for target in ("WebDriverAgentRunner", "WebDriverAgentLib"):
    source = source.replace(
        f"PRODUCT_BUNDLE_IDENTIFIER = com.facebook.{target};",
        f"PRODUCT_BUNDLE_IDENTIFIER = {prefix}.{target};")
open(path, "w").write(source)
PY
}

cmd_build() {
    echo "Building WebDriverAgent (team $TEAM_ID)…"
    patch_bundle_ids
    xcodebuild build-for-testing \
        -project "$WDA_DIR/WebDriverAgent.xcodeproj" \
        -scheme WebDriverAgentRunner \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        | grep -E "SUCCEEDED|FAILED|error:" || true
}

cmd_install() {
    [ -n "$(xctestrun_path)" ] || cmd_build
    local udid app
    udid="$(resolve_device)"
    app="$DERIVED/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
    echo "Installing to $udid…"
    xcrun devicectl device install app --device "$udid" "$app"
}

cmd_run() {
    local udid run
    udid="$(resolve_device)"
    run="$(xctestrun_path)"
    [ -n "$run" ] || { echo "No xctestrun; run '$0 install' first." >&2; exit 1; }
    echo "Starting WebDriverAgent on $udid (Ctrl-C to stop)…"
    xcodebuild test-without-building -xctestrun "$run" -destination "id=$udid"
}

cmd_ip() {
    local udid
    udid="$(resolve_device)"
    xcrun devicectl device info details --device "$udid" 2>/dev/null \
        | grep -iE "ipv4|inet " | head -5
}

case "${1:-run}" in
    build) cmd_build ;;
    install) cmd_install ;;
    run) cmd_run ;;
    ip) cmd_ip ;;
    *) echo "usage: $0 {build|install|run|ip}" >&2; exit 1 ;;
esac
