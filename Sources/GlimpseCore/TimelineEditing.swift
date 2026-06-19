import Foundation

public struct TimelineRange: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: TimeInterval {
        max(0, end - start)
    }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }

    public func clamped(to bounds: TimelineRange) -> TimelineRange? {
        let clampedStart = max(bounds.start, min(bounds.end, start))
        let clampedEnd = max(bounds.start, min(bounds.end, end))
        let range = TimelineRange(start: clampedStart, end: clampedEnd)
        return range.duration > 0 ? range : nil
    }
}

public struct EditingSession: Codable, Equatable, Sendable {
    public var sourceDuration: TimeInterval
    public var trimStart: TimeInterval
    public var trimEnd: TimeInterval
    public private(set) var splitPoints: [TimeInterval]
    public private(set) var removedRanges: [TimelineRange]
    public private(set) var audioSplitPoints: [TimeInterval]
    public private(set) var audioRemovedRanges: [TimelineRange]

    public init(sourceDuration: TimeInterval) {
        let duration = max(0, sourceDuration)
        self.sourceDuration = duration
        self.trimStart = 0
        self.trimEnd = duration
        self.splitPoints = []
        self.removedRanges = []
        self.audioSplitPoints = []
        self.audioRemovedRanges = []
    }

    public var trimRange: TimelineRange {
        TimelineRange(start: trimStart, end: trimEnd)
    }

    public var keptRanges: [TimelineRange] {
        keptRanges(removing: normalizedRemovedRanges(removedRanges))
    }

    public var clipRanges: [TimelineRange] {
        clipRanges(
            in: keptRanges,
            splitPoints: normalizedSplitPoints(splitPoints, removedRanges: normalizedRemovedRanges(removedRanges))
        )
    }

    public var audioKeptRanges: [TimelineRange] {
        keptRanges(removing: normalizedRemovedRanges(audioRemovedRanges))
    }

    public var audioClipRanges: [TimelineRange] {
        clipRanges(
            in: audioKeptRanges,
            splitPoints: normalizedSplitPoints(
                audioSplitPoints,
                removedRanges: normalizedRemovedRanges(audioRemovedRanges)
            )
        )
    }

    public mutating func setTrim(start: TimeInterval, end: TimeInterval) {
        let boundedStart = Self.clamp(start, lowerBound: 0, upperBound: sourceDuration)
        let boundedEnd = Self.clamp(end, lowerBound: 0, upperBound: sourceDuration)
        trimStart = min(boundedStart, boundedEnd)
        trimEnd = max(boundedStart, boundedEnd)
        normalizeVideoEdits()
        normalizeAudioEdits()
    }

    public mutating func resetTrim() {
        trimStart = 0
        trimEnd = sourceDuration
        normalizeVideoEdits()
        normalizeAudioEdits()
    }

    @discardableResult
    public mutating func split(at time: TimeInterval, syncAudio: Bool = true) -> Bool {
        let splitPoint = Self.clamp(time, lowerBound: trimStart, upperBound: trimEnd)
        let minimumClipDuration: TimeInterval = 0.05
        guard clipRanges.contains(where: { range in
            splitPoint > range.start + minimumClipDuration
                && splitPoint < range.end - minimumClipDuration
        }) else {
            return false
        }

        splitPoints.append(splitPoint)
        normalizeVideoEdits()
        if syncAudio,
           audioClipRanges.contains(where: { range in
            splitPoint > range.start + minimumClipDuration
                && splitPoint < range.end - minimumClipDuration
        }) {
            audioSplitPoints.append(splitPoint)
            normalizeAudioEdits()
        }
        return true
    }

    @discardableResult
    public mutating func splitAudio(at time: TimeInterval) -> Bool {
        let splitPoint = Self.clamp(time, lowerBound: trimStart, upperBound: trimEnd)
        let minimumClipDuration: TimeInterval = 0.05
        guard audioClipRanges.contains(where: { range in
            splitPoint > range.start + minimumClipDuration
                && splitPoint < range.end - minimumClipDuration
        }) else {
            return false
        }

        audioSplitPoints.append(splitPoint)
        normalizeAudioEdits()
        return true
    }

    public mutating func deleteClip(_ clip: TimelineRange) {
        addRemovedRange(start: clip.start, end: clip.end)
    }

