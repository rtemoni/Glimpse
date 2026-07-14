import Foundation

public enum RecordingLeadTrimPolicy {
    public static let defaultTrimDuration: TimeInterval = 1
    public static let minimumRetainedDuration: TimeInterval = 0.1

    /// Returns the synchronized source range that should remain after capture warmup.
    /// Very short recordings retain at least `minimumRetainedDuration` rather than
    /// producing an empty or invalid media file.
    public static func retainedRange(
        sourceDuration: TimeInterval,
        trimDuration: TimeInterval = defaultTrimDuration
    ) -> TimelineRange {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            return TimelineRange(start: 0, end: 0)
        }

        let duration = max(0, sourceDuration)
        let requestedTrim = max(0, trimDuration)
        let maximumSafeTrim = max(0, duration - minimumRetainedDuration)
        let actualTrim = min(requestedTrim, maximumSafeTrim)
        return TimelineRange(start: actualTrim, end: duration)
    }
}
