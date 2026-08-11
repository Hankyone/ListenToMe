#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

cd "$PROJECT_DIR"

xcrun swift build --build-tests

# SIP strips DYLD_* for the test helper, so place Sparkle where the bundle
# rpath already looks: Products/Debug/PackageFrameworks.
# SPM may use .build/out or .build/apple depending on the toolchain.
SPARKLE_SRC=""
for candidate in \
    "$PROJECT_DIR/.build/out/Products/Debug/Sparkle.framework" \
    "$PROJECT_DIR/.build/apple/Products/Debug/Sparkle.framework"
do
    if [[ -d "$candidate" ]]; then
        SPARKLE_SRC="$candidate"
        break
    fi
done
if [[ -z "$SPARKLE_SRC" ]]; then
    SPARKLE_SRC="$(find "$PROJECT_DIR/.build" -path '*/Products/Debug/Sparkle.framework' -print -quit 2>/dev/null || true)"
fi
if [[ -n "$SPARKLE_SRC" ]]; then
    PRODUCTS_DEBUG="$(dirname "$SPARKLE_SRC")"
    PACKAGE_FRAMEWORKS="$PRODUCTS_DEBUG/PackageFrameworks"
    mkdir -p "$PACKAGE_FRAMEWORKS"
    rm -rf "$PACKAGE_FRAMEWORKS/Sparkle.framework"
    ditto "$SPARKLE_SRC" "$PACKAGE_FRAMEWORKS/Sparkle.framework"
fi

xcrun swift test --skip-build
