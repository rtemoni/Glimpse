#if os(macOS)
import CoreMedia
import Foundation
import GlimpseCore

/// Keeps capture, compositing, preview rendering, and asset-writer traffic off the main actor.
/// Video submissions are latest-wins so an overloaded preview never grows an unbounded backlog.
final class CaptureMediaPipeline: @unchecked Sendable {
    var screenPreviewHandler: ((CapturePreviewFrame) -> Void)?
    var cameraPreviewHandler: ((CapturePreviewFrame) -> Void)?
    var audioLevelHandler: ((Double, Double, AudioSourceKind) -> Void)?

    private struct RecordingConfiguration {
        var overlay: OverlaySettings
        let microphoneEnabled: Bool
        let systemAudioEnabled: Bool
        let microphoneGain: Float
        let systemAudioGain: Float
    }

    private enum Mode {
        case stopped
        case preview(OverlaySettings)
        case recording(RecordingConfiguration)
    }

    private let mediaQueue = DispatchQueue(
        label: "Glimpse.media-pipeline",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let meterQueue = DispatchQueue(
        label: "Glimpse.audio-meter-pipeline",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let pendingFrameLock = NSLock()
    private let submissionStateLock = NSLock()
    private let compositor = VideoCompositor()
    private let muxer = Muxer()

    private var mode: Mode = .stopped
    private var pendingScreenFrame: CapturedVideoFrame?
    private var pendingCameraFrame: CapturedVideoFrame?
    private var isScreenDrainScheduled = false
    private var isCameraDrainScheduled = false
    private var acceptsVideoFrames = false
    private var acceptsAudioSamples = false
    private var screenPreviewLimiter = PreviewUpdateLimiter(maximumUpdatesPerSecond: 30)
    private var cameraPreviewLimiter = PreviewUpdateLimiter(maximumUpdatesPerSecond: 30)
    private var screenRateTracker = PreviewUpdateRateTracker()
    private var cameraRateTracker = PreviewUpdateRateTracker()

    private var microphoneMeterEnabled = false
    private var systemAudioMeterEnabled = false
    private var microphoneRateTracker = PreviewUpdateRateTracker()
    private var systemAudioRateTracker = PreviewUpdateRateTracker()

    func startPreview(
        overlay: OverlaySettings,
        microphoneEnabled: Bool,
        systemAudioEnabled: Bool
    ) async {
        await performOnMediaQueue {
            self.resetVideoState()
            self.mode = .preview(overlay)
        }
        setSubmissionState(acceptsVideoFrames: true, acceptsAudioSamples: false)
        configureMeters(microphoneEnabled: microphoneEnabled, systemAudioEnabled: systemAudioEnabled)
    }

    func startRecording(
        outputURL: URL,
        videoSize: CGSize,
        fileFormat: RecorderFileFormat,
        overlay: OverlaySettings,
        microphoneEnabled: Bool,
        systemAudioEnabled: Bool,
        microphoneGain: Float,
        systemAudioGain: Float
    ) async throws {
        try await performThrowingOnMediaQueue {
            self.resetVideoState()
            try self.muxer.start(
                outputURL: outputURL,
                videoSize: videoSize,
                fileFormat: fileFormat,
                includeMicrophone: microphoneEnabled,
                includeSystemAudio: systemAudioEnabled
            )
            self.mode = .recording(
                RecordingConfiguration(
                    overlay: overlay,
                    microphoneEnabled: microphoneEnabled,
                    systemAudioEnabled: systemAudioEnabled,
                    microphoneGain: microphoneGain,
                    systemAudioGain: systemAudioGain
                )
            )
        }
        setSubmissionState(acceptsVideoFrames: true, acceptsAudioSamples: true)
        configureMeters(microphoneEnabled: microphoneEnabled, systemAudioEnabled: systemAudioEnabled)
    }

    func updateOverlaySettings(_ overlay: OverlaySettings) {
        mediaQueue.async { [weak self] in
            guard let self else {
                return
            }
            switch mode {
            case .preview:
                mode = .preview(overlay)
            case .recording(var configuration):
                configuration.overlay = overlay
                mode = .recording(configuration)
            case .stopped:
                break
            }
        }
    }

    func receiveScreenFrame(_ frame: CapturedVideoFrame) {
        guard shouldAcceptVideoFrames() else {
            return
        }
        pendingFrameLock.lock()
        pendingScreenFrame = frame
        guard !isScreenDrainScheduled else {
            pendingFrameLock.unlock()
            return
        }
        isScreenDrainScheduled = true
        pendingFrameLock.unlock()

        mediaQueue.async { [weak self] in
            self?.drainScreenFrames()
        }
    }

    func receiveCameraFrame(_ frame: CapturedVideoFrame) {
        guard shouldAcceptVideoFrames() else {
            return
        }
        pendingFrameLock.lock()
        pendingCameraFrame = frame
        guard !isCameraDrainScheduled else {
            pendingFrameLock.unlock()
            return
        }
        isCameraDrainScheduled = true
        pendingFrameLock.unlock()

        mediaQueue.async { [weak self] in
            self?.drainCameraFrames()
        }
    }

    func receiveAudioSample(_ sampleBuffer: CMSampleBuffer, source: AudioSourceKind) {
        guard shouldAcceptAudioSamples() else {
            return
        }
        mediaQueue.async { [weak self] in
            guard let self,
                  case let .recording(configuration) = mode else {
                return
            }

            switch source {
            case .microphone where configuration.microphoneEnabled:
                muxer.appendAudioSampleBuffer(
                    sampleBuffer,
                    source: source,
                    gain: configuration.microphoneGain
                )
            case .system where configuration.systemAudioEnabled:
                muxer.appendAudioSampleBuffer(
                    sampleBuffer,
                    source: source,
                    gain: configuration.systemAudioGain
                )
            default:
                break
            }
        }
    }

    func receiveAudioLevel(_ level: Double, source: AudioSourceKind) {
        let now = ProcessInfo.processInfo.systemUptime
        meterQueue.async { [weak self] in
            guard let self else {
                return
            }

            let rate: Double
            switch source {
            case .microphone:
                guard microphoneMeterEnabled else {
                    return
                }
                rate = microphoneRateTracker.recordUpdate(at: now)
            case .system:
                guard systemAudioMeterEnabled else {
                    return
                }
                rate = systemAudioRateTracker.recordUpdate(at: now)
            }

            audioLevelHandler?(level, rate, source)
        }
    }

    func setPaused(_ paused: Bool) {
        mediaQueue.async { [weak self] in
            self?.muxer.setPaused(paused)
        }
    }

    func stopPreview() async {
        await stopProcessing()
    }

    func finishRecording() async throws {
        await stopProcessing()
        try await muxer.finish()
    }

    func cancelRecording() async {
        await stopProcessing()
        muxer.cancel()
    }

    private func drainScreenFrames() {
        while let frame = takePendingScreenFrame() {
            processScreenFrame(frame)
        }
    }

    private func drainCameraFrames() {
        while let frame = takePendingCameraFrame() {
            processCameraFrame(frame)
        }
    }

    private func takePendingScreenFrame() -> CapturedVideoFrame? {
        pendingFrameLock.lock()
        defer { pendingFrameLock.unlock() }
        guard let frame = pendingScreenFrame else {
            isScreenDrainScheduled = false
            return nil
        }
        pendingScreenFrame = nil
        return frame
    }

    private func takePendingCameraFrame() -> CapturedVideoFrame? {
        pendingFrameLock.lock()
        defer { pendingFrameLock.unlock() }
        guard let frame = pendingCameraFrame else {
            isCameraDrainScheduled = false
            return nil
        }
        pendingCameraFrame = nil
        return frame
    }

    private func processScreenFrame(_ frame: CapturedVideoFrame) {
        switch mode {
        case .stopped:
            return
        case .preview(let overlay):
            let now = ProcessInfo.processInfo.systemUptime
            guard screenPreviewLimiter.shouldUpdate(at: now),
                  let image = compositor.makeCompositedPreviewImage(
                    screenFrame: frame,
                    settings: overlay,
                    maximumSize: CGSize(width: 960, height: 540)
                  ) else {
                return
            }
            let rate = screenRateTracker.recordUpdate(at: now)
            screenPreviewHandler?(CapturePreviewFrame(image: image, updatesPerSecond: rate))
        case .recording(let configuration):
            let pixelBuffer = compositor.compose(
                screenFrame: frame,
                settings: configuration.overlay
            ) ?? frame.pixelBuffer
            muxer.appendVideoPixelBuffer(pixelBuffer, at: frame.timestamp)
        }
    }

    private func processCameraFrame(_ frame: CapturedVideoFrame) {
        compositor.updateCameraFrame(frame)
        guard case let .preview(overlay) = mode,
              overlay.isEnabled else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard cameraPreviewLimiter.shouldUpdate(at: now),
              let image = compositor.makePreviewImage(
                from: frame.pixelBuffer,
                maximumSize: CGSize(width: 960, height: 720)
              ) else {
            return
        }
        let rate = cameraRateTracker.recordUpdate(at: now)
        cameraPreviewHandler?(CapturePreviewFrame(image: image, updatesPerSecond: rate))
    }

    private func stopProcessing() async {
        setSubmissionState(acceptsVideoFrames: false, acceptsAudioSamples: false)
        await performOnMediaQueue {
            self.mode = .stopped
            self.resetVideoState()
        }
        configureMeters(microphoneEnabled: false, systemAudioEnabled: false)
        await performOnMeterQueue {}
    }

    private func resetVideoState() {
        compositor.reset()
        screenPreviewLimiter.reset()
        cameraPreviewLimiter.reset()
        screenRateTracker.reset()
        cameraRateTracker.reset()

        pendingFrameLock.lock()
        pendingScreenFrame = nil
        pendingCameraFrame = nil
        pendingFrameLock.unlock()
    }

    private func configureMeters(microphoneEnabled: Bool, systemAudioEnabled: Bool) {
        meterQueue.async { [weak self] in
            guard let self else {
                return
            }
            microphoneMeterEnabled = microphoneEnabled
            systemAudioMeterEnabled = systemAudioEnabled
            microphoneRateTracker.reset()
            systemAudioRateTracker.reset()
        }
    }

    private func setSubmissionState(acceptsVideoFrames: Bool, acceptsAudioSamples: Bool) {
        submissionStateLock.lock()
        self.acceptsVideoFrames = acceptsVideoFrames
        self.acceptsAudioSamples = acceptsAudioSamples
        submissionStateLock.unlock()
    }

    private func shouldAcceptVideoFrames() -> Bool {
        submissionStateLock.lock()
        defer { submissionStateLock.unlock() }
        return acceptsVideoFrames
    }

    private func shouldAcceptAudioSamples() -> Bool {
        submissionStateLock.lock()
        defer { submissionStateLock.unlock() }
        return acceptsAudioSamples
    }

    private func performOnMediaQueue(_ operation: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            mediaQueue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private func performThrowingOnMediaQueue(_ operation: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            mediaQueue.async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performOnMeterQueue(_ operation: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            meterQueue.async {
                operation()
                continuation.resume()
            }
        }
    }
}
#endif
