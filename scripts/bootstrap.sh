#!/bin/bash
# Fetch third-party sources into vendor/ at pinned commits.
#
# vendor/ is deliberately NOT committed: UxPlay is GPL-3.0 as a whole (only its
# LGPL lib/ is linked) and WebDriverAgent is a large Apache-2.0 tree. Keeping
# them out of this repo keeps the product source separate from third-party
# licenses, and pinning here keeps builds reproducible.
set -euo pipefail
cd "$(dirname "$0")/.."

UXPLAY_REPO="https://github.com/FDH2/UxPlay.git"
UXPLAY_COMMIT="546820c723b0539ff6ba0f6eefc590b26dc55322"

WDA_REPO="https://github.com/appium/WebDriverAgent.git"
WDA_COMMIT="8bcf451e853d0f94b89b52ec478c6b24a9fc516b"

fetch() {
    local dir="$1" repo="$2" commit="$3"
    if [ -d "$dir/.git" ]; then
        if [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ]; then
            echo "==> $dir already at pinned commit"
            return
        fi
        echo "==> Updating $dir to $commit"
    else
        echo "==> Cloning $repo into $dir"
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" remote add origin "$repo"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q FETCH_HEAD
}

mkdir -p vendor
fetch vendor/UxPlay "$UXPLAY_REPO" "$UXPLAY_COMMIT"
fetch vendor/WebDriverAgent "$WDA_REPO" "$WDA_COMMIT"

echo
echo "Dependencies ready. Next:"
echo "  brew install openssl@3 libplist cmake pkg-config   # if not installed"
echo "  ./native/build.sh                                  # build AirPlay core"
echo "  swift build                                        # build the app"
