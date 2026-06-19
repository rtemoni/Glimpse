#if os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import GlimpseCore

final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var frameHandler: ((CapturedVideoFrame) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "Glimpse.camera-session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "Glimpse.camera-samples")

    static func availableCameraDevices() -> [SourceDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        .devices
        .map { SourceDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func prepare(deviceID: String?) throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = selectedDevice(deviceID: deviceID) else {
            throw RecorderRuntimeError.captureUnavailable("No camera is available.")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecorderRuntimeError.captureUnavailable("The selected camera cannot be added to the capture session.")
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)

        guard session.canAddOutput(videoOutput) else {
            throw RecorderRuntimeError.captureUnavailable("Camera video output cannot be added.")
        }
        session.addOutput(videoOutput)
    }

    func start() {
        sessionQueue.async { [session] in
            guard !session.isRunning else {
                return
            }
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            guard session.isRunning else {
                return
            }
            session.stopRunning()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        frameHandler?(
            CapturedVideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: sampleBuffer.presentationTimeStamp
            )
        )
    }

    private func selectedDevice(deviceID: String?) -> AVCaptureDevice? {
        if let deviceID {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                mediaType: .video,
                position: .unspecified
            )
            .devices
            .first { $0.uniqueID == deviceID }
        }
        return AVCaptureDevice.default(for: .video)
    }
}
#endif
