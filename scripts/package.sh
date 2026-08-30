#!/bin/bash
# Build MirrorDeck.app and a distributable .dmg.
#
#   ./scripts/package.sh            # build, bundle, sign, make dmg
#   VERSION=0.2.0 ./scripts/package.sh
#   NOTARIZE=1 ./scripts/package.sh   # also notarize + staple (needs Developer ID)
#
# Signing: uses a "Developer ID Application" identity when one exists (required
# for distribution outside the App Store). Falls back to ad-hoc signing, which
# is fine for local testing but WILL be blocked by Gatekeeper on other Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
COPYRIGHT="${COPYRIGHT:-Copyright © $(date +%Y) Emerson Garland. All rights reserved.}"
APP_NAME="MirrorDeck"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building native AirPlay core (shared library)"
[ -f native/build/libMirrorCore.dylib ] || ./native/build.sh >/dev/null

echo "==> Building $APP_NAME $VERSION (release)"
swift build -c release 2>&1 | grep -vE "^ld: warning" | tail -2

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/"$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# All copyleft code ships as this replaceable shared library, never linked into
# the app binary. Required for LGPL relinking — see licenses/NOTICE.md.
cp native/build/libMirrorCore.dylib "$APP/Contents/Frameworks/"
cp -R licenses "$APP/Contents/Resources/licenses"

sed -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD_NUMBER/" \
    -e "s/__COPYRIGHT__/$COPYRIGHT/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Generating icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift packaging/MakeIcon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Signing"
# `|| true`: no matching certificate is an expected case, not a script failure.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 \
    | sed -E 's/.*"(.*)".*/\1/' || true)"
if [ -n "$IDENTITY" ]; then
    echo "    identity: $IDENTITY"
    # Nested code must be signed before the enclosing bundle.
    # Hardened runtime is mandatory for notarization.
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$APP/Contents/Frameworks/libMirrorCore.dylib"
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$APP"
    SIGNED_FOR_DISTRIBUTION=1
else
    echo "    WARNING: no 'Developer ID Application' certificate found."
    echo "    Falling back to ad-hoc signing — Gatekeeper will block this build"
    echo "    on any other Mac. See README (Distribution) to get the cert."
    codesign --force --sign - "$APP/Contents/Frameworks/libMirrorCore.dylib"
    codesign --force --sign - "$APP"
    SIGNED_FOR_DISTRIBUTION=0
fi
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -2

if [ "${NOTARIZE:-0}" = "1" ]; then
    if [ "$SIGNED_FOR_DISTRIBUTION" != "1" ]; then
        echo "==> Skipping notarization: needs a Developer ID signature." >&2
    else
        echo "==> Notarizing (requires stored credentials profile 'mirrordeck')"
        ZIP="$DIST/$APP_NAME-notarize.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile mirrordeck --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
    fi
fi

echo "==> Building disk image"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$DIST/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov \
    -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# The disk image is notarized too, so it opens cleanly on a machine that has
# never seen it. Stapling both means neither needs a network check at open time.
if [ "${NOTARIZE:-0}" = "1" ] && [ "$SIGNED_FOR_DISTRIBUTION" = "1" ]; then
    echo "==> Notarizing disk image"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile mirrordeck --wait
    xcrun stapler staple "$DMG"
fi

echo
echo "Built:"
echo "  $APP"
echo "  $DMG  ($(du -h "$DMG" | cut -f1))"
if [ "$SIGNED_FOR_DISTRIBUTION" = "1" ]; then
    spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  gatekeeper: /' || true
else
    echo "  (ad-hoc signed — Gatekeeper will block this on other Macs)"
fi
