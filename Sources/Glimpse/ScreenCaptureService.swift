#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import GlimpseCore
import ScreenCaptureKit

struct CapturedVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
}

enum ScreenCaptureTarget: Identifiable {
    case display(SCDisplay)
    case window(SCWindow)

    var id: String {
        switch self {
        case .display(let display):
            return "display-\(display.displayID)"
        case .window(let window):
            return "window-\(window.windowID)"
        }
    }

    var title: String {
        switch self {
        case .display:
            return "Entire Screen"
        case .window(let window):
            return window.title?.isEmpty == false ? window.title ?? "Untitled Window" : "Untitled Window"
        }
    }

    var subtitle: String {
        switch self {
        case .display(let display):
            return "\(display.width) x \(display.height)"
        case .window(let window):
            let appName = window.owningApplication?.applicationName ?? "Unknown App"
            let width = Int(window.frame.width.rounded())
            let height = Int(window.frame.height.rounded())
            return "\(appName) - \(width) x \(height)"
        }
    }

    var systemImage: String {
        switch self {
        case .display:
            return "display"
        case .window:
            return "macwindow"
        }
    }

    func previewImage(maximumSize: CGSize) -> NSImage? {
        let cgImage: CGImage?
        switch self {
        case .display(let display):
            cgImage = CGDisplayCreateImage(CGDirectDisplayID(display.displayID))
        case .window(let window):
            cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(window.windowID),
                [.boundsIgnoreFraming, .bestResolution]
            )
        }

        guard let cgImage else {
            return nil
        }

        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let maxWidth = max(maximumSize.width, 1)
        let maxHeight = max(maximumSize.height, 1)
        let scale = min(1, min(maxWidth / max(sourceSize.width, 1), maxHeight / max(sourceSize.height, 1)))
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        )
    }
}

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    var frameHandler: ((CapturedVideoFrame) -> Void)?

    private let sampleQueue = DispatchQueue(label: "Glimpse.screen-samples")
    private var stream: SCStream?
    private var preparedSize = CGSize(width: 1920, height: 1080)

    static func availableTargets() async throws -> [ScreenCaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        let backstopDisplayID = CaptureTargetCatalog.backstopDisplayID(
            availableDisplayIDs: content.displays.map(\.displayID),
            mainDisplayID: CGMainDisplayID()
        )
        let displays = content.displays
            .filter { $0.displayID == backstopDisplayID }
            .map { ScreenCaptureTarget.display($0) }
        let windows = content.windows
            .filter { window in
                CaptureTargetCatalog.shouldIncludeWindow(
                    ownerBundleIdentifier: window.owningApplication?.bundleIdentifier,
                    ownerApplicationName: window.owningApplication?.applicationName,
                    title: window.title,
                    width: window.frame.width,
                    height: window.frame.height,
                    isOnScreen: window.isOnScreen,
                    ownBundleIdentifier: ownBundleID
                )
            }
            .map { ScreenCaptureTarget.window($0) }

        return displays + windows
    }

    func prepare(target: ScreenCaptureTarget?) async throws -> CGSize {
        let resolvedTarget: ScreenCaptureTarget
        if let target {
            resolvedTarget = target
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw RecorderRuntimeError.captureUnavailable("No display is available for screen capture.")
            }
            resolvedTarget = .display(display)
        }

        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()

        switch resolvedTarget {
        case .display(let display):
            preparedSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
            filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            configuration.width = display.width
            configuration.height = display.height
        case .window(let window):
            let scale = NSScreen.screens
                .first { screen in
                    screen.frame.intersects(window.frame)
                }?
                .backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let width = max(1, Int((window.frame.width * scale).rounded()))
            let height = max(1, Int((window.frame.height * scale).rounded()))
            preparedSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.width = width
            configuration.height = height
        }

        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        return preparedSize
    }

    func start() async throws {
        guard let stream else {
            throw RecorderRuntimeError.captureUnavailable("Screen capture has not been prepared.")
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
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
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

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The coordinator owns user-visible error state. Capture callbacks are kept hardware-only.
    }
}
#endif
