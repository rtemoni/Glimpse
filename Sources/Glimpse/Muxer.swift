#if os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import GlimpseCore

final class Muxer {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var isPaused = false
    private var appendedVideoFrameCount = 0
    private var appendedAudioSampleCount = 0

    func start(
        outputURL: URL,
        videoSize: CGSize,
        fileFormat: RecorderFileFormat,
        includeMicrophone: Bool,
        includeSystemAudio: Bool
    ) throws {
        cancel()
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileFormat.avFileType)
        let proResSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height)
        ]
        let h264Settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.highQualityH264Bitrate(for: videoSize),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoSettings = writer.canApply(outputSettings: proResSettings, forMediaType: .video)
            ? proResSettings
            : h264Settings
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000
        ]
        guard writer.canAdd(videoInput) else {
            throw RecorderRuntimeError.writerFailed("Video track cannot be added to the asset writer.")
        }
        writer.add(videoInput)

        let microphoneInput: AVAssetWriterInput?
        if includeMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderRuntimeError.writerFailed("Microphone track cannot be added to the asset writer.")
            }
            writer.add(input)
            microphoneInput = input
        } else {
            microphoneInput = nil
        }

        let systemAudioInput: AVAssetWriterInput?
        if includeSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderRuntimeError.writerFailed("System audio track cannot be added to the asset writer.")
            }
            writer.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }

        guard writer.startWriting() else {
            throw RecorderRuntimeError.writerFailed(Self.describeWriterError(writer.error, fallback: "Asset writer failed to start."))
        }

        self.writer = writer
        self.videoInput = videoInput
        self.microphoneInput = microphoneInput
        self.systemAudioInput = systemAudioInput
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.sessionStarted = false
        self.isPaused = false
        self.appendedVideoFrameCount = 0
        self.appendedAudioSampleCount = 0
    }

    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
        guard !isPaused,
              let writer,
              let videoInput,
              let pixelBufferAdaptor,
              writer.status == .writing else {
            return
        }

        startSessionIfNeeded(at: timestamp)
        guard videoInput.isReadyForMoreMediaData else {
            return
        }
        if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: timestamp) {
            appendedVideoFrameCount += 1
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, source: AudioSourceKind, gain: Float) {
        _ = gain
        guard !isPaused,
              let writer,
              writer.status == .writing,
              CMSampleBufferIsValid(sampleBuffer) else {
            return
        }

        let audioInput: AVAssetWriterInput?
        switch source {
        case .microphone:
            audioInput = microphoneInput
        case .system:
            audioInput = systemAudioInput
        }

        guard let audioInput else {
            return
        }

        startSessionIfNeeded(at: sampleBuffer.presentationTimeStamp)
        guard audioInput.isReadyForMoreMediaData else {
            return
        }
        if audioInput.append(sampleBuffer) {
            appendedAudioSampleCount += 1
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func finish() async throws {
        guard let writer else {
            return
        }

        guard appendedVideoFrameCount > 0 else {
            writer.cancelWriting()
            reset()
            throw RecorderRuntimeError.writerFailed("No screen frames were recorded. Check Screen & System Audio Recording permission, wait for the recording preview to appear, then stop again.")
        }

        videoInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        systemAudioInput?.markAsFinished()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = writer.error {
                    continuation.resume(throwing: RecorderRuntimeError.writerFailed(Self.describeWriterError(error, fallback: "Asset writer failed to finish.")))
                } else {
                    continuation.resume()
                }
            }
        }

        reset()
    }

    func cancel() {
        writer?.cancelWriting()
        reset()
    }

    private func startSessionIfNeeded(at timestamp: CMTime) {
        guard !sessionStarted else {
            return
        }
        writer?.startSession(atSourceTime: timestamp)
        sessionStarted = true
    }

    private func reset() {
        writer = nil
        videoInput = nil
        microphoneInput = nil
        systemAudioInput = nil
        pixelBufferAdaptor = nil
        sessionStarted = false
        isPaused = false
        appendedVideoFrameCount = 0
        appendedAudioSampleCount = 0
    }

    private static func describeWriterError(_ error: Error?, fallback: String) -> String {
        guard let error else {
            return fallback
        }

        let nsError = error as NSError
        var parts = [nsError.localizedDescription]

        if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
            parts.append(failureReason)
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion, !recoverySuggestion.isEmpty {
            parts.append(recoverySuggestion)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("Underlying error: \(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))")
        }
        parts.append("(\(nsError.domain) \(nsError.code))")

        return parts.joined(separator: " ")
    }

    private static func highQualityH264Bitrate(for videoSize: CGSize) -> Int {
        let pixels = max(1, Int(videoSize.width * videoSize.height))
        let fullHD = 1_920 * 1_080
        return max(50_000_000, Int(Double(pixels) / Double(fullHD) * 50_000_000))
    }
}

private extension RecorderFileFormat {
    var avFileType: AVFileType {
        switch self {
        case .mov:
            return .mov
        case .mp4:
            return .mp4
        }
    }
}
#endif
