import GlimpseCore
import XCTest

final class RecordingAppActivationPolicyTests: XCTestCase {
    func testForegroundingStopsAnActiveHiddenRecording() {
        XCTAssertTrue(
            RecordingAppActivationPolicy.shouldStopRecording(
                state: .recording,
                isWindowHiddenForRecording: true
            )
        )
        XCTAssertTrue(
            RecordingAppActivationPolicy.shouldStopRecording(
                state: .paused,
                isWindowHiddenForRecording: true
            )
        )
    }

    func testForegroundingDoesNotStopWhenRecordingWindowIsVisible() {
        XCTAssertFalse(
            RecordingAppActivationPolicy.shouldStopRecording(
                state: .recording,
                isWindowHiddenForRecording: false
            )
        )
    }

    func testForegroundingDoesNotRestartAnExistingStop() {
        XCTAssertFalse(
            RecordingAppActivationPolicy.shouldStopRecording(
                state: .stopping,
                isWindowHiddenForRecording: true
            )
        )
        XCTAssertFalse(
            RecordingAppActivationPolicy.shouldStopRecording(
                state: .idle,
                isWindowHiddenForRecording: true
            )
        )
    }
}
