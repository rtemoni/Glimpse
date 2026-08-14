# Glimpse

Glimpse is a SwiftPM-based macOS recording app that captures the screen, webcam, microphone, and optional system audio, then writes a single recording with the camera composited as a bottom-left picture-in-picture overlay.

## Requirements

- macOS 13 or later
- Xcode command line tools or a Swift toolchain that can link SwiftUI, AVFoundation, ScreenCaptureKit, CoreImage, and AVAssetWriter
- Xcode 26 or later to compile the layered Liquid Glass app icon (older toolchains use the bundled `.icns` fallback)

## Build and Run

```sh
swift build
swift run Glimpse
```

The package also includes `GlimpseCore`, a cross-platform core target for state-machine, overlay-layout, frame-synchronization, and audio-mixing tests.

```sh
swift test
```

## Package for Distribution

The project includes command-line packaging for direct macOS distribution:

```sh
scripts/build_app.sh
scripts/create_dmg.sh
```

`scripts/build_app.sh` creates `.build/distribution/Glimpse.app` with the standard app bundle layout:

- `Contents/Info.plist`
- `Contents/MacOS/Glimpse`
- `Contents/Resources/Assets.car` with default, dark, and tintable Liquid Glass icon appearances when Xcode 26 is available
- `Contents/Resources/AppIcon.icns` with 16–1024 px fallback artwork for macOS 13–25 and command-line launches
- `Contents/Frameworks/Sparkle.framework` for signed, atomic in-app updates
- `Contents/PlugIns` and `Contents/SharedSupport` placeholders for future bundled dependencies

Set `SIGNING_IDENTITY` to sign with a Developer ID Application certificate:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build_app.sh
```

Without `SIGNING_IDENTITY`, the script applies an ad-hoc local signature so the bundle can still be inspected and tested locally.

The icon source lives in `Sources/Glimpse/Resources/AppIcon.icon`. After changing its foreground artwork or legacy background treatment, regenerate the checked-in icon set and `.icns` entirely from the command line:

```sh
scripts/generate_app_icons.swift
```

`scripts/create_dmg.sh` creates `.build/distribution/Glimpse-<version>.dmg` with a drag-and-drop installer layout:

```sh
VERSION=0.1.0 SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/create_dmg.sh
```

To notarize and staple the DMG locally, pass Apple notarization credentials:

```sh
NOTARIZE=1 \
APPLE_ID="developer@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_SPECIFIC_PASSWORD="app-specific-password" \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
scripts/create_dmg.sh
```

## GitHub Releases

`.github/workflows/release-macos.yml` builds, signs, notarizes, staples, uploads the DMG artifact, and attaches it to a GitHub Release when a `v*` tag is pushed.

Cut the initial release from `main` with:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Optional secrets for signed and notarized tag releases:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `DEVELOPER_ID_APPLICATION_IDENTITY`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `SPARKLE_ED_PRIVATE_KEY`

Optional:

- `KEYCHAIN_PASSWORD`

`SPARKLE_ED_PRIVATE_KEY` and the Developer ID signing credentials are mandatory for update releases. A release may not fall back to an ad-hoc identity because a stable Developer ID designated requirement is what lets macOS preserve the user's privacy grants across app versions.

## Updates

Glimpse uses a signed Sparkle appcast hosted on the release branch:

```text
https://raw.githubusercontent.com/rtemoni/Glimpse/main/updates/appcast.xml
```

The app checks automatically once per day and also exposes **Check for Updates...** in the app menu and Settings. Download progress is shown from 0–99%; after verification and extraction, the action becomes **Update** and offers **Update Now** or **Next Launch**. Sparkle verifies the signed feed, Ed25519 archive signature, and Apple code signature, then atomically replaces the current app. Recorder and export settings live outside the app bundle with a rolling valid backup and a pre-update snapshot. The legacy `updates/latest.json` manifest is still published for builds that predate the in-app updater.

The first release containing Sparkle must still be installed from its DMG once. After that migration release, subsequent signed releases update in place without reinstalling a DMG.

## Privacy

The app uses only official macOS capture APIs and requests user consent for screen recording, camera, microphone, and system audio. Required usage descriptions are included in `Info.plist`.
