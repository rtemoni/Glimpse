import XCTest
@testable import GlimpseCore

final class VideoCompositorLayoutTests: XCTestCase {
    func testOverlayIsAnchoredBottomLeftWithAspectRatio() {
        let rect = VideoCompositorLayout.overlayRect(
            screen: PixelSize(width: 1920, height: 1080),
            camera: PixelSize(width: 1280, height: 720),
            settings: OverlaySettings(sizePreset: .medium)
        )

        XCTAssertEqual(rect?.x, 24)
        XCTAssertEqual(rect?.width ?? 0, 384, accuracy: 0.001)
        XCTAssertEqual(rect?.height ?? 0, 216, accuracy: 0.001)
        XCTAssertEqual(rect?.y ?? 0, 840, accuracy: 0.001)
    }

    func testOverlayClampsToMaximumWidth() {
        let rect = VideoCompositorLayout.overlayRect(
            screen: PixelSize(width: 6_000, height: 3_000),
            camera: PixelSize(width: 1_920, height: 1_080),
            settings: OverlaySettings(sizePreset: .large, maximumWidth: 400)
        )

        XCTAssertEqual(rect?.width ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(rect?.height ?? 0, 225, accuracy: 0.001)
    }

    func testOverlayCanAnchorToEachRequestedPosition() {
        let expectedOrigins: [OverlayPosition: (x: Double, y: Double)] = [
            .bottomLeft: (24, 840),
            .topLeft: (24, 24),
            .topRight: (1512, 24),
            .bottomRight: (1512, 840),
            .topMiddle: (768, 24),
            .bottomMiddle: (768, 840)
        ]

        for (position, origin) in expectedOrigins {
            let rect = VideoCompositorLayout.overlayRect(
                screen: PixelSize(width: 1920, height: 1080),
                camera: PixelSize(width: 1280, height: 720),
                settings: OverlaySettings(position: position)
            )

            XCTAssertEqual(rect?.x ?? 0, origin.x, accuracy: 0.001, "x for \(position)")
            XCTAssertEqual(rect?.y ?? 0, origin.y, accuracy: 0.001, "y for \(position)")
        }
    }

    func testSquareOverlayUsesSquareCrop() {
        let rect = VideoCompositorLayout.overlayRect(
            screen: PixelSize(width: 1920, height: 1080),
            camera: PixelSize(width: 1280, height: 720),
            settings: OverlaySettings(shape: .square)
        )

        XCTAssertEqual(rect?.width ?? 0, 384, accuracy: 0.001)
        XCTAssertEqual(rect?.height ?? 0, 384, accuracy: 0.001)
        XCTAssertEqual(rect?.y ?? 0, 672, accuracy: 0.001)
    }

    func testCircleOverlayUsesSquareCrop() {
        let rect = VideoCompositorLayout.overlayRect(
            screen: PixelSize(width: 1920, height: 1080),
            camera: PixelSize(width: 1280, height: 720),
            settings: OverlaySettings(shape: .circle)
        )

        XCTAssertEqual(rect?.width ?? 0, 216, accuracy: 0.001)
        XCTAssertEqual(rect?.height ?? 0, 216, accuracy: 0.001)
        XCTAssertEqual(rect?.y ?? 0, 840, accuracy: 0.001)
    }

    func testOverlayRemainsInsideSmallScreens() {
        let rect = VideoCompositorLayout.overlayRect(
            screen: PixelSize(width: 240, height: 160),
            camera: PixelSize(width: 1280, height: 720),
            settings: OverlaySettings(margin: 24, minimumWidth: 200, maximumWidth: 400)
        )

        XCTAssertNotNil(rect)
        XCTAssertGreaterThanOrEqual(rect?.x ?? -1, 0)
        XCTAssertGreaterThanOrEqual(rect?.y ?? -1, 0)
        XCTAssertLessThanOrEqual((rect?.x ?? 0) + (rect?.width ?? 0), 240)
        XCTAssertLessThanOrEqual((rect?.y ?? 0) + (rect?.height ?? 0), 160)
    }

    func testDisabledOverlayReturnsNil() {
        let rect = VideoCompositorLayout.overlayRect(
            screen: PixelSize(width: 1920, height: 1080),
            camera: PixelSize(width: 1280, height: 720),
            settings: OverlaySettings(isEnabled: false)
        )

        XCTAssertNil(rect)
    }
}
