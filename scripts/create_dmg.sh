#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-Glimpse}"
VERSION="${VERSION:-0.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/.build/distribution}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
DMG_PATH="${DMG_PATH:-$OUTPUT_DIR/$APP_NAME-$VERSION.dmg}"
STAGING_DIR="${STAGING_DIR:-$OUTPUT_DIR/dmg-root}"
NOTARIZE="${NOTARIZE:-0}"

APP_PATH="${1:-$OUTPUT_DIR/$APP_NAME.app}"
TEMP_DMG="$OUTPUT_DIR/$APP_NAME-$VERSION-rw.dmg"
MOUNT_DIR="$OUTPUT_DIR/dmg-mount"
LAYOUT_SCRIPT="$OUTPUT_DIR/dmg-layout.applescript"

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found at $APP_PATH; building it first."
    "$SCRIPT_DIR/build_app.sh"
fi

rm -rf "$STAGING_DIR" "$MOUNT_DIR"
mkdir -p "$STAGING_DIR" "$MOUNT_DIR" "$OUTPUT_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$TEMP_DMG" "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "$TEMP_DMG"

cleanup() {
    if mount | grep -q "$MOUNT_DIR"; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$MOUNT_DIR" "$STAGING_DIR" "$TEMP_DMG" "$LAYOUT_SCRIPT"
}
trap cleanup EXIT

hdiutil attach "$TEMP_DMG" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" >/dev/null

cat > "$LAYOUT_SCRIPT" <<APPLESCRIPT
set dmgFolder to POSIX file "$MOUNT_DIR" as alias
tell application "Finder"
    open dmgFolder
    delay 1
    set dmgWindow to container window of dmgFolder
    set current view of dmgWindow to icon view
    try
        set toolbar visible of dmgWindow to false
    end try
    try
        set statusbar visible of dmgWindow to false
    end try
    try
        set pathbar visible of dmgWindow to false
    end try
    set bounds of dmgWindow to {100, 100, 740, 500}
    set theViewOptions to the icon view options of dmgWindow
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 80
    set text size of theViewOptions to 14
    set label position of theViewOptions to bottom
    set position of item "$APP_NAME.app" of dmgFolder to {180, 190}
    set position of item "Applications" of dmgFolder to {460, 190}
    update dmgFolder without registering applications
    delay 1
    try
        close container window of dmgFolder
    end try
end tell
APPLESCRIPT

if command -v python3 >/dev/null 2>&1; then
    python3 - "$LAYOUT_SCRIPT" <<'PY' || echo "Finder layout could not be applied; continuing with a functional DMG." >&2
import subprocess
import sys

subprocess.run(["osascript", sys.argv[1]], check=True, timeout=15)
PY
else
    osascript "$LAYOUT_SCRIPT" >/dev/null || echo "Finder layout could not be applied; continuing with a functional DMG." >&2
fi

rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes"

sync
hdiutil detach "$MOUNT_DIR" -quiet

hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    echo "Signing $DMG_PATH with $SIGNING_IDENTITY..."
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
    if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
            --wait
    else
        : "${APPLE_ID:?APPLE_ID is required when NOTARIZE=1 and NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
        : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required when NOTARIZE=1 and NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
        : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required when NOTARIZE=1 and NOTARYTOOL_KEYCHAIN_PROFILE is not set}"

        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" \
            --wait
    fi

    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"

echo "$DMG_PATH"
