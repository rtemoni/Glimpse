#if os(macOS)
import AVFoundation
import CoreImage
import Foundation
import GlimpseCore

struct RecordingSourceSet: Equatable {
    var camera: Bool
    var microphone: Bool
    var systemAudio: Bool
}

enum RecordingCaptureTargetKind: Equatable {
    case display
    case window
}

struct RecordingSummary: Equatable {
    var sourceURL: URL
    var duration: TimeInterval
    var fileSizeBytes: Int64
    var videoSize: PixelSize
    var sourceBitrate: Int?
    var sources: RecordingSourceSet
    var overlaySettings: OverlaySettings
    var captureTargetKind: RecordingCaptureTargetKind
}

struct ExportedVideo: Identifiable, Equatable {
    var preset: ExportAspectPreset
    var url: URL

    var id: String {
        "\(preset.rawValue)-\(url.path)"
    }
}

enum VideoExportError: LocalizedError {
    case noKeptRanges
    case cannotCreateExporter
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noKeptRanges:
            return "There are no kept timeline ranges to export."
        case .cannotCreateExporter:
            return "The edited video could not be prepared for export."
        case let .exportFailed(message):
            return message
        }
    }
}

final class VideoExporter {
    func export(
        sourceURL: URL,
        session: EditingSession,
        settings: ExportSettings,
        outputDirectory: URL,
        fileNamePrefix: String,
        sourceBitrate: Int?,
        sourceVideoSize: PixelSize,
        captureTargetKind: RecordingCaptureTargetKind,
        recordingSources: RecordingSourceSet,
        overlaySettings: OverlaySettings,
        progressHandler: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> [ExportedVideo] {
        let keptRanges = session.keptRanges
        guard !keptRanges.isEmpty else {
            throw VideoExportError.noKeptRanges
        }

        let sourceAsset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()
        try insertTimelineRanges(from: sourceAsset, session: session, into: composition)
        let targetBitrate = settings.bitrateBitsPerSecond(sourceBitrate: sourceBitrate)
        let duration = keptRanges.reduce(0) { $0 + $1.duration }
        let presets = settings.normalizedAspectPresets
        var exportedVideos: [ExportedVideo] = []

        await progressHandler(0)
        for (presetIndex, preset) in presets.enumerated() {
            let outputURL = try makeOutputURL(
                outputDirectory: outputDirectory,
                fileNamePrefix: fileNamePrefix,
                settings: settings,
                preset: preset
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            guard let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw VideoExportError.cannotCreateExporter
            }

            exporter.outputURL = outputURL
            exporter.outputFileType = settings.format.avFileType
            exporter.shouldOptimizeForNetworkUse = true
            exporter.videoComposition = videoComposition(
                for: composition,
                preset: preset,
                sourceVideoSize: sourceVideoSize,
                settings: settings,
                captureTargetKind: captureTargetKind,
                recordingSources: recordingSources,
                overlaySettings: overlaySettings
            )

            if targetBitrate > 0, duration > 0 {
                exporter.fileLengthLimit = Int64((Double(targetBitrate) * duration) / 8.0)
            }

            let startProgress = Double(presetIndex) / Double(max(presets.count, 1))
            let progressSpan = 1.0 / Double(max(presets.count, 1))
            await progressHandler(startProgress)
            let progressTask = Task {
                while !Task.isCancelled {
                    let value = startProgress + (Double(exporter.progress) * progressSpan)
                    await progressHandler(min(max(value, 0), 1))
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }

            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    exporter.exportAsynchronously {
                        switch exporter.status {
                        case .completed:
                            continuation.resume()
                        case .failed:
                            continuation.resume(
                                throwing: VideoExportError.exportFailed(
                                    exporter.error?.localizedDescription ?? "Video export failed."
                                )
                            )
                        case .cancelled:
                            continuation.resume(throwing: VideoExportError.exportFailed("Video export was cancelled."))
                        default:
                            continuation.resume(throwing: VideoExportError.exportFailed("Video export did not complete."))
                        }
                    }
                }
            } catch {
                progressTask.cancel()
                throw error
            }
            progressTask.cancel()
            await progressHandler(startProgress + progressSpan)

            exportedVideos.append(ExportedVideo(preset: preset, url: outputURL))
        }

        return exportedVideos
    }

