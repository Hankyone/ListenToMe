#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

APP_NAME="ListenToMe"
BUNDLE_ID="ca.hankyone.ListenToMe"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_DIR/dist"
RELEASE_DIR="$PROJECT_DIR/release"
PACKAGE_SCRIPT="$PROJECT_DIR/Scripts/package-app.sh"
DMG_SCRIPT="$PROJECT_DIR/Scripts/create-dmg.sh"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$PROJECT_DIR/.tmp/bin}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
TAG="v${VERSION}"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DOWNLOAD_PREFIX="${DOWNLOAD_PREFIX:-https://github.com/Hankyone/ListenToMe/releases/download/${TAG}/}"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Anouar Mansour (K32684A887)}"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-K32684A887}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$PROJECT_DIR/.secrets/sparkle_eddsa_private.key}"

sparkle_version() {
    python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path("Package.resolved").read_text())
for pin in data.get("pins", []):
    if pin.get("identity") == "sparkle":
        print(pin["state"]["version"])
        raise SystemExit(0)
raise SystemExit("Sparkle pin missing from Package.resolved")
PY
}

ensure_sparkle_tools() {
    if [[ -x "$SPARKLE_TOOLS_DIR/generate_appcast" && -x "$SPARKLE_TOOLS_DIR/sign_update" ]]; then
        return
    fi

    local version
    version="$(sparkle_version)"
    print "Downloading Sparkle ${version} tools…"
    mkdir -p "$PROJECT_DIR/.tmp"
    local archive="$PROJECT_DIR/.tmp/Sparkle-tools.tar.xz"
    curl -sL \
        -o "$archive" \
        "https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz"
    tar -xJf "$archive" -C "$PROJECT_DIR/.tmp" bin
    SPARKLE_TOOLS_DIR="$PROJECT_DIR/.tmp/bin"
}

require_file() {
    if [[ ! -f "$1" ]]; then
        print -u2 "Missing required file: $1"
        exit 1
    fi
}

if [[ -z "$APPLE_ID" || -z "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
    print -u2 "Set APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD for notarization."
    exit 1
fi

require_file "$SPARKLE_PRIVATE_KEY_FILE"
ensure_sparkle_tools

export CODESIGN_IDENTITY
"$PACKAGE_SCRIPT"

APP_PATH="$DIST_DIR/${APP_NAME}.app"
require_file "$APP_PATH/Contents/MacOS/$APP_NAME"

print "Notarizing ${APP_NAME}.app…"
# Apple notarytool accepts zip/dmg/pkg; staple the .app, then make the
# distribution zip. Sparkle publishing docs require ditto for zip archives:
#   ditto -c -k --sequesterRsrc --keepParent MyApp.app MyApp.zip
NOTARY_ZIP="$DIST_DIR/${APP_NAME}-notarize.zip"
rm -f "$NOTARY_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"

xcrun notarytool submit "$NOTARY_ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

xcrun stapler staple "$APP_PATH"
rm -f "$NOTARY_ZIP"

print "Creating release archive…"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
# Keep only the .app inside the zip to avoid app translocation issues
# (Sparkle distribution guidance).
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RELEASE_DIR/$ZIP_NAME"

print "Creating installer DMG…"
export CODESIGN_IDENTITY
"$DMG_SCRIPT" "$APP_PATH" "$RELEASE_DIR/$DMG_NAME"

print "Notarizing ${DMG_NAME}…"
xcrun notarytool submit "$RELEASE_DIR/$DMG_NAME" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
xcrun stapler staple "$RELEASE_DIR/$DMG_NAME"

NOTES_MD="$PROJECT_DIR/RELEASE_NOTES.md"
NOTES_RELEASE_MD="$RELEASE_DIR/${APP_NAME}-${VERSION}.md"
if [[ ! -f "$NOTES_MD" ]]; then
    print -u2 "Missing RELEASE_NOTES.md — Sparkle needs release notes for this version."
    exit 1
fi
if ! grep -q "ListenToMe ${VERSION}" "$NOTES_MD"; then
    print -u2 "RELEASE_NOTES.md must mention ListenToMe ${VERSION} before releasing."
    exit 1
fi
python3 "$PROJECT_DIR/Scripts/embed-appcast-notes.py" \
    --extract "$VERSION" "$NOTES_MD" > "$NOTES_RELEASE_MD"

# generate_appcast scans the folder; keep the DMG out so Sparkle only
# publishes the zip update archive. embed-appcast-notes.py then keeps
# only this version's section in the Sparkle alert.
SPARKLE_DIR="$RELEASE_DIR/sparkle"
mkdir -p "$SPARKLE_DIR"
cp "$RELEASE_DIR/$ZIP_NAME" "$SPARKLE_DIR/"
cp "$NOTES_RELEASE_MD" "$SPARKLE_DIR/"

print "Generating Sparkle appcast…"
# --embed-release-notes inlines the matching .md as sparkle:format="markdown"
# so the update alert can skip WKWebView (which is what made notes feel slow).
"$SPARKLE_TOOLS_DIR/generate_appcast" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --embed-release-notes \
    -o "$RELEASE_DIR/appcast.xml" \
    "$SPARKLE_DIR"
rm -rf "$SPARKLE_DIR"

# Normalize to inline markdown even if generate_appcast linked a notes URL.
python3 "$PROJECT_DIR/Scripts/embed-appcast-notes.py" \
    "$RELEASE_DIR/appcast.xml" \
    "$NOTES_MD"

print "Release artifacts ready in $RELEASE_DIR"
print "  version: $VERSION ($BUILD)"
print "  tag:     $TAG"
print "  zip:     $RELEASE_DIR/$ZIP_NAME"
print "  dmg:     $RELEASE_DIR/$DMG_NAME"
print "  notes:   $NOTES_RELEASE_MD"
print "  appcast: $RELEASE_DIR/appcast.xml"
ls -lh "$RELEASE_DIR"
