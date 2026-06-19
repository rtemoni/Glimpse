import XCTest
@testable import GlimpseCore

final class RecordingStateMachineTests: XCTestCase {
    func testHappyPathLifecycle() throws {
        var machine = RecordingStateMachine()

        try machine.startPreparing()
        XCTAssertEqual(machine.state, .preparing)

        try machine.markReady()
        XCTAssertEqual(machine.state, .ready)

        try machine.startRecording()
        XCTAssertEqual(machine.state, .recording)

        try machine.pause()
        XCTAssertEqual(machine.state, .paused)

        try machine.resume()
        XCTAssertEqual(machine.state, .recording)

        try machine.startStopping()
        XCTAssertEqual(machine.state, .stopping)

        try machine.finishStopped()
        XCTAssertEqual(machine.state, .idle)
    }

    func testCannotRecordWithoutBeingReady() {
        var machine = RecordingStateMachine()

        XCTAssertThrowsError(try machine.startRecording()) { error in
            XCTAssertEqual(
                error as? RecordingStateMachineError,
                .invalidTransition(event: .startRecording, state: .idle)
            )
        }
        XCTAssertEqual(machine.state, .idle)
    }

    func testFailAndReset() {
        var machine = RecordingStateMachine()

        machine.fail()
        XCTAssertEqual(machine.state, .error)

        machine.reset()
        XCTAssertEqual(machine.state, .idle)
    }
}