    private func videoComposition(
        for composition: AVMutableComposition,
        preset: ExportAspectPreset,
        sourceVideoSize: PixelSize,
        settings: ExportSettings,
        captureTargetKind: RecordingCaptureTargetKind,
        recordingSources: RecordingSourceSet,
        overlaySettings: OverlaySettings
    ) -> AVMutableVideoComposition? {
        switch preset {
        case .wide16x9:
            guard settings.framedCapture.isEnabled else {
                return nil
            }
            return makeFramedVideoComposition(
                for: composition,
                sourceVideoSize: sourceVideoSize,
                settings: settings.framedCapture,
                roundsForeground: captureTargetKind == .window
            )
        case .feed4x5, .vertical9x16:
            return makeAspectPresetVideoComposition(
                for: composition,
                preset: preset,
                cameraCrop: Self.cameraCrop(
                    sourceVideoSize: sourceVideoSize,
                    recordingSources: recordingSources,
                    overlaySettings: overlaySettings
                )
            )
        }
    }

    private func makeFramedVideoComposition(
        for composition: AVMutableComposition,
        sourceVideoSize: PixelSize,
        settings: FramedCaptureSettings,
        roundsForeground: Bool
    ) -> AVMutableVideoComposition {
        let renderSize = Self.fullHDAspectCanvasSize(for: sourceVideoSize)
        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            let image = FramedCaptureVideoRenderer.render(
                sourceImage: request.sourceImage,
                renderSize: renderSize,
                settings: settings,
                roundsForeground: roundsForeground
            )
            request.finish(with: image, context: nil)
        }
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        return videoComposition
    }

    private func makeAspectPresetVideoComposition(
        for composition: AVMutableComposition,
        preset: ExportAspectPreset,
        cameraCrop: CGRect?
    ) -> AVMutableVideoComposition {
        let renderSize = preset.renderSize
        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            let image = AspectPresetVideoRenderer.render(
                sourceImage: request.sourceImage,
                renderSize: renderSize,
                cameraCrop: cameraCrop
            )
            request.finish(with: image, context: nil)
        }
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        return videoComposition
    }

    private static func cameraCrop(
        sourceVideoSize: PixelSize,
        recordingSources: RecordingSourceSet,
        overlaySettings: OverlaySettings
    ) -> CGRect? {
        guard recordingSources.camera,
              overlaySettings.isEnabled,
              sourceVideoSize.width > 0,
              sourceVideoSize.height > 0,
              let rect = VideoCompositorLayout.overlayRect(
                screen: sourceVideoSize,
                camera: PixelSize(width: 16, height: 9),
                settings: overlaySettings
              ) else {
            return nil
        }

        return CGRect(
            x: rect.x / sourceVideoSize.width,
            y: rect.y / sourceVideoSize.height,
            width: rect.width / sourceVideoSize.width,
            height: rect.height / sourceVideoSize.height
        )
    }

    private static func fullHDAspectCanvasSize(for sourceVideoSize: PixelSize) -> CGSize {
        let targetAspectRatio = 16.0 / 9.0
        let sourceWidth = max(1, sourceVideoSize.width)
        let sourceHeight = max(1, sourceVideoSize.height)
        let sourceAspectRatio = sourceWidth / sourceHeight

        let width: Double
        let height: Double
        if sourceAspectRatio >= targetAspectRatio {
            width = sourceWidth
            height = sourceWidth / targetAspectRatio
        } else {
            height = sourceHeight
            width = sourceHeight * targetAspectRatio
        }

        return CGSize(
            width: CGFloat(max(2, Int(width.rounded()).roundedDownToEven)),
            height: CGFloat(max(2, Int(height.rounded()).roundedDownToEven))
        )
    }

    private func insertTimelineRanges(
        from asset: AVAsset,
        session: EditingSession,
        into composition: AVMutableComposition
    ) throws {
        try insertVideoRanges(session.keptRanges, from: asset, into: composition)
        try insertAudioRanges(
            videoRanges: session.keptRanges,
            audioRanges: session.audioKeptRanges,
            from: asset,
            into: composition
        )
    }

    private func insertVideoRanges(
        _ keptRanges: [TimelineRange],
        from asset: AVAsset,
        into composition: AVMutableComposition
    ) throws {
        let sourceTracks = asset.tracks(withMediaType: .video)
        var compositionTracks: [CMPersistentTrackID: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero

        for keptRange in keptRanges {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: keptRange.start, preferredTimescale: 600),
                duration: CMTime(seconds: keptRange.duration, preferredTimescale: 600)
            )

            for sourceTrack in sourceTracks {
                let compositionTrack: AVMutableCompositionTrack
                if let existing = compositionTracks[sourceTrack.trackID] {
                    compositionTrack = existing
                } else {
                    guard let newTrack = composition.addMutableTrack(
                        withMediaType: sourceTrack.mediaType,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        continue
                    }
                    newTrack.preferredTransform = sourceTrack.preferredTransform
                    compositionTracks[sourceTrack.trackID] = newTrack
                    compositionTrack = newTrack
                }

                try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: cursor)
            }

            cursor = cursor + timeRange.duration
        }
    }

    private func insertAudioRanges(
        videoRanges: [TimelineRange],
        audioRanges: [TimelineRange],
        from asset: AVAsset,
        into composition: AVMutableComposition
    ) throws {
        let sourceTracks = asset.tracks(withMediaType: .audio)
        guard !sourceTracks.isEmpty, !audioRanges.isEmpty else {
            return
        }

        var compositionTracks: [CMPersistentTrackID: AVMutableCompositionTrack] = [:]
        for mappedRange in mappedAudioRanges(videoRanges: videoRanges, audioRanges: audioRanges) {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: mappedRange.source.start, preferredTimescale: 600),
                duration: CMTime(seconds: mappedRange.source.duration, preferredTimescale: 600)
            )
            let outputStart = CMTime(seconds: mappedRange.outputStart, preferredTimescale: 600)

            for sourceTrack in sourceTracks {
                let compositionTrack = try compositionTrack(
                    for: sourceTrack,
                    in: composition,
                    cache: &compositionTracks
                )
                try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: outputStart)
            }
        }
    }

    private func mappedAudioRanges(
        videoRanges: [TimelineRange],
        audioRanges: [TimelineRange]
    ) -> [TimelineMappedRange] {
        var mappedRanges: [TimelineMappedRange] = []
        var outputCursor: TimeInterval = 0

        for videoRange in videoRanges {
            for audioRange in audioRanges {
                guard let sourceRange = videoRange.intersection(with: audioRange) else {
                    continue
                }
                mappedRanges.append(
                    TimelineMappedRange(
                        source: sourceRange,
                        outputStart: outputCursor + sourceRange.start - videoRange.start
                    )
                )
            }
            outputCursor += videoRange.duration
        }

        return mappedRanges
    }

    private func compositionTrack(
        for sourceTrack: AVAssetTrack,
        in composition: AVMutableComposition,
        cache: inout [CMPersistentTrackID: AVMutableCompositionTrack]
    ) throws -> AVMutableCompositionTrack {
        if let existing = cache[sourceTrack.trackID] {
            return existing
        }

        guard let newTrack = composition.addMutableTrack(
            withMediaType: sourceTrack.mediaType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoExportError.cannotCreateExporter
        }

        newTrack.preferredTransform = sourceTrack.preferredTransform
        cache[sourceTrack.trackID] = newTrack
        return newTrack
    }

    private func makeOutputURL(
        outputDirectory: URL,
        fileNamePrefix: String,
        settings: ExportSettings,
        preset: ExportAspectPreset
    ) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safePrefix = fileNamePrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let prefix = safePrefix.isEmpty ? "screen-recording" : safePrefix
        return outputDirectory
            .appendingPathComponent("\(prefix)-edited-\(preset.fileSuffix)-\(formatter.string(from: Date()))")
            .appendingPathExtension(settings.format.fileExtension)
    }
}

