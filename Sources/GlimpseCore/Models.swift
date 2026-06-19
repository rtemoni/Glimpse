import Foundation

public enum RecordingState: String, CaseIterable, Equatable, Sendable {
    case idle
    case preparing
    case ready
    case recording
    case paused
    case stopping
    case error

    public var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .ready:
            return "Ready"
        case .recording:
            return "Recording"
        case .paused:
            return "Paused"
        case .stopping:
            return "Stopping"
        case .error:
            return "Error"
        }
    }
}

public enum RecorderFileFormat: String, CaseIterable, Identifiable, Sendable {
    case mov
    case mp4

    public var id: String { rawValue }

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .mov:
            return "QuickTime MOV"
        case .mp4:
            return "MPEG-4 MP4"
        }
    }
}

public enum OverlaySizePreset: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        case .large:
            return "Large"
        }
    }

    public var screenWidthFraction: Double {
        switch self {
        case .small:
            return 0.16
        case .medium:
            return 0.20
        case .large:
            return 0.26
        }
    }
}

public enum OverlayPosition: String, CaseIterable, Identifiable, Sendable {
    case bottomLeft
    case topLeft
    case topRight
    case bottomRight
    case topMiddle
    case bottomMiddle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bottomLeft:
            return "Bottom Left"
        case .topLeft:
            return "Top Left"
        case .topRight:
            return "Top Right"
        case .bottomRight:
            return "Bottom Right"
        case .topMiddle:
            return "Top Middle"
        case .bottomMiddle:
            return "Bottom Middle"
        }
    }
}

public enum OverlayShape: String, CaseIterable, Identifiable, Sendable {
    case rectangle
    case square
    case circle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rectangle:
            return "Rectangle"
        case .square:
            return "Square"
        case .circle:
            return "Circle"
        }
    }
}

public struct PixelSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in pixel coordinates with origin at the top-left of the output frame.
public struct PixelRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OverlaySettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var sizePreset: OverlaySizePreset
    public var position: OverlayPosition
    public var shape: OverlayShape
    public var margin: Double
    public var minimumWidth: Double
    public var maximumWidth: Double
    public var cornerRadius: Double
    public var hasShadow: Bool
    public var borderWidth: Double

    public init(
        isEnabled: Bool = true,
        sizePreset: OverlaySizePreset = .medium,
        position: OverlayPosition = .bottomLeft,
        shape: OverlayShape = .rectangle,
        margin: Double = 24,
        minimumWidth: Double = 200,
        maximumWidth: Double = 400,
        cornerRadius: Double = 16,
        hasShadow: Bool = true,
        borderWidth: Double = 1
    ) {
        self.isEnabled = isEnabled
        self.sizePreset = sizePreset
        self.position = position
        self.shape = shape
        self.margin = margin
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.cornerRadius = cornerRadius
        self.hasShadow = hasShadow
        self.borderWidth = borderWidth
    }
}

public struct RecorderSettings: Equatable, Sendable {
    public var outputDirectory: URL
    public var fileNamePrefix: String
    public var fileFormat: RecorderFileFormat
    public var selectedCameraID: String?
    public var selectedMicrophoneID: String?
    public var microphoneEnabled: Bool
    public var systemAudioEnabled: Bool
    public var microphoneGain: Float
    public var systemAudioGain: Float
    public var overlay: OverlaySettings

    public init(
        outputDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true),
        fileNamePrefix: String = "screen-recording",
        fileFormat: RecorderFileFormat = .mov,
        selectedCameraID: String? = nil,
        selectedMicrophoneID: String? = nil,
        microphoneEnabled: Bool = true,
        systemAudioEnabled: Bool = true,
        microphoneGain: Float = 1,
        systemAudioGain: Float = 1,
        overlay: OverlaySettings = OverlaySettings()
    ) {
        self.outputDirectory = outputDirectory
        self.fileNamePrefix = fileNamePrefix
        self.fileFormat = fileFormat
        self.selectedCameraID = selectedCameraID
        self.selectedMicrophoneID = selectedMicrophoneID
        self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
        self.microphoneGain = microphoneGain
        self.systemAudioGain = systemAudioGain
        self.overlay = overlay
    }

    public func nextOutputURL(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safePrefix = fileNamePrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let prefix = safePrefix.isEmpty ? "screen-recording" : safePrefix
        return outputDirectory
            .appendingPathComponent("\(prefix)-\(formatter.string(from: now))")
            .appendingPathExtension(fileFormat.fileExtension)
    }
}

public struct SourceDevice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct TimedFrame<Payload: Sendable>: Sendable {
    public var timestamp: TimeInterval
    public var payload: Payload

    public init(timestamp: TimeInterval, payload: Payload) {
        self.timestamp = timestamp
        self.payload = payload
    }
}

extension TimedFrame: Equatable where Payload: Equatable {}
