#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-Glimpse}"
PRODUCT_NAME="${PRODUCT_NAME:-Glimpse}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.rtemoni.Glimpse}"
EXPECTED_UPDATE_BUNDLE_IDENTIFIER="${EXPECTED_UPDATE_BUNDLE_IDENTIFIER:-com.rtemoni.Glimpse}"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/.build/distribution}"
INFO_PLIST_SOURCE="${INFO_PLIST_SOURCE:-$REPO_ROOT/Info.plist}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$REPO_ROOT/Signing/ScreenCamRecorder.entitlements}"
RESOURCE_BUNDLE_NAME="${RESOURCE_BUNDLE_NAME:-Glimpse_Glimpse.bundle}"
SPARKLE_FRAMEWORK_SOURCE="${SPARKLE_FRAMEWORK_SOURCE:-$REPO_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-13.0}"
SKIP_CODESIGN="${SKIP_CODESIGN:-0}"
RESET_SCREEN_CAPTURE_TCC="${RESET_SCREEN_CAPTURE_TCC:-0}"

if [[ "$BUNDLE_IDENTIFIER" != "$EXPECTED_UPDATE_BUNDLE_IDENTIFIER" && "${ALLOW_UPDATE_IDENTITY_CHANGE:-0}" != "1" ]]; then
    echo "Refusing to change bundle identifier from $EXPECTED_UPDATE_BUNDLE_IDENTIFIER to $BUNDLE_IDENTIFIER." >&2
    echo "Changing update identity resets macOS privacy grants and separates user defaults." >&2
    exit 1
fi

if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" && -z "${SIGNING_IDENTITY:-}" ]]; then
    echo "A stable Developer ID signing identity is required for update releases." >&2
    exit 1
fi
if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" && -z "${APPLE_TEAM_ID:-}" ]]; then
    echo "APPLE_TEAM_ID is required to verify update release identity." >&2
    exit 1
fi

if [[ -z "${VERSION:-}" ]]; then
    if git -C "$REPO_ROOT" describe --tags --abbrev=0 >/dev/null 2>&1; then
        VERSION="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 | sed 's/^v//')"
    else
        VERSION="0.1.0"
    fi
fi

if [[ -z "${BUILD_NUMBER:-}" ]]; then
    if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
    else
        BUILD_NUMBER="1"
    fi
fi

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
SHARED_SUPPORT_DIR="$CONTENTS_DIR/SharedSupport"

plist_set_string() {
    local key="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$CONTENTS_DIR/Info.plist" >/dev/null
}

plist_set_bool() {
    local key="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$CONTENTS_DIR/Info.plist" >/dev/null
}

echo "Building $PRODUCT_NAME ($CONFIGURATION)..."
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_PATH/$PRODUCT_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Expected executable not found at $EXECUTABLE_PATH" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$PLUGINS_DIR" "$SHARED_SUPPORT_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$PRODUCT_NAME"
chmod 755 "$MACOS_DIR/$PRODUCT_NAME"

cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
plist_set_string "CFBundleExecutable" "$PRODUCT_NAME"
plist_set_string "CFBundleIdentifier" "$BUNDLE_IDENTIFIER"
plist_set_string "CFBundleName" "$APP_NAME"
plist_set_string "CFBundleDisplayName" "$APP_NAME"
plist_set_string "CFBundlePackageType" "APPL"
plist_set_string "CFBundleShortVersionString" "$VERSION"
plist_set_string "CFBundleVersion" "$BUILD_NUMBER"
plist_set_string "CFBundleIconFile" "AppIcon"
plist_set_string "CFBundleIconName" "AppIcon"
plist_set_string "LSMinimumSystemVersion" "$MINIMUM_SYSTEM_VERSION"
plist_set_bool "NSHighResolutionCapable" "true"

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

"$SCRIPT_DIR/compile_app_icon.sh" "$REPO_ROOT" "$RESOURCES_DIR" "$MINIMUM_SYSTEM_VERSION"

