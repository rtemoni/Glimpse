import XCTest
@testable import GlimpseCore

final class AudioMixerTests: XCTestCase {
    func testMixesMicrophoneAndSystemAudioWithIndependentGain() throws {
        let microphone = try StereoAudioBuffer(left: [0.2, 0.2], right: [0.1, 0.1])
        let system = try StereoAudioBuffer(left: [0.5, -0.5], right: [0.25, -0.25])

        let mixed = try AudioMixer.mix(
            microphone: microphone,
            system: system,
            microphoneGain: 2,
            systemGain: 0.5
        )

        XCTAssertEqual(mixed.left[0], 0.65, accuracy: 0.0001)
        XCTAssertEqual(mixed.left[1], 0.15, accuracy: 0.0001)
        XCTAssertEqual(mixed.right[0], 0.325, accuracy: 0.0001)
        XCTAssertEqual(mixed.right[1], 0.075, accuracy: 0.0001)
    }

    func testMixClipsToStereoRange() throws {
        let microphone = try StereoAudioBuffer(left: [0.9], right: [-0.9])
        let system = try StereoAudioBuffer(left: [0.9], right: [-0.9])

        let mixed = try AudioMixer.mix(
            microphone: microphone,
            system: system,
            microphoneGain: 1,
            systemGain: 1
        )

        XCTAssertEqual(mixed.left, [1])
        XCTAssertEqual(mixed.right, [-1])
    }

    func testRejectsMismatchedStereoChannels() {
        XCTAssertThrowsError(try StereoAudioBuffer(left: [0.1], right: [0.1, 0.2])) { error in
            XCTAssertEqual(error as? AudioMixError, .channelLengthMismatch)
        }
    }
}
