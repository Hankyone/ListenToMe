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

cd "$PROJECT_DIR"
xcrun swift build -c release

APP_NAME="ListenToMe.app"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
STAGING_DIR="$PROJECT_DIR/.build/$APP_NAME.staging"
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"

mkdir -p "$DIST_DIR"
move_aside "$STAGING_DIR"
move_aside "$ICONSET_DIR"

mkdir -p "$STAGING_DIR/Contents/MacOS"
mkdir -p "$STAGING_DIR/Contents/Resources"
mkdir -p "$ICONSET_DIR"

cp "$PROJECT_DIR/.build/release/ListenToMe" \
    "$STAGING_DIR/Contents/MacOS/ListenToMe"
cp "$PROJECT_DIR/Resources/Info.plist" \
    "$STAGING_DIR/Contents/Info.plist"

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

codesign --force --deep --sign - "$STAGING_DIR" >/dev/null

move_aside "$APP_DIR"
mv "$STAGING_DIR" "$APP_DIR"

print "$APP_DIR"