private struct TimelineMappedRange {
    var source: TimelineRange
    var outputStart: TimeInterval
}

private enum AspectPresetVideoRenderer {
    static func render(sourceImage: CIImage, renderSize: CGSize, cameraCrop: CGRect?) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: renderSize)
        let background = CIImage(color: .black).cropped(to: canvasRect)

        guard let cameraCrop else {
            let foreground = aspectFill(sourceImage, into: canvasRect)
            return foreground
                .composited(over: background)
                .cropped(to: canvasRect)
        }

        let cameraHeight = min(canvasRect.height * 0.46, canvasRect.width * 9.0 / 16.0)
        let topHeight = max(0, canvasRect.height - cameraHeight)
        guard topHeight > 1, cameraHeight > 1 else {
            let foreground = aspectFill(sourceImage, into: canvasRect)
            return foreground
                .composited(over: background)
                .cropped(to: canvasRect)
        }

        let topRect = CGRect(x: 0, y: cameraHeight, width: canvasRect.width, height: topHeight)
        let cameraRect = CGRect(x: 0, y: 0, width: canvasRect.width, height: cameraHeight)

        let topCrop = normalizedAspectFillCrop(
            targetAspectRatio: Double(topRect.width / topRect.height),
            sourceAspectRatio: sourceAspectRatio(for: sourceImage),
            excluding: cameraCrop
        )
        let topSource = crop(sourceImage, toNormalizedTopLeftRect: topCrop) ?? sourceImage
        let cameraSource = crop(sourceImage, toNormalizedTopLeftRect: cameraCrop) ?? sourceImage

        let topLayer = aspectFill(topSource, into: topRect)
        let cameraLayer = aspectFill(cameraSource, into: cameraRect)

        return cameraLayer
            .composited(over: topLayer.composited(over: background))
            .cropped(to: canvasRect)
    }

    private static func aspectFill(_ image: CIImage, into targetRect: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0, targetRect.width > 0, targetRect.height > 0 else {
            return image
        }

        let scale = max(targetRect.width / source.width, targetRect.height / source.height)
        let scaledWidth = source.width * scale
        let scaledHeight = source.height * scale
        let originX = targetRect.midX - scaledWidth / 2
        let originY = targetRect.midY - scaledHeight / 2

        return image
            .transformed(by: CGAffineTransform(translationX: -source.origin.x, y: -source.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: originX, y: originY))
            .cropped(to: targetRect)
    }

    private static func crop(_ image: CIImage, toNormalizedTopLeftRect normalizedRect: CGRect) -> CIImage? {
        let extent = image.extent
        let clampedRect = normalizedRect
            .standardized
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clampedRect.isNull,
              clampedRect.width > 0,
              clampedRect.height > 0,
              extent.width > 0,
              extent.height > 0 else {
            return nil
        }

        let cropRect = CGRect(
            x: extent.minX + (clampedRect.minX * extent.width),
            y: extent.minY + ((1 - clampedRect.maxY) * extent.height),
            width: clampedRect.width * extent.width,
            height: clampedRect.height * extent.height
        )
        return image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
    }

    private static func normalizedAspectFillCrop(
        targetAspectRatio: Double,
        sourceAspectRatio: Double,
        excluding excludedRect: CGRect?
    ) -> CGRect {
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let centeredCrop = aspectCrop(
            inside: fullRect,
            targetAspectRatio: targetAspectRatio,
            sourceAspectRatio: sourceAspectRatio
        ) ?? fullRect

        guard let excludedRect else {
            return centeredCrop
        }

        let clampedExcluded = excludedRect
            .standardized
            .intersection(fullRect)
        guard !clampedExcluded.isNull else {
            return centeredCrop
        }

        let candidateBounds = [
            CGRect(x: 0, y: 0, width: 1, height: clampedExcluded.minY),
            CGRect(x: 0, y: clampedExcluded.maxY, width: 1, height: 1 - clampedExcluded.maxY),
            CGRect(x: 0, y: 0, width: clampedExcluded.minX, height: 1),
            CGRect(x: clampedExcluded.maxX, y: 0, width: 1 - clampedExcluded.maxX, height: 1)
        ]
        let candidates = candidateBounds.compactMap { bounds in
            aspectCrop(
                inside: bounds,
                targetAspectRatio: targetAspectRatio,
                sourceAspectRatio: sourceAspectRatio
            )
        }

        return candidates.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        } ?? centeredCrop
    }

    private static func aspectCrop(
        inside bounds: CGRect,
        targetAspectRatio: Double,
        sourceAspectRatio: Double
    ) -> CGRect? {
        guard targetAspectRatio.isFinite,
              targetAspectRatio > 0,
              sourceAspectRatio.isFinite,
              sourceAspectRatio > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }

        let boundsAspectRatio = Double(bounds.width / bounds.height) * sourceAspectRatio
        let cropWidth: Double
        let cropHeight: Double
        if boundsAspectRatio > targetAspectRatio {
            cropHeight = Double(bounds.height)
            cropWidth = cropHeight * targetAspectRatio / sourceAspectRatio
        } else {
            cropWidth = Double(bounds.width)
            cropHeight = cropWidth * sourceAspectRatio / targetAspectRatio
        }

        guard cropWidth > 0,
              cropHeight > 0,
              cropWidth <= Double(bounds.width) + 0.0001,
              cropHeight <= Double(bounds.height) + 0.0001 else {
            return nil
        }

        return CGRect(
            x: bounds.midX - CGFloat(cropWidth / 2),
            y: bounds.midY - CGFloat(cropHeight / 2),
            width: CGFloat(cropWidth),
            height: CGFloat(cropHeight)
        )
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func sourceAspectRatio(for image: CIImage) -> Double {
        let extent = image.extent
        return Double(max(extent.width, 1) / max(extent.height, 1))
    }
}

