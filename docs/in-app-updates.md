# In-app update design

Glimpse uses Sparkle 2 to replace an installed application bundle safely. Glimpse provides the update presentation while Sparkle handles downloading, verification, writable-location authorization, atomic replacement, and relaunch.

## Runtime flow

1. `AppUpdateController` starts Sparkle for packaged `.app` builds.
2. Sparkle checks `updates/appcast.xml` on `main` every 24 hours, or immediately after the user chooses **Check for Updates…**.
3. The signed appcast points to the DMG attached to the matching GitHub Release.
4. The user chooses **Download**. Glimpse shows Sparkle's byte progress from 0–99%; it holds at 99% while Sparkle verifies and extracts the archive.
5. Sparkle verifies:
   - the signed appcast against `SUPublicEDKey`;
   - the DMG's Ed25519 signature and byte length;
   - the replacement app's Apple code signature.
6. When Sparkle reports that installation is ready, the action becomes an orange **Update** button. The user chooses either **Update Now** or **Next Launch**.
7. Immediately before that choice is committed, Glimpse writes and snapshots its settings. Sparkle then installs and relaunches immediately, or installs when Glimpse quits so the new build is ready on the next launch.

The legacy `updates/latest.json` feed remains available so pre-Sparkle versions can continue detecting the migration release.

## Release flow

Tagging `v*` runs `.github/workflows/release-macos.yml`:

1. Build and test Glimpse.
2. Embed Sparkle and sign its nested helper tools from the inside out.
3. Sign the application with the project's stable Developer ID identity. Release builds fail rather than fall back to an ad-hoc identity.
4. Sign the final DMG bytes with the Sparkle Ed25519 private key.
5. Upload the DMG to the GitHub Release.
6. Publish both `updates/latest.json` and a signed `updates/appcast.xml` to `main`.

`SPARKLE_ED_PRIVATE_KEY` must contain the base64-encoded 32-byte private seed matching the public key in `Info.plist`. It is a required GitHub Actions secret for tag releases and must never be committed.

## Migration and recovery

An already-installed binary cannot gain self-update code retroactively. Users must install the first Sparkle-enabled release from its DMG once; every later signed release can update in place.

Keep the Ed25519 private key backed up in a secure secret store. Sparkle supports signing-key rotation when releases are also Developer ID signed, but losing both signing paths would require another manual migration. If a release is bad, publish a newer build number; do not rewrite an already-published artifact or reuse its appcast entry.

## Configuration and permission continuity

- Recorder and export configuration is stored under the user's Application Support directory, outside the replaceable `.app` bundle. Writes are schema-versioned, validated, and atomic.
- The previous valid settings file is rotated as a recovery copy. A separate pre-update snapshot is written before either installation choice. If the primary file is unreadable, Glimpse restores the rolling backup, then the pre-update snapshot as a final fallback.
- Sparkle's own preferences remain in the bundle identifier's user-defaults domain.
- macOS privacy grants are owned by TCC and must not be copied or restored by the app. macOS recognizes an updated build by its designated code requirement, so releases keep `com.rtemoni.Glimpse` and the same Developer ID team identity. The packaging script rejects an accidental bundle-ID change and release CI rejects an ad-hoc build.
- Local packaging no longer resets Screen Recording permission by default. Developers can still opt into a deliberate test reset with `RESET_SCREEN_CAPTURE_TCC=1`.

## Future delta updates

The initial implementation replaces the bundle from the existing release DMG. Sparkle can later generate binary delta artifacts with `generate_appcast`; those can be attached to GitHub Releases and added to the appcast without changing the runtime integration.

References:

- [Sparkle basic setup and security](https://sparkle-project.org/documentation/)
- [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle custom user-driver callbacks](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html)
- [Publishing signed updates](https://sparkle-project.org/documentation/publishing/)
- [Sparkle sandboxing and manual helper signing](https://sparkle-project.org/documentation/sandboxing/)
- [Apple Application Support directory](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory)
- [Apple CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)
- [Apple TN3127: Inside Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
