#if os(macOS)
import Foundation

enum PermissionRequirement: String, CaseIterable, Identifiable {
    case screenRecording
    case camera
    case microphone
    case systemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .camera:
            return "Camera"
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        }
    }

    var summary: String {
        switch self {
        case .screenRecording:
            return "Required to capture the selected display."
        case .camera:
            return "Required for the picture-in-picture webcam overlay."
        case .microphone:
            return "Required to capture narration."
        case .systemAudio:
            return "Available through ScreenCaptureKit after screen recording is approved."
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording:
            return "display"
        case .camera:
            return "video"
        case .microphone:
            return "mic"
        case .systemAudio:
            return "speaker.wave.2"
        }
    }
}

enum PermissionApprovalState: Equatable {
    case approved
    case notRequested
    case needsSettings
    case restricted
    case waitingForScreenRecording
    case unavailable

    var label: String {
        switch self {
        case .approved:
            return "Approved"
        case .notRequested:
            return "Not requested"
        case .needsSettings:
            return "Needs Settings"
        case .restricted:
            return "Restricted"
        case .waitingForScreenRecording:
            return "Waiting"
        case .unavailable:
            return "Unavailable"
        }
    }

    var isApproved: Bool {
        self == .approved
    }
}

struct PermissionChecklistItem: Identifiable, Equatable {
    let requirement: PermissionRequirement
    let state: PermissionApprovalState
    let isRequired: Bool

    var id: PermissionRequirement { requirement }

    var isSatisfied: Bool {
        isRequired ? state.isApproved : state == .approved || state == .unavailable
    }

    var detail: String {
        switch state {
        case .approved:
            return "Ready."
        case .notRequested:
            return "Grant access when macOS asks."
        case .needsSettings:
            return "Enable this app in System Settings, then return here."
        case .restricted:
            return "This Mac restricts access for this capability."
        case .waitingForScreenRecording:
            return "Approve Screen Recording first."
        case .unavailable:
            return "This macOS version does not support this capture path."
        }
    }

    var actionTitle: String? {
        switch state {
        case .approved, .restricted, .unavailable:
            return nil
        case .notRequested:
            return "Allow"
        case .needsSettings:
            return "Open Settings"
        case .waitingForScreenRecording:
            return "Open Settings"
        }
    }
}
#endif