    public mutating func deleteAudioClip(_ clip: TimelineRange) {
        addAudioRemovedRange(start: clip.start, end: clip.end)
    }

    public mutating func addRemovedRange(start: TimeInterval, end: TimeInterval) {
        guard let range = TimelineRange(start: start, end: end).clamped(to: trimRange) else {
            return
        }
        removedRanges.append(range)
        normalizeVideoEdits()
        addAudioRemovedRange(start: range.start, end: range.end)
    }

    public mutating func addAudioRemovedRange(start: TimeInterval, end: TimeInterval) {
        guard let range = TimelineRange(start: start, end: end).clamped(to: trimRange) else {
            return
        }
        audioRemovedRanges.append(range)
        normalizeAudioEdits()
    }

    public mutating func removeRemovedRange(at index: Int) {
        guard removedRanges.indices.contains(index) else {
            return
        }
        removedRanges.remove(at: index)
        normalizeVideoEdits()
    }

    public mutating func removeAllCuts() {
        removedRanges = []
        splitPoints = []
        audioRemovedRanges = []
        audioSplitPoints = []
    }

    public mutating func removeAllAudioCuts() {
        audioRemovedRanges = []
        audioSplitPoints = []
    }

    private mutating func normalizeVideoEdits() {
        removedRanges = normalizedRemovedRanges(removedRanges)
        splitPoints = normalizedSplitPoints(splitPoints, removedRanges: removedRanges)
    }

    private mutating func normalizeAudioEdits() {
        audioRemovedRanges = normalizedRemovedRanges(audioRemovedRanges)
        audioSplitPoints = normalizedSplitPoints(audioSplitPoints, removedRanges: audioRemovedRanges)
    }

    private func keptRanges(removing removedRanges: [TimelineRange]) -> [TimelineRange] {
        let bounds = trimRange
        guard bounds.duration > 0 else {
            return []
        }

        var ranges: [TimelineRange] = []
        var cursor = bounds.start

        for removed in removedRanges {
            if removed.start > cursor {
                ranges.append(TimelineRange(start: cursor, end: removed.start))
            }
            cursor = max(cursor, removed.end)
        }

        if cursor < bounds.end {
            ranges.append(TimelineRange(start: cursor, end: bounds.end))
        }

        return ranges.filter { $0.duration > 0 }
    }

    private func clipRanges(
        in keptRanges: [TimelineRange],
        splitPoints: [TimeInterval]
    ) -> [TimelineRange] {
        keptRanges.flatMap { keptRange in
            let points = ([keptRange.start] + splitPoints.filter {
                $0 > keptRange.start && $0 < keptRange.end
            } + [keptRange.end])

            return zip(points, points.dropFirst()).compactMap { start, end in
                let range = TimelineRange(start: start, end: end)
                return range.duration > 0 ? range : nil
            }
        }
    }

    private func normalizedSplitPoints(
        _ points: [TimeInterval],
        removedRanges: [TimelineRange]
    ) -> [TimeInterval] {
        let lowerBound = trimStart
        let upperBound = trimEnd
        let minimumClipDuration: TimeInterval = 0.05

        return points
            .map { Self.clamp($0, lowerBound: lowerBound, upperBound: upperBound) }
            .filter { point in
                point > lowerBound + minimumClipDuration
                    && point < upperBound - minimumClipDuration
                    && !removedRanges.contains(where: { $0.contains(point) })
            }
            .sorted()
            .reduce(into: []) { result, point in
                guard let last = result.last else {
                    result.append(point)
                    return
                }
                if abs(point - last) > minimumClipDuration {
                    result.append(point)
                }
            }
    }

    private func normalizedRemovedRanges(_ ranges: [TimelineRange]) -> [TimelineRange] {
        let bounds = trimRange
        let sorted = ranges
            .compactMap { $0.clamped(to: bounds) }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.end < rhs.end
                }
                return lhs.start < rhs.start
            }

        var normalized: [TimelineRange] = []
        for range in sorted {
            guard var last = normalized.last else {
                normalized.append(range)
                continue
            }

            if range.start <= last.end {
                last.end = max(last.end, range.end)
                normalized[normalized.count - 1] = last
            } else {
                normalized.append(range)
            }
        }

        return normalized
    }

    private static func clamp(
        _ value: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        max(lowerBound, min(upperBound, value))
    }
}

