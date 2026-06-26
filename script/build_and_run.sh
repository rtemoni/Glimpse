#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Glimpse"
BUNDLE_ID="com.factory.glimpse"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/Glimpse/Resources/AppIcon.icns"

cd "$ROOT_DIR"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BIN_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BIN_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

copy_swiftpm_resources() {
  local resources_dir
  for resources_dir in \
    "$BIN_DIR/${APP_NAME}_${APP_NAME}.resources" \
    "$BIN_DIR/${APP_NAME}.resources" \
    "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" \
    "$BIN_DIR/${APP_NAME}.bundle"; do
    if [[ -d "$resources_dir" ]]; then
      cp -R "$resources_dir" "$APP_RESOURCES/"
    fi
  done
}

copy_swiftpm_resources

if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>Glimpse needs camera access to include your webcam in recordings when you enable it.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Glimpse needs microphone access to capture narration when you enable it.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Glimpse needs screen recording access to capture the screen you choose to record.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Glimpse needs audio capture access to record system audio when you enable it.</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

wait_for_app() {
  for _ in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    sleep 0.5
  done

  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    wait_for_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
