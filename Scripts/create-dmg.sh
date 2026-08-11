#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

if [[ $# -lt 2 ]]; then
    print -u2 "Usage: $0 /path/to/ListenToMe.app /path/to/ListenToMe-X.Y.Z.dmg"
    exit 1
fi

APP_PATH="${1:A}"
OUT_DMG="${2:A}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "App bundle not found: $APP_PATH"
    exit 1
fi

BACKGROUND_TIFF="$PROJECT_DIR/Resources/dmg/background.tiff"
if [[ ! -f "$BACKGROUND_TIFF" ]]; then
    print -u2 "Missing DMG background: $BACKGROUND_TIFF"
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        print "Installing create-dmg via Homebrew…"
        brew install create-dmg
    else
        print -u2 "create-dmg is required. Install with: brew install create-dmg"
        exit 1
    fi
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/listentome-dmg.XXXXXX")"
cleanup() {
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGE_DIR/ListenToMe.app"

VOLUME_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
CREATE_DMG_ARGS=(
    --volname "ListenToMe"
    --background "$BACKGROUND_TIFF"
    --window-pos 200 120
    --window-size 660 420
    --icon-size 128
    --icon "ListenToMe.app" 160 185
    --hide-extension "ListenToMe.app"
    --app-drop-link 500 185
    --no-internet-enable
    --hdiutil-quiet
)

if [[ -f "$VOLUME_ICON" ]]; then
    CREATE_DMG_ARGS+=(--volicon "$VOLUME_ICON")
fi

rm -f "$OUT_DMG"
# create-dmg returns 2 when Finder UI automation glitches but the DMG is usable.
set +e
create-dmg "${CREATE_DMG_ARGS[@]}" "$OUT_DMG" "$STAGE_DIR"
CREATE_STATUS=$?
set -e
if [[ ! -f "$OUT_DMG" ]]; then
    print -u2 "create-dmg failed to produce $OUT_DMG (exit $CREATE_STATUS)"
    exit 1
fi
if [[ "$CREATE_STATUS" -ne 0 && "$CREATE_STATUS" -ne 2 ]]; then
    print -u2 "create-dmg failed with exit $CREATE_STATUS"
    exit "$CREATE_STATUS"
fi

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$OUT_DMG"
    codesign --verify --verbose=2 "$OUT_DMG"
fi

print "$OUT_DMG"
