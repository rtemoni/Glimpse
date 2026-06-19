#if os(macOS)
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import GlimpseCore

final class VideoCompositor {
    private let context = CIContext(options: nil)
    private var frameSynchronizer = FrameSynchronizer<CapturedVideoFrame>()

    func updateCameraFrame(_ frame: CapturedVideoFrame) {
        frameSynchronizer.appendCameraFrame(TimedFrame(timestamp: frame.timestamp.seconds, payload: frame))
    }

    func compose(screenFrame: CapturedVideoFrame, settings: OverlaySettings) -> CVPixelBuffer? {
        guard let cameraFrame = (
            frameSynchronizer.frame(forScreenTimestamp: screenFrame.timestamp.seconds)
                ?? frameSynchronizer.latestFrame()
        )?.payload else {
            return screenFrame.pixelBuffer
        }

        let screenSize = PixelSize(
            width: Double(CVPixelBufferGetWidth(screenFrame.pixelBuffer)),
            height: Double(CVPixelBufferGetHeight(screenFrame.pixelBuffer))
        )
        let cameraSize = PixelSize(
            width: Double(CVPixelBufferGetWidth(cameraFrame.pixelBuffer)),
            height: Double(CVPixelBufferGetHeight(cameraFrame.pixelBuffer))
        )
        guard let topLeftRect = VideoCompositorLayout.overlayRect(
            screen: screenSize,
            camera: cameraSize,
            settings: settings
        ) else {
            return screenFrame.pixelBuffer
        }

        let outputRect = CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height)
        let overlayRect = CGRect(
            x: topLeftRect.x,
            y: screenSize.height - topLeftRect.y - topLeftRect.height,
            width: topLeftRect.width,
            height: topLeftRect.height
        )

        let background = CIImage(cvPixelBuffer: screenFrame.pixelBuffer)
            .cropped(to: outputRect)
        let cameraImage = CIImage(cvPixelBuffer: cameraFrame.pixelBuffer)
        let overlay = aspectFill(cameraImage, into: overlayRect)
        let mask = overlayMask(rect: overlayRect, settings: settings, extent: outputRect)

        var composed = background
        if settings.hasShadow {
            composed = renderShadow(mask: mask, over: composed, extent: outputRect)
        }

        composed = overlay.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: composed,
                kCIInputMaskImageKey: mask
            ]
        )
        .cropped(to: outputRect)

        if settings.borderWidth > 0 {
            composed = renderBorder(
                rect: overlayRect,
                settings: settings,
                borderWidth: settings.borderWidth,
                over: composed,
                extent: outputRect
            )
        }

        guard let outputBuffer = makePixelBuffer(width: Int(screenSize.width), height: Int(screenSize.height)) else {
            return nil
        }
        context.render(composed, to: outputBuffer)
        return outputBuffer
    }

    func makePreviewImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private func aspectFill(_ image: CIImage, into targetRect: CGRect) -> CIImage {
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

    private func overlayMask(rect: CGRect, settings: OverlaySettings, extent: CGRect) -> CIImage {
        let filter = CIFilter(name: "CIRoundedRectangleGenerator")
        filter?.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter?.setValue(maskRadius(for: rect, settings: settings), forKey: "inputRadius")
        filter?.setValue(CIColor.white, forKey: "inputColor")
        return filter?.outputImage?.cropped(to: extent) ?? CIImage(color: .white).cropped(to: rect)
    }

    private func maskRadius(for rect: CGRect, settings: OverlaySettings) -> Double {
        switch settings.shape {
        case .circle:
            return min(rect.width, rect.height) / 2
        case .rectangle, .square:
            return min(settings.cornerRadius, min(rect.width, rect.height) / 2)
        }
    }

    private func renderShadow(mask: CIImage, over background: CIImage, extent: CGRect) -> CIImage {
        let shadowMask = mask
            .transformed(by: CGAffineTransform(translationX: 0, y: -5))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10])
            .cropped(to: extent)
        let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.32))
            .cropped(to: extent)
        return shadow.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: shadowMask
            ]
        )
        .cropped(to: extent)
    }

    private func renderBorder(
        rect: CGRect,
        settings: OverlaySettings,
        borderWidth: Double,
        over image: CIImage,
        extent: CGRect
    ) -> CIImage {
        let outerMask = overlayMask(rect: rect, settings: settings, extent: extent)
        let innerRect = rect.insetBy(dx: borderWidth, dy: borderWidth)
        var innerSettings = settings
        innerSettings.cornerRadius = max(0, settings.cornerRadius - borderWidth)
        let innerMask = overlayMask(rect: innerRect, settings: innerSettings, extent: extent)
        let ringMask = outerMask.applyingFilter(
            "CISourceOutCompositing",
            parameters: [kCIInputBackgroundImageKey: innerMask]
        )
        let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.45))
            .cropped(to: extent)
        return border.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: ringMask
            ]
        )
        .cropped(to: extent)
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        return pixelBuffer
    }
}
#endif
