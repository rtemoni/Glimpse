#if os(macOS)
import Combine
import CoreGraphics
import Foundation

struct CapturePreviewFrame: @unchecked Sendable {
    let image: CGImage
    let updatesPerSecond: Double
}

@MainActor
final class PreviewFrameStore: ObservableObject {
    @Published private(set) var frame: CapturePreviewFrame?

    func publish(_ frame: CapturePreviewFrame) {
        self.frame = frame
    }

    func clear() {
        frame = nil
    }
}

@MainActor
final class AudioMeterStore: ObservableObject {
    @Published private(set) var level: Double = 0
    @Published private(set) var updatesPerSecond: Double = 0

    func publish(rawLevel: Double, updatesPerSecond: Double) {
        let clampedLevel = min(1, max(0, rawLevel))
        let smoothing = clampedLevel >= level ? 0.62 : 0.24
        level += (clampedLevel - level) * smoothing
        self.updatesPerSecond = updatesPerSecond
    }

    func clear() {
        level = 0
        updatesPerSecond = 0
    }
}
#endif
