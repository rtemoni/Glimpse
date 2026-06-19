import Foundation

public struct FrameSynchronizer<Payload: Sendable>: Sendable {
    private var cameraFrames: [TimedFrame<Payload>]
    private var lastSelectedFrame: TimedFrame<Payload>?
    private let retainedFrameLimit: Int

    public init(retainedFrameLimit: Int = 120) {
        self.cameraFrames = []
        self.lastSelectedFrame = nil
        self.retainedFrameLimit = max(1, retainedFrameLimit)
    }

    public mutating func appendCameraFrame(_ frame: TimedFrame<Payload>) {
        cameraFrames.append(frame)
        cameraFrames.sort { $0.timestamp < $1.timestamp }
        if cameraFrames.count > retainedFrameLimit {
            cameraFrames.removeFirst(cameraFrames.count - retainedFrameLimit)
        }
    }

    public mutating func frame(forScreenTimestamp timestamp: TimeInterval) -> TimedFrame<Payload>? {
        guard let selectedIndex = cameraFrames.lastIndex(where: { $0.timestamp <= timestamp }) else {
            return lastSelectedFrame
        }

        let selected = cameraFrames[selectedIndex]
        lastSelectedFrame = selected

        if selectedIndex > 0 {
            cameraFrames.removeFirst(selectedIndex)
        }

        return selected
    }

    public func latestFrame() -> TimedFrame<Payload>? {
        cameraFrames.last ?? lastSelectedFrame
    }
}
