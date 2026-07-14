import XCTest
@testable import GlimpseCore

final class AudioLevelScaleTests: XCTestCase {
    func testSilenceAndNoiseFloorStayAtRest() {
        XCTAssertEqual(AudioLevelScale.displayLevel(decibels: -.infinity), 0)
        XCTAssertEqual(AudioLevelScale.displayLevel(decibels: -60), 0)
        XCTAssertEqual(AudioLevelScale.displayLevel(decibels: -50), 0)
        XCTAssertEqual(AudioLevelScale.displayLevel(rootMeanSquare: 0), 0)
    }

    func testSpeechRangeGetsAnExpressiveMeterResponse() {
        let quietSpeech = AudioLevelScale.displayLevel(decibels: -35)
        let normalSpeech = AudioLevelScale.displayLevel(decibels: -20)
        let loudSpeech = AudioLevelScale.displayLevel(decibels: -8)

        XCTAssertGreaterThan(quietSpeech, 0.45)
        XCTAssertGreaterThan(normalSpeech, quietSpeech)
        XCTAssertEqual(loudSpeech, 1, accuracy: 0.0001)
    }

    func testRootMeanSquareUsesTheSameDecibelScale() {
        let rootMeanSquare = pow(10.0, -20.0 / 20.0)

        XCTAssertEqual(
            AudioLevelScale.displayLevel(rootMeanSquare: rootMeanSquare),
            AudioLevelScale.displayLevel(decibels: -20),
            accuracy: 0.0001
        )
    }

    func testLevelIsClampedForInvalidAndVeryLoudInput() {
        XCTAssertEqual(AudioLevelScale.displayLevel(decibels: .nan), 0)
        XCTAssertEqual(AudioLevelScale.displayLevel(rootMeanSquare: .infinity), 0)
        XCTAssertEqual(AudioLevelScale.displayLevel(decibels: 4), 1)
        XCTAssertEqual(AudioLevelScale.displayLevel(rootMeanSquare: 2), 1)
    }
}
