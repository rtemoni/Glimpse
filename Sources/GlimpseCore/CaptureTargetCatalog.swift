import Foundation

/// Pure filtering and fallback-selection rules for the capture target picker.
public enum CaptureTargetCatalog {
    public static func shouldIncludeWindow(
        ownerBundleIdentifier: String?,
        ownerApplicationName: String?,
        title: String?,
        width: Double,
        height: Double,
        isOnScreen: Bool,
        ownBundleIdentifier: String?
    ) -> Bool {
        guard isOnScreen, width >= 80, height >= 80 else {
            return false
        }

        let bundleIdentifier = ownerBundleIdentifier?.lowercased()
        if let ownBundleIdentifier,
           bundleIdentifier == ownBundleIdentifier.lowercased() {
            return false
        }

        if bundleIdentifier == "com.apple.dock"
            || bundleIdentifier?.hasPrefix("com.apple.wallpaper") == true {
            return false
        }

        let ownerName = ownerApplicationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ownerName == "dock" || ownerName == "wallpaper" {
            return false
        }

        // Desktop-picture windows can be reported without useful owning-app metadata.
        if bundleIdentifier == nil {
            let windowTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if windowTitle == "desktop picture" || windowTitle == "wallpaper" {
                return false
            }
        }

        return true
    }

    /// Picks one whole-display fallback, preferring the main display when available.
    public static func backstopDisplayID(
        availableDisplayIDs: [UInt32],
        mainDisplayID: UInt32
    ) -> UInt32? {
        if availableDisplayIDs.contains(mainDisplayID) {
            return mainDisplayID
        }
        return availableDisplayIDs.first
    }
}