private enum FramedCaptureVideoRenderer {
    static func render(
        sourceImage: CIImage,
        renderSize: CGSize,
        settings: FramedCaptureSettings,
        roundsForeground: Bool
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: renderSize)
        let background = backgroundImage(for: settings, extent: canvasRect)
        let padding = clampedScaled(settings.padding, renderSize: renderSize, maximumFraction: 0.22)
        let cornerRadius = clampedScaled(settings.cornerRadius, renderSize: renderSize, maximumFraction: 0.12)
        let contentBounds = canvasRect.insetBy(dx: padding, dy: padding)
        guard contentBounds.width > 1, contentBounds.height > 1 else {
            return background
        }

        let foregroundRect = aspectFitRect(
            sourceSize: sourceImage.extent.size,
            in: contentBounds,
            alignment: settings.alignment
        )
        let foreground = aspectFit(sourceImage, into: foregroundRect)
        let mask = roundsForeground
            ? roundedRectangleMask(rect: foregroundRect, radius: cornerRadius, extent: canvasRect)
            : rectangleMask(rect: foregroundRect, extent: canvasRect)

        var composed = background
        if settings.shadow != .off {
            composed = renderShadow(
                mask: mask,
                settings: settings,
                renderSize: renderSize,
                over: composed,
                extent: canvasRect
            )
        }

