import XCTest
@testable import GlimpseCore

final class CaptureTargetCatalogTests: XCTestCase {
    func testFiltersDockWallpaperOwnAppAndOffscreenWindows() {
        XCTAssertFalse(includes(bundleID: "com.apple.dock", owner: "Dock"))
        XCTAssertFalse(includes(bundleID: "com.apple.wallpaper.extension", owner: "Wallpaper"))
        XCTAssertFalse(includes(bundleID: "com.example.Glimpse", owner: "Glimpse"))
        XCTAssertFalse(includes(bundleID: "com.example.notes", owner: "Notes", isOnScreen: false))
        XCTAssertFalse(includes(bundleID: nil, owner: nil, title: "Desktop Picture"))
    }

    func testIncludesUsefulApplicationWindows() {
        XCTAssertTrue(includes(bundleID: "com.apple.Safari", owner: "Safari", title: "Project"))
        XCTAssertTrue(includes(bundleID: nil, owner: "Utility", title: "Untitled"))
    }

    func testFiltersWindowsTooSmallToBeUseful() {
        XCTAssertFalse(includes(bundleID: "com.example.app", owner: "App", width: 79))
        XCTAssertFalse(includes(bundleID: "com.example.app", owner: "App", height: 79))
    }

    func testBackstopPrefersMainDisplayAndFallsBackToFirstDisplay() {
        XCTAssertEqual(
            CaptureTargetCatalog.backstopDisplayID(
                availableDisplayIDs: [7, 12],
                mainDisplayID: 12
            ),
            12
        )
        XCTAssertEqual(
            CaptureTargetCatalog.backstopDisplayID(
                availableDisplayIDs: [7, 12],
                mainDisplayID: 99
            ),
            7
        )
        XCTAssertNil(
            CaptureTargetCatalog.backstopDisplayID(
                availableDisplayIDs: [],
                mainDisplayID: 99
            )
        )
    }

    private func includes(
        bundleID: String?,
        owner: String?,
        title: String? = "Window",
        width: Double = 640,
        height: Double = 480,
        isOnScreen: Bool = true
    ) -> Bool {
        CaptureTargetCatalog.shouldIncludeWindow(
            ownerBundleIdentifier: bundleID,
            ownerApplicationName: owner,
            title: title,
            width: width,
            height: height,
            isOnScreen: isOnScreen,
            ownBundleIdentifier: "com.example.Glimpse"
        )
    }
}
