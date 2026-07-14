#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Glimpse}"
DMG_PATH="${1:?Usage: scripts/verify_dmg.sh path/to/Glimpse.dmg}"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glimpse-dmg.XXXXXX")"

cleanup() {
    if mount | grep -q " on $MOUNT_DIR "; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG_PATH" \
    -readonly \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNT_DIR" >/dev/null

[[ -d "$MOUNT_DIR/$APP_NAME.app" ]] || {
    echo "$APP_NAME.app is missing from the DMG." >&2
    exit 1
}

[[ -L "$MOUNT_DIR/Applications" ]] || {
    echo "Applications shortcut is missing from the DMG." >&2
    exit 1
}

unexpected_items="$(find "$MOUNT_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name '.DS_Store' \
    ! -name "$APP_NAME.app" \
    ! -name 'Applications' \
    -print)"

if [[ -n "$unexpected_items" ]]; then
    echo "Unexpected top-level DMG items:" >&2
    echo "$unexpected_items" >&2
    exit 1
fi

echo "DMG layout verified: $APP_NAME.app and Applications only."
