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

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found at $APP_PATH; building it first."
    "$SCRIPT_DIR/build_app.sh"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

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
