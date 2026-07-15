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
            return "Uses the same System Settings grant as Screen Recording on modern macOS."
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
    case restartRequired
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
        case .restartRequired:
            return "Relaunch needed"
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
        switch (requirement, state) {
        case (_, .approved):
            return "Ready."
        case (_, .notRequested):
            return "Grant access when macOS asks."
        case (.screenRecording, .needsSettings):
            return "Enable Glimpse in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch Glimpse."
        case (.systemAudio, .needsSettings):
            return "Enable Glimpse under Screen & System Audio Recording, then relaunch Glimpse."
        case (_, .needsSettings):
            return "Enable this app in System Settings, then return here."
        case (.screenRecording, .restartRequired), (.systemAudio, .restartRequired):
            return "macOS applies this permission only after a full relaunch. Click Relaunch once the toggle is on."
        case (_, .restartRequired):
            return "Relaunch Glimpse to apply the updated permission."
        case (_, .restricted):
            return "This Mac restricts access for this capability."
        case (.systemAudio, .waitingForScreenRecording):
            return "Approve and relaunch for Screen Recording first."
        case (_, .waitingForScreenRecording):
            return "Approve Screen Recording first."
        case (_, .unavailable):
            return "This macOS version does not support this capture path."
        }
    }

    var actionTitle: String? {
        switch state {
        case .approved, .restricted, .unavailable:
            return nil
        case .notRequested:
            return "Allow"
        case .needsSettings, .waitingForScreenRecording:
            return "Open Settings"
        case .restartRequired:
            return "Relaunch"
        }
    }
}
#endif