        return foreground
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: composed,
                    kCIInputMaskImageKey: mask
                ]
            )
            .cropped(to: canvasRect)
    }

    private static func backgroundImage(for settings: FramedCaptureSettings, extent: CGRect) -> CIImage {
        switch settings.background {
        case .solidColor:
            return CIImage(color: CIColor(hex: settings.solidColorHex))
                .cropped(to: extent)
        case .gradient:
            let filter = CIFilter(name: "CILinearGradient")
            filter?.setValue(CIVector(x: extent.minX, y: extent.maxY), forKey: "inputPoint0")
            filter?.setValue(CIVector(x: extent.maxX, y: extent.minY), forKey: "inputPoint1")
            filter?.setValue(CIColor(hex: settings.gradientStartHex), forKey: "inputColor0")
            filter?.setValue(CIColor(hex: settings.gradientEndHex), forKey: "inputColor1")
            return filter?.outputImage?.cropped(to: extent)
                ?? CIImage(color: CIColor(hex: settings.solidColorHex)).cropped(to: extent)
        }
    }

    private static func aspectFit(_ image: CIImage, into targetRect: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0, targetRect.width > 0, targetRect.height > 0 else {
            return image
        }

        let scale = min(targetRect.width / source.width, targetRect.height / source.height)
        let scaledWidth = source.width * scale
        let scaledHeight = source.height * scale
        let originX = targetRect.midX - scaledWidth / 2
        let originY = targetRect.midY - scaledHeight / 2

        return image
            .transformed(by: CGAffineTransform(translationX: -source.origin.x, y: -source.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: originX, y: originY))
            .cropped(to: targetRect)
    }

    private static func aspectFitRect(
        sourceSize: CGSize,
        in bounds: CGRect,
        alignment: FramedCaptureAlignment
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        let originY: CGFloat
        switch alignment {
        case .center:
            originY = bounds.midY - height / 2
        case .top:
            originY = bounds.maxY - height
        case .bottom:
            originY = bounds.minY
        }

        return CGRect(
            x: bounds.midX - width / 2,
            y: originY,
            width: width,
            height: height
        )
    }

    private static func rectangleMask(rect: CGRect, extent: CGRect) -> CIImage {
        CIImage(color: .white)
            .cropped(to: rect)
            .cropped(to: extent)
    }

    private static func roundedRectangleMask(rect: CGRect, radius: Double, extent: CGRect) -> CIImage {
        let filter = CIFilter(name: "CIRoundedRectangleGenerator")
        filter?.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter?.setValue(radius, forKey: "inputRadius")
        filter?.setValue(CIColor.white, forKey: "inputColor")
        return filter?.outputImage?.cropped(to: extent)
            ?? rectangleMask(rect: rect, extent: extent)
    }

    private static func renderShadow(
        mask: CIImage,
        settings: FramedCaptureSettings,
        renderSize: CGSize,
        over background: CIImage,
        extent: CGRect
    ) -> CIImage {
        let blurRadius = clampedScaled(settings.shadow.exportRadius, renderSize: renderSize, maximumFraction: 0.08)
        let yOffset = clampedScaled(settings.shadow.exportYOffset, renderSize: renderSize, maximumFraction: 0.08)
        let shadowMask = mask
            .transformed(by: CGAffineTransform(translationX: 0, y: -yOffset))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
        let shadow = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: settings.shadow.exportOpacity)
        )
        .cropped(to: extent)

        return shadow
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: background,
                    kCIInputMaskImageKey: shadowMask
                ]
            )
            .cropped(to: extent)
    }

    private static func scaled(_ value: Double, renderSize: CGSize) -> Double {
        let scale = min(renderSize.width / 1920, renderSize.height / 1080)
        return max(0, value * max(scale, 0.35))
    }

    private static func clampedScaled(
        _ value: Double,
        renderSize: CGSize,
        maximumFraction: Double
    ) -> Double {
        min(
            scaled(value, renderSize: renderSize),
            max(0, min(renderSize.width, renderSize.height) * maximumFraction)
        )
    }
}

