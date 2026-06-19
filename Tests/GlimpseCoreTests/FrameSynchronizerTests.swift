import XCTest
@testable import GlimpseCore

final class FrameSynchronizerTests: XCTestCase {
    func testChoosesMostRecentCameraFrameAtOrBeforeScreenTimestamp() {
        var synchronizer = FrameSynchronizer<String>()
        synchronizer.appendCameraFrame(TimedFrame(timestamp: 1.0, payload: "one"))
        synchronizer.appendCameraFrame(TimedFrame(timestamp: 2.0, payload: "two"))
        synchronizer.appendCameraFrame(TimedFrame(timestamp: 3.0, payload: "three"))

        XCTAssertEqual(synchronizer.frame(forScreenTimestamp: 2.5)?.payload, "two")
    }

    func testDoesNotChooseFutureCameraFrame() {
        var synchronizer = FrameSynchronizer<String>()
        synchronizer.appendCameraFrame(TimedFrame(timestamp: 10.0, payload: "future"))

        XCTAssertNil(synchronizer.frame(forScreenTimestamp: 5.0))
    }

    func testReusesLastCameraFrameWhenCameraStops() {
        var synchronizer = FrameSynchronizer<String>()
        synchronizer.appendCameraFrame(TimedFrame(timestamp: 1.0, payload: "last"))

        XCTAssertEqual(synchronizer.frame(forScreenTimestamp: 1.1)?.payload, "last")
        XCTAssertEqual(synchronizer.frame(forScreenTimestamp: 4.0)?.payload, "last")
    }

    func testLatestFrameReturnsMostRecentBufferedFrame() {
        var synchronizer = FrameSynchronizer<String>()
        synchronizer.appendCameraFrame(TimedFrame(timestamp: 10.0, payload: "future"))

        XCTAssertEqual(synchronizer.latestFrame()?.payload, "future")
    }
}
