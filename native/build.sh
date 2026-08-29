#!/bin/bash
# Builds the AirPlay core as a SHARED library: native/build/libMirrorCore.dylib
#
# This is deliberately a separate, replaceable component. It contains all the
# copyleft-licensed code (UxPlay's LGPL lib/, the GPL-3.0 playfair FairPlay
# implementation, LGPL libplist); the application links to it only through the
# C ABI in include/mirror_bridge.h. Anyone can rebuild this library from source
# with this script and drop the result into MirrorDeck.app/Contents/Frameworks/
# to run the app against their own build. See licenses/NOTICE.md.
set -euo pipefail
cd "$(dirname "$0")"

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(sysctl -n hw.ncpu)" --target mirrorcore

# keep the SwiftPM-visible copy of the header in sync
cp include/mirror_bridge.h ../Sources/CMirrorBridge/include/mirror_bridge.h

DYLIB="build/libMirrorCore.dylib"
echo
echo "Built native/$DYLIB"
otool -D "$DYLIB" | tail -1
echo "exported symbols:"
nm -gU "$DYLIB" | awk '{print "  " $NF}'
