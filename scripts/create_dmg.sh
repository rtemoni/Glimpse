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
BACKGROUND_SOURCE="${BACKGROUND_SOURCE:-$REPO_ROOT/scripts/assets/dmg-background.png}"
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
mkdir -p "$STAGING_DIR/.background" "$MOUNT_DIR" "$OUTPUT_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"

if [[ -f "$BACKGROUND_SOURCE" ]]; then
    cp "$BACKGROUND_SOURCE" "$STAGING_DIR/.background/background.png"
fi

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

if [[ -f "$MOUNT_DIR/.background/background.png" ]]; then
    cat > "$LAYOUT_SCRIPT" <<APPLESCRIPT
set dmgFolder to POSIX file "$MOUNT_DIR" as alias
tell application "Finder"
    open dmgFolder
    set current view of container window of dmgFolder to icon view
    set toolbar visible of container window of dmgFolder to false
    set statusbar visible of container window of dmgFolder to false
    set bounds of container window of dmgFolder to {100, 100, 740, 500}
    set theViewOptions to the icon view options of container window of dmgFolder
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set background picture of theViewOptions to file ".background:background.png" of dmgFolder
    set position of item "$APP_NAME.app" of dmgFolder to {154, 232}
    set position of item "Applications" of dmgFolder to {420, 232}
    update dmgFolder without registering applications
    delay 1
    close container window of dmgFolder
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
fi

if command -v SetFile >/dev/null 2>&1; then
    SetFile -a V "$MOUNT_DIR/.background" || true
elif xcrun -f SetFile >/dev/null 2>&1; then
    xcrun SetFile -a V "$MOUNT_DIR/.background" || true
fi

touch "$MOUNT_DIR/.metadata_never_index"
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