if [[ -d "$BIN_PATH/$RESOURCE_BUNDLE_NAME" ]]; then
    cp -R "$BIN_PATH/$RESOURCE_BUNDLE_NAME" "$RESOURCES_DIR/"
fi

if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    echo "Sparkle.framework was not resolved at $SPARKLE_FRAMEWORK_SOURCE" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"

if [[ "$SKIP_CODESIGN" != "1" ]]; then
    SPARKLE_FRAMEWORK="$FRAMEWORKS_DIR/Sparkle.framework"
    CODESIGN_ARGS=(--force --options runtime)
    if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
        CODESIGN_IDENTITY="$SIGNING_IDENTITY"
        CODESIGN_ARGS+=(--timestamp)
    else
        echo "SIGNING_IDENTITY is not set; applying local ad-hoc signatures."
        CODESIGN_IDENTITY="-"
    fi

    codesign "${CODESIGN_ARGS[@]}" \
        --sign "$CODESIGN_IDENTITY" \
        "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    codesign "${CODESIGN_ARGS[@]}" \
        --preserve-metadata=entitlements \
        --sign "$CODESIGN_IDENTITY" \
        "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
    codesign "${CODESIGN_ARGS[@]}" \
        --sign "$CODESIGN_IDENTITY" \
        "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    codesign "${CODESIGN_ARGS[@]}" \
        --sign "$CODESIGN_IDENTITY" \
        "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
    codesign "${CODESIGN_ARGS[@]}" \
        --sign "$CODESIGN_IDENTITY" \
        "$SPARKLE_FRAMEWORK"

    if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
        echo "Signing $APP_DIR with $SIGNING_IDENTITY..."
        codesign --force --timestamp --options runtime \
            --entitlements "$ENTITLEMENTS_PATH" \
            --sign "$SIGNING_IDENTITY" \
            "$APP_DIR"
    else
        AD_HOC_ENTITLEMENTS_PATH="$OUTPUT_DIR/$APP_NAME-ad-hoc.entitlements"
        cp "$ENTITLEMENTS_PATH" "$AD_HOC_ENTITLEMENTS_PATH"
        /usr/libexec/PlistBuddy \
            -c "Add :com.apple.security.cs.disable-library-validation bool true" \
            "$AD_HOC_ENTITLEMENTS_PATH"
        codesign --force --options runtime \
            --entitlements "$AD_HOC_ENTITLEMENTS_PATH" \
            --sign - \
            "$APP_DIR"
    fi
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"

    if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
        SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$APP_DIR" 2>&1)"
        ACTUAL_TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<< "$SIGNATURE_DETAILS")"
        ACTUAL_SIGNING_IDENTIFIER="$(sed -n 's/^Identifier=//p' <<< "$SIGNATURE_DETAILS")"

        if [[ -z "$ACTUAL_TEAM_ID" || "$ACTUAL_TEAM_ID" == "not set" ]]; then
            echo "Release app does not have a stable Developer ID team identifier." >&2
            exit 1
        fi
        if [[ -n "${APPLE_TEAM_ID:-}" && "$ACTUAL_TEAM_ID" != "$APPLE_TEAM_ID" ]]; then
            echo "Signed app team $ACTUAL_TEAM_ID does not match APPLE_TEAM_ID $APPLE_TEAM_ID." >&2
            exit 1
        fi
        if [[ "$ACTUAL_SIGNING_IDENTIFIER" != "$EXPECTED_UPDATE_BUNDLE_IDENTIFIER" ]]; then
            echo "Signed app identifier $ACTUAL_SIGNING_IDENTIFIER does not match $EXPECTED_UPDATE_BUNDLE_IDENTIFIER." >&2
            exit 1
        fi
    fi
fi

if [[ "$RESET_SCREEN_CAPTURE_TCC" == "1" ]]; then
    echo "Resetting ScreenCapture TCC permission for $BUNDLE_IDENTIFIER..."
    tccutil reset ScreenCapture "$BUNDLE_IDENTIFIER" \
        || echo "ScreenCapture TCC reset skipped for $BUNDLE_IDENTIFIER."
fi

echo "$APP_DIR"
