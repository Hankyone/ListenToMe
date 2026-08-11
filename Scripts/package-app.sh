#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

if ! xcrun --find swift >/dev/null 2>&1; then
    print -u2 "Swift was not found. Install Xcode before packaging ListenToMe."
    exit 1
fi

# Optional Developer ID identity. Empty/ad-hoc for local builds.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
ENTITLEMENTS="$PROJECT_DIR/Resources/ListenToMe.entitlements"

move_aside() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        return
    fi

    if command -v trash >/dev/null 2>&1; then
        trash "$target"
    else
        mv "$target" "${target}.backup-$(date +%Y%m%d-%H%M%S)"
    fi
}

find_sparkle_framework() {
    local bin_dir="$1"
    local candidate
    for candidate in \
        "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
        "$bin_dir/Sparkle.framework" \
        "$PROJECT_DIR/.build/out/Products/Release/Sparkle.framework" \
        "$PROJECT_DIR/.build/apple/Products/Release/Sparkle.framework" \
        "$PROJECT_DIR/.build/release/Sparkle.framework"
    do
        if [[ -d "$candidate" ]]; then
            print "$candidate"
            return
        fi
    done
    candidate="$(find "$PROJECT_DIR/.build" -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        print "$candidate"
        return
    fi
    return 1
}

find_release_binary() {
    local bin_dir binary
    bin_dir="$(xcrun swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
    binary="$bin_dir/ListenToMe"
    if [[ -x "$binary" ]]; then
        print "$binary"
        return
    fi

    for binary in \
        "$PROJECT_DIR/.build/release/ListenToMe" \
        "$PROJECT_DIR/.build/out/Products/Release/ListenToMe" \
        "$PROJECT_DIR/.build/apple/Products/Release/ListenToMe"
    do
        if [[ -x "$binary" ]]; then
            print "$binary"
            return
        fi
    done

    binary="$(find "$PROJECT_DIR/.build" \
        \( -path '*/Products/Release/ListenToMe' -o -path '*/release/ListenToMe' \) \
        -type f -perm +111 -print -quit 2>/dev/null || true)"
    if [[ -n "$binary" && -x "$binary" ]]; then
        print "$binary"
        return
    fi
    return 1
}

# Per Sparkle sandboxing docs: resign nested helpers without --deep, and never
# apply the host app's entitlements to Sparkle binaries.
# https://sparkle-project.org/documentation/sandboxing/
resign_sparkle_framework() {
    local sparkle_framework="$1"
    local identity="$2"
    local sparkle_b="$sparkle_framework/Versions/B"

    if [[ -d "$sparkle_b/XPCServices/Installer.xpc" ]]; then
        codesign -f -s "$identity" -o runtime \
            "$sparkle_b/XPCServices/Installer.xpc"
    fi
    if [[ -d "$sparkle_b/XPCServices/Downloader.xpc" ]]; then
        # Sparkle >= 2.6: preserve Downloader's own entitlements metadata.
        codesign -f -s "$identity" -o runtime \
            --preserve-metadata=entitlements \
            "$sparkle_b/XPCServices/Downloader.xpc"
    fi
    if [[ -e "$sparkle_b/Autoupdate" ]]; then
        codesign -f -s "$identity" -o runtime "$sparkle_b/Autoupdate"
    fi
    if [[ -d "$sparkle_b/Updater.app" ]]; then
        codesign -f -s "$identity" -o runtime "$sparkle_b/Updater.app"
    fi
    codesign -f -s "$identity" -o runtime "$sparkle_framework"
}

cd "$PROJECT_DIR"
# Universal binary so Sparkle does not emit arm64-only hardwareRequirements.
xcrun swift build -c release --arch arm64 --arch x86_64

APP_NAME="ListenToMe.app"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
STAGING_DIR="$PROJECT_DIR/.build/$APP_NAME.staging"
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
BIN_DIR="$(xcrun swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BINARY_PATH="$(find_release_binary)" || {
    print -u2 "Release binary was not found after swift build."
    print -u2 "Checked show-bin-path: ${BIN_DIR}/ListenToMe"
    exit 1
}

mkdir -p "$DIST_DIR"
move_aside "$STAGING_DIR"
move_aside "$ICONSET_DIR"

mkdir -p "$STAGING_DIR/Contents/MacOS"
mkdir -p "$STAGING_DIR/Contents/Resources"
mkdir -p "$STAGING_DIR/Contents/Frameworks"
mkdir -p "$ICONSET_DIR"

# ditto preserves Sparkle framework symlinks (required for valid signatures).
ditto "$BINARY_PATH" "$STAGING_DIR/Contents/MacOS/ListenToMe"
cp "$PROJECT_DIR/Resources/Info.plist" \
    "$STAGING_DIR/Contents/Info.plist"

SPARKLE_FRAMEWORK="$(find_sparkle_framework "$BIN_DIR")" || {
    print -u2 "Sparkle.framework was not found under .build. Run swift build first."
    exit 1
}
rm -rf "$STAGING_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$STAGING_DIR/Contents/Frameworks/Sparkle.framework"

# Non-sandboxed apps do not enable Sparkle XPC services; removing them matches
# Sparkle's guidance and avoids resigning helpers we never use.
SPARKLE_B="$STAGING_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
rm -rf "$SPARKLE_B/XPCServices" \
    "$STAGING_DIR/Contents/Frameworks/Sparkle.framework/XPCServices"

install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$STAGING_DIR/Contents/MacOS/ListenToMe" 2>/dev/null || true

MASTER_ICON="$PROJECT_DIR/Resources/AppIcon-v2.png"
typeset -A ICON_SIZES
ICON_SIZES=(
    icon_16x16.png 16
    icon_16x16@2x.png 32
    icon_32x32.png 32
    icon_32x32@2x.png 64
    icon_128x128.png 128
    icon_128x128@2x.png 256
    icon_256x256.png 256
    icon_256x256@2x.png 512
    icon_512x512.png 512
    icon_512x512@2x.png 1024
)

for icon_name icon_size in ${(kv)ICON_SIZES}; do
    sips -z "$icon_size" "$icon_size" "$MASTER_ICON" \
        --out "$ICONSET_DIR/$icon_name" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" \
    -o "$STAGING_DIR/Contents/Resources/AppIcon.icns"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    resign_sparkle_framework \
        "$STAGING_DIR/Contents/Frameworks/Sparkle.framework" \
        "$CODESIGN_IDENTITY"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" \
        "$STAGING_DIR"
else
    # Ad-hoc local builds: avoid hardened runtime so Sparkle can load under
    # library validation. See Sparkle basic setup notes.
    codesign --force --deep --sign - "$STAGING_DIR" >/dev/null
fi

move_aside "$APP_DIR"
mv "$STAGING_DIR" "$APP_DIR"

print "$APP_DIR"
