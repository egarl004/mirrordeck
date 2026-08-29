#!/bin/bash
# Builds the vendored UxPlay protocol core + mirror bridge and merges
# everything (incl. static libplist and libcrypto) into libMirrorCore.a,
# which the Swift package links.
set -euo pipefail
cd "$(dirname "$0")"

BREW_PREFIX="$(brew --prefix)"
LIBPLIST_A="$(ls "$BREW_PREFIX"/opt/libplist/lib/libplist-2.0.a)"
LIBCRYPTO_A="$(ls "$BREW_PREFIX"/opt/openssl@3/lib/libcrypto.a)"

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(sysctl -n hw.ncpu)"

libtool -static -o build/libMirrorCore.a \
    build/libmirrorbridge.a \
    build/airplay/libairplay.a \
    build/playfair/libplayfair.a \
    build/llhttp/libllhttp.a \
    build/dns_sd/libdnssd.a \
    "$LIBPLIST_A" \
    "$LIBCRYPTO_A"

# keep the SwiftPM-visible copy of the header in sync
cp include/mirror_bridge.h ../Sources/CMirrorBridge/include/mirror_bridge.h

echo "Built native/build/libMirrorCore.a"
