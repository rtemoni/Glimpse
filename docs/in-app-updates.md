# In-app update design

Glimpse uses Sparkle 2 to replace an installed application bundle safely. The updater presents the standard macOS update flow with **Install and Relaunch** and **Install on Quit**, while Sparkle handles downloading, verification, writable-location authorization, atomic replacement, and relaunch.

## Runtime flow

1. `AppUpdateController` starts Sparkle for packaged `.app` builds.
2. Sparkle checks `updates/appcast.xml` on `main` every 24 hours, or immediately after the user chooses **Check for Updates…**.
3. The signed appcast points to the DMG attached to the matching GitHub Release.
4. Sparkle downloads the DMG and verifies:
   - the signed appcast against `SUPublicEDKey`;
   - the DMG's Ed25519 signature and byte length;
   - the replacement app's Apple code signature.
5. Sparkle mounts/extracts the release, prepares an atomic bundle replacement, and lets the user install and relaunch immediately or install when Glimpse quits.

The legacy `updates/latest.json` feed remains available so pre-Sparkle versions can continue detecting the migration release.

## Release flow

Tagging `v*` runs `.github/workflows/release-macos.yml`:

1. Build and test Glimpse.
2. Embed Sparkle and sign its nested helper tools from the inside out.
3. Sign/notarize the application and DMG when Developer ID credentials are configured.
4. Sign the final DMG bytes with the Sparkle Ed25519 private key.
5. Upload the DMG to the GitHub Release.
6. Publish both `updates/latest.json` and a signed `updates/appcast.xml` to `main`.

`SPARKLE_ED_PRIVATE_KEY` must contain the base64-encoded 32-byte private seed matching the public key in `Info.plist`. It is a required GitHub Actions secret for tag releases and must never be committed.

## Migration and recovery

An already-installed binary cannot gain self-update code retroactively. Users must install the first Sparkle-enabled release from its DMG once; every later signed release can update in place.

Keep the Ed25519 private key backed up in a secure secret store. Sparkle supports signing-key rotation when releases are also Developer ID signed, but losing both signing paths would require another manual migration. If a release is bad, publish a newer build number; do not rewrite an already-published artifact or reuse its appcast entry.

## Future delta updates

The initial implementation replaces the bundle from the existing release DMG. Sparkle can later generate binary delta artifacts with `generate_appcast`; those can be attached to GitHub Releases and added to the appcast without changing the runtime integration.

References:

- [Sparkle basic setup and security](https://sparkle-project.org/documentation/)
- [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [Publishing signed updates](https://sparkle-project.org/documentation/publishing/)
- [Sparkle sandboxing and manual helper signing](https://sparkle-project.org/documentation/sandboxing/)
