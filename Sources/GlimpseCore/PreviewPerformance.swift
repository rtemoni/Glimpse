import Foundation

/// Limits UI-bound preview work to a predictable cadence without accumulating drift.
public struct PreviewUpdateLimiter: Sendable {
    public let maximumUpdatesPerSecond: Double
    private var lastUpdateTime: TimeInterval?

    public init(maximumUpdatesPerSecond: Double) {
        self.maximumUpdatesPerSecond = max(1, maximumUpdatesPerSecond)
    }

    public mutating func shouldUpdate(at time: TimeInterval) -> Bool {
        guard let lastUpdateTime else {
            self.lastUpdateTime = time
            return true
        }

        if time < lastUpdateTime {
            self.lastUpdateTime = time
            return true
        }

        guard time - lastUpdateTime >= 1 / maximumUpdatesPerSecond else {
            return false
        }

        self.lastUpdateTime = time
        return true
    }

    public mutating func reset() {
        lastUpdateTime = nil
    }
}

/// Estimates delivered UI update rate over a short rolling window for live diagnostics.
public struct PreviewUpdateRateTracker: Sendable {
    public let windowDuration: TimeInterval
    private var updateTimes: [TimeInterval] = []

    public init(windowDuration: TimeInterval = 1) {
        self.windowDuration = max(0.25, windowDuration)
    }

    public mutating func recordUpdate(at time: TimeInterval) -> Double {
        if let last = updateTimes.last, time < last {
            updateTimes.removeAll(keepingCapacity: true)
        }

        updateTimes.append(time)
        let cutoff = time - windowDuration
        updateTimes.removeAll { $0 < cutoff }

        guard updateTimes.count > 1,
              let first = updateTimes.first,
              let last = updateTimes.last,
              last > first else {
            return 0
        }

        return Double(updateTimes.count - 1) / (last - first)
    }

    public mutating func reset() {
        updateTimes.removeAll(keepingCapacity: true)
    }
}