public enum ExportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case mp4
    case mov

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mp4:
            return "MP4"
        case .mov:
            return "MOV"
        }
    }

    public var fileExtension: String {
        rawValue
    }
}

public enum ExportBitratePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high
    case sourceQuality
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .sourceQuality:
            return "Source Quality"
        case .custom:
            return "Custom"
        }
    }

    public func bitrateBitsPerSecond(sourceBitrate: Int?, customMegabits: Double) -> Int {
        switch self {
        case .low:
            return 5_000_000
        case .medium:
            return 12_000_000
        case .high:
            return 30_000_000
        case .sourceQuality:
            return sourceBitrate ?? 50_000_000
        case .custom:
            return max(1_000_000, Int(customMegabits * 1_000_000))
        }
    }
}

public enum FramedCaptureBackground: String, CaseIterable, Codable, Identifiable, Sendable {
    case gradient
    case solidColor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gradient:
            return "Gradient"
        case .solidColor:
            return "Color"
        }
    }
}

public enum FramedCaptureShadow: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case soft
    case strong

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .soft:
            return "Soft"
        case .strong:
            return "Strong"
        }
    }
}

public enum FramedCaptureAlignment: String, CaseIterable, Codable, Identifiable, Sendable {
    case center
    case top
    case bottom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .center:
            return "Center"
        case .top:
            return "Top"
        case .bottom:
            return "Bottom"
        }
    }
}

public enum ExportAspectPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case wide16x9
    case feed4x5
    case vertical9x16

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wide16x9:
            return "16:9"
        case .feed4x5:
            return "4:5"
        case .vertical9x16:
            return "9:16"
        }
    }

    public var description: String {
        switch self {
        case .wide16x9:
            return "Full"
        case .feed4x5:
            return "Feed"
        case .vertical9x16:
            return "Short"
        }
    }

    public var fileSuffix: String {
        switch self {
        case .wide16x9:
            return "16x9"
        case .feed4x5:
            return "4x5"
        case .vertical9x16:
            return "9x16"
        }
    }
}

public struct FramedCaptureSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var background: FramedCaptureBackground
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: FramedCaptureShadow
    public var alignment: FramedCaptureAlignment
    public var solidColorHex: String
    public var gradientStartHex: String
    public var gradientEndHex: String

    public init(
        isEnabled: Bool = false,
        background: FramedCaptureBackground = .gradient,
        padding: Double = 30,
        cornerRadius: Double = 20,
        shadow: FramedCaptureShadow = .soft,
        alignment: FramedCaptureAlignment = .center,
        solidColorHex: String = "#111318",
        gradientStartHex: String = "#246BFE",
        gradientEndHex: String = "#FB6F4D"
    ) {
        self.isEnabled = isEnabled
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.alignment = alignment
        self.solidColorHex = solidColorHex
        self.gradientStartHex = gradientStartHex
        self.gradientEndHex = gradientEndHex
    }
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var format: ExportFormat
    public var bitratePreset: ExportBitratePreset
    public var customBitrateMegabits: Double
    public var framedCapture: FramedCaptureSettings
    public var aspectPresets: [ExportAspectPreset]

    public init(
        format: ExportFormat = .mp4,
        bitratePreset: ExportBitratePreset = .sourceQuality,
        customBitrateMegabits: Double = 20,
        framedCapture: FramedCaptureSettings = FramedCaptureSettings(),
        aspectPresets: [ExportAspectPreset] = [.wide16x9]
    ) {
        self.format = format
        self.bitratePreset = bitratePreset
        self.customBitrateMegabits = customBitrateMegabits
        self.framedCapture = framedCapture
        self.aspectPresets = aspectPresets
    }

    public func bitrateBitsPerSecond(sourceBitrate: Int?) -> Int {
        bitratePreset.bitrateBitsPerSecond(
            sourceBitrate: sourceBitrate,
            customMegabits: customBitrateMegabits
        )
    }

    public var normalizedAspectPresets: [ExportAspectPreset] {
        var seen: Set<ExportAspectPreset> = []
        let unique = aspectPresets.filter { preset in
            seen.insert(preset).inserted
        }
        return unique.isEmpty ? [.wide16x9] : unique
    }
}
