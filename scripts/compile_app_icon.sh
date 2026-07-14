#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 <repository-root> <bundle-resources-dir> [minimum-macos-version]" >&2
    exit 2
fi

REPOSITORY_ROOT="$1"
BUNDLE_RESOURCES_DIR="$2"
MINIMUM_SYSTEM_VERSION="${3:-13.0}"
ICON_COMPOSER_SOURCE="$REPOSITORY_ROOT/Sources/Glimpse/Resources/AppIcon.icon"
LEGACY_ICNS_SOURCE="$REPOSITORY_ROOT/Sources/Glimpse/Resources/AppIcon.icns"
LEGACY_ICONSET_SOURCE="$REPOSITORY_ROOT/Sources/Glimpse/Resources/Assets.xcassets/AppIcon.appiconset"
PARTIAL_INFO_PLIST="$BUNDLE_RESOURCES_DIR/AppIcon.partial.plist"

mkdir -p "$BUNDLE_RESOURCES_DIR"
rm -f "$PARTIAL_INFO_PLIST"

if [[ -d "$ICON_COMPOSER_SOURCE" ]] \
    && command -v xcrun >/dev/null 2>&1 \
    && xcrun --find actool >/dev/null 2>&1; then
    if xcrun actool "$ICON_COMPOSER_SOURCE" \
        --compile "$BUNDLE_RESOURCES_DIR" \
        --platform macosx \
        --minimum-deployment-target "$MINIMUM_SYSTEM_VERSION" \
        --app-icon AppIcon \
        --output-partial-info-plist "$PARTIAL_INFO_PLIST" \
        --warnings \
        --notices; then
        echo "Compiled AppIcon.icon with Liquid Glass appearance variants."
    else
        echo "Icon Composer compilation failed; using the prebuilt legacy icon." >&2
    fi
fi

rm -f "$PARTIAL_INFO_PLIST"

# Keep a complete 16–1024 px icon beside Assets.car for macOS 13–25 and for
# command-line launches that do not run from a compiled application bundle.
if [[ -f "$LEGACY_ICNS_SOURCE" ]]; then
    cp "$LEGACY_ICNS_SOURCE" "$BUNDLE_RESOURCES_DIR/AppIcon.icns"
elif [[ -d "$LEGACY_ICONSET_SOURCE" ]]; then
    TEMPORARY_ICONSET="$BUNDLE_RESOURCES_DIR/AppIcon.iconset"
    rm -rf "$TEMPORARY_ICONSET"
    mkdir -p "$TEMPORARY_ICONSET"
    cp "$LEGACY_ICONSET_SOURCE"/icon_*.png "$TEMPORARY_ICONSET"/
    iconutil --convert icns --output "$BUNDLE_RESOURCES_DIR/AppIcon.icns" "$TEMPORARY_ICONSET"
    rm -rf "$TEMPORARY_ICONSET"
else
    echo "No Glimpse app icon source was found." >&2
    exit 1
fi
