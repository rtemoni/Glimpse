import XCTest
@testable import GlimpseCore

final class PreviewPerformanceTests: XCTestCase {
    func testLimiterEmitsAtConfiguredCadence() {
        var limiter = PreviewUpdateLimiter(maximumUpdatesPerSecond: 30)

        XCTAssertTrue(limiter.shouldUpdate(at: 0))
        XCTAssertFalse(limiter.shouldUpdate(at: 0.01))
        XCTAssertTrue(limiter.shouldUpdate(at: 1.0 / 30.0))
        XCTAssertFalse(limiter.shouldUpdate(at: 0.05))
        XCTAssertTrue(limiter.shouldUpdate(at: 2.0 / 30.0))
    }

    func testLimiterRecoversWhenTimestampMovesBackward() {
        var limiter = PreviewUpdateLimiter(maximumUpdatesPerSecond: 30)

        XCTAssertTrue(limiter.shouldUpdate(at: 10))
        XCTAssertTrue(limiter.shouldUpdate(at: 1))
        XCTAssertFalse(limiter.shouldUpdate(at: 1.01))
    }

    func testRateTrackerReportsThirtyUpdatesPerSecond() {
        var tracker = PreviewUpdateRateTracker(windowDuration: 1)
        var rate = 0.0

        for index in 0...30 {
            rate = tracker.recordUpdate(at: Double(index) / 30)
        }

        XCTAssertEqual(rate, 30, accuracy: 0.001)
    }

    func testRateTrackerDropsSamplesOutsideWindow() {
        var tracker = PreviewUpdateRateTracker(windowDuration: 1)
        _ = tracker.recordUpdate(at: 0)
        _ = tracker.recordUpdate(at: 0.5)

        let rate = tracker.recordUpdate(at: 1.5)

        XCTAssertEqual(rate, 1, accuracy: 0.001)
    }
}
