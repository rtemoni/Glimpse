import Foundation

public struct StereoAudioBuffer: Equatable, Sendable {
    public var left: [Float]
    public var right: [Float]

    public init(left: [Float], right: [Float]) throws {
        guard left.count == right.count else {
            throw AudioMixError.channelLengthMismatch
        }
        self.left = left
        self.right = right
    }

    public var frameCount: Int {
        left.count
    }
}

public enum AudioMixError: Error, Equatable, Sendable {
    case channelLengthMismatch
}

public enum AudioMixer {
    public static func mix(
        microphone: StereoAudioBuffer?,
        system: StereoAudioBuffer?,
        microphoneGain: Float,
        systemGain: Float
    ) throws -> StereoAudioBuffer {
        let frameCount = max(microphone?.frameCount ?? 0, system?.frameCount ?? 0)
        var left = Array(repeating: Float(0), count: frameCount)
        var right = Array(repeating: Float(0), count: frameCount)

        for index in 0..<frameCount {
            let micLeft = microphone?.left[safe: index] ?? 0
            let micRight = microphone?.right[safe: index] ?? 0
            let systemLeft = system?.left[safe: index] ?? 0
            let systemRight = system?.right[safe: index] ?? 0

            left[index] = clip(micLeft * microphoneGain + systemLeft * systemGain)
            right[index] = clip(micRight * microphoneGain + systemRight * systemGain)
        }

        return try StereoAudioBuffer(left: left, right: right)
    }

    private static func clip(_ value: Float) -> Float {
        min(1, max(-1, value))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
