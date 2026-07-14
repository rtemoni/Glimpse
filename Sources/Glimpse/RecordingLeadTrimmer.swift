#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import GlimpseCore

enum RecordingLeadTrimmerError: LocalizedError {
    case cannotCreateExporter
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateExporter:
            return "The recording warmup could not be removed."
        case let .exportFailed(message):
            return "The recording warmup could not be removed: \(message)"
        }
    }
}

private final class SendableExportSession: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

/// Removes capture warmup from the completed source file as one shared media
/// time range so video, microphone, and system audio stay synchronized.
final class RecordingLeadTrimmer {
    func trimRecording(
        at sourceURL: URL,
        trimDuration: TimeInterval = RecordingLeadTrimPolicy.defaultTrimDuration
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let sourceDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let retainedRange = RecordingLeadTrimPolicy.retainedRange(
            sourceDuration: sourceDuration,
            trimDuration: trimDuration
        )
        guard retainedRange.start > 0, retainedRange.duration > 0 else {
            return
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ), exporter.supportedFileTypes.contains(.mov) else {
            throw RecordingLeadTrimmerError.cannotCreateExporter
        }

        let temporaryURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".glimpse-trim-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        exporter.outputURL = temporaryURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: retainedRange.start, preferredTimescale: 600),
            duration: CMTime(seconds: retainedRange.duration, preferredTimescale: 600)
        )

        let sendableExporter = SendableExportSession(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                let completedExporter = sendableExporter.value
                switch completedExporter.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(
                        throwing: RecordingLeadTrimmerError.exportFailed(
                            completedExporter.error?.localizedDescription ?? "Export failed."
                        )
                    )
                case .cancelled:
                    continuation.resume(
                        throwing: RecordingLeadTrimmerError.exportFailed("Export was cancelled.")
                    )
                default:
                    continuation.resume(
                        throwing: RecordingLeadTrimmerError.exportFailed("Export did not complete.")
                    )
                }
            }
        }

        do {
            _ = try fileManager.replaceItemAt(sourceURL, withItemAt: temporaryURL)
        } catch {
            throw RecordingLeadTrimmerError.exportFailed(error.localizedDescription)
        }
    }
}
#endif