private extension FramedCaptureShadow {
    var exportOpacity: Double {
        switch self {
        case .off:
            return 0
        case .soft:
            return 0.24
        case .strong:
            return 0.42
        }
    }

    var exportRadius: Double {
        switch self {
        case .off:
            return 0
        case .soft:
            return 26
        case .strong:
            return 42
        }
    }

    var exportYOffset: Double {
        switch self {
        case .off:
            return 0
        case .soft:
            return 14
        case .strong:
            return 24
        }
    }
}

private extension CIColor {
    convenience init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: cleaned)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        switch cleaned.count {
        case 6:
            red = CGFloat((value >> 16) & 0xff) / 255
            green = CGFloat((value >> 8) & 0xff) / 255
            blue = CGFloat(value & 0xff) / 255
        default:
            red = 0.07
            green = 0.08
            blue = 0.10
        }

        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}

private extension Int {
    var roundedDownToEven: Int {
        self - (self % 2)
    }
}

private extension ExportAspectPreset {
    var renderSize: CGSize {
        switch self {
        case .wide16x9:
            return CGSize(width: 1920, height: 1080)
        case .feed4x5:
            return CGSize(width: 1080, height: 1350)
        case .vertical9x16:
            return CGSize(width: 1080, height: 1920)
        }
    }
}

private extension TimelineRange {
    func intersection(with other: TimelineRange) -> TimelineRange? {
        let range = TimelineRange(start: max(start, other.start), end: min(end, other.end))
        return range.duration > 0 ? range : nil
    }
}

private extension ExportFormat {
    var avFileType: AVFileType {
        switch self {
        case .mp4:
            return .mp4
        case .mov:
            return .mov
        }
    }
}
#endif
