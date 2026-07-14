#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import GlimpseCore
import ScreenCaptureKit

enum AudioSourceKind {
    case microphone
    case system
}

final class AudioCaptureService: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var sampleHandler: ((CMSampleBuffer, AudioSourceKind) -> Void)?
    var levelHandler: ((Double, AudioSourceKind) -> Void)?

    static var isSystemAudioCaptureSupported: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    private let microphoneSession = AVCaptureSession()
    private let microphoneSessionQueue = DispatchQueue(label: "Glimpse.microphone-session")
    private let microphoneOutput = AVCaptureAudioDataOutput()
    private let microphoneSampleQueue = DispatchQueue(label: "Glimpse.microphone-samples")
    private var systemAudioStream: SystemAudioStream?
    private var includeMicrophone = false
    private var includeSystemAudio = false
    private(set) var isSystemAudioActive = false

    static func availableMicrophoneDevices() -> [SourceDevice] {
        AVCaptureDevice.devices(for: .audio)
            .map { SourceDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func prepare(microphoneDeviceID: String?, includeMicrophone: Bool, includeSystemAudio: Bool) async throws {
        self.includeMicrophone = includeMicrophone
        self.includeSystemAudio = includeSystemAudio
        self.isSystemAudioActive = false
        self.systemAudioStream = nil

        if includeMicrophone {
            try prepareMicrophone(deviceID: microphoneDeviceID)
        } else {
            clearMicrophoneConfiguration()
            levelHandler?(0, .microphone)
        }

        if includeSystemAudio {
            let systemAudioStream = SystemAudioStream()
            systemAudioStream.sampleHandler = { [weak self] sampleBuffer in
                self?.levelHandler?(Self.normalizedLevel(from: sampleBuffer), .system)
                self?.sampleHandler?(sampleBuffer, .system)
            }
            do {
                try await systemAudioStream.prepare()
                self.systemAudioStream = systemAudioStream
                self.isSystemAudioActive = true
            } catch {
                self.includeSystemAudio = false
                self.systemAudioStream = nil
                self.isSystemAudioActive = false
            }
        }
    }

    func start() async throws {
        if includeMicrophone {
            await withCheckedContinuation { continuation in
                microphoneSessionQueue.async { [microphoneSession] in
                    if !microphoneSession.isRunning {
                        microphoneSession.startRunning()
                    }
                    continuation.resume()
                }
            }
        }

        if includeSystemAudio {
            try await systemAudioStream?.start()
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            microphoneSessionQueue.async { [microphoneSession] in
                if microphoneSession.isRunning {
                    microphoneSession.stopRunning()
                }
                continuation.resume()
            }
        }
        await systemAudioStream?.stop()
        systemAudioStream = nil
        includeMicrophone = false
        includeSystemAudio = false
        isSystemAudioActive = false
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let averagePower = connection.audioChannels.first?.averagePowerLevel {
            levelHandler?(Self.normalizedLevel(fromAveragePower: averagePower), .microphone)
        }
        sampleHandler?(sampleBuffer, .microphone)
    }

    private func prepareMicrophone(deviceID: String?) throws {
        microphoneSession.beginConfiguration()
        defer {
            microphoneSession.commitConfiguration()
        }

        microphoneSession.inputs.forEach { microphoneSession.removeInput($0) }
        microphoneSession.outputs.forEach { microphoneSession.removeOutput($0) }

        guard let device = selectedMicrophone(deviceID: deviceID) else {
            throw RecorderRuntimeError.captureUnavailable("No microphone is available.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard microphoneSession.canAddInput(input) else {
            throw RecorderRuntimeError.captureUnavailable("The selected microphone cannot be added to the capture session.")
        }
        microphoneSession.addInput(input)

        microphoneOutput.setSampleBufferDelegate(self, queue: microphoneSampleQueue)
        guard microphoneSession.canAddOutput(microphoneOutput) else {
            throw RecorderRuntimeError.captureUnavailable("Microphone audio output cannot be added.")
        }
        microphoneSession.addOutput(microphoneOutput)
    }

    private func clearMicrophoneConfiguration() {
        microphoneSession.beginConfiguration()
        microphoneSession.inputs.forEach { microphoneSession.removeInput($0) }
        microphoneSession.outputs.forEach { microphoneSession.removeOutput($0) }
        microphoneSession.commitConfiguration()
    }

    private func selectedMicrophone(deviceID: String?) -> AVCaptureDevice? {
        if let deviceID {
            return AVCaptureDevice.devices(for: .audio)
                .first { $0.uniqueID == deviceID }
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private static func normalizedLevel(fromAveragePower averagePower: Float) -> Double {
        guard averagePower.isFinite else {
            return 0
        }
        let clamped = max(-60, min(0, averagePower))
        return pow(10, Double(clamped) / 20)
    }

    private static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Double {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return 0
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return 0
        }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            return 0
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var squaredTotal = 0.0
        var sampleCount = 0

        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else {
                continue
            }

            switch format.commonFormat {
            case .pcmFormatFloat32:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let sample = Double(samples[index])
                    squaredTotal += sample * sample
                }
                sampleCount += count
            case .pcmFormatFloat64:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                let samples = data.assumingMemoryBound(to: Double.self)
                for index in 0..<count {
                    let sample = samples[index]
                    squaredTotal += sample * sample
                }
                sampleCount += count
            case .pcmFormatInt16:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int16.max)
                    squaredTotal += sample * sample
                }
                sampleCount += count
            case .pcmFormatInt32:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int32.max)
                    squaredTotal += sample * sample
                }
                sampleCount += count
            case .otherFormat:
                continue
            @unknown default:
                continue
            }
        }

        guard sampleCount > 0 else {
            return 0
        }
        return min(1, sqrt(squaredTotal / Double(sampleCount)))
    }
}

private final class SystemAudioStream: NSObject, SCStreamOutput, SCStreamDelegate {
    var sampleHandler: ((CMSampleBuffer) -> Void)?

    private let sampleQueue = DispatchQueue(label: "Glimpse.system-audio-samples")
    private var stream: SCStream?

    func prepare() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw RecorderRuntimeError.captureUnavailable("No display is available for system audio capture.")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream
    }

    func start() async throws {
        guard let stream else {
            throw RecorderRuntimeError.captureUnavailable("System audio capture has not been prepared.")
        }
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else {
            return
        }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else {
            return
        }
        sampleHandler?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}
#endif
