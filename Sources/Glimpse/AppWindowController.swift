#if os(macOS)
import AppKit
import Foundation
import GlimpseCore
import SwiftUI

@MainActor
private final class GlimpseMainWindowRegistry {
    static let shared = GlimpseMainWindowRegistry()

    weak var window: NSWindow?
    var lastHiddenRecordingToken: UUID?
    var isHiddenForRecording = false
}

@MainActor
enum GlimpseWindowPresenter {
    static func showMainWindow(preferredWindow: NSWindow? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        var candidate = preferredWindow
        if candidate == nil {
            candidate = GlimpseMainWindowRegistry.shared.window
        }
        if candidate == nil {
            candidate = NSApp.mainWindow
        }
        if candidate == nil {
            candidate = NSApp.keyWindow
        }
        if candidate == nil {
            candidate = NSApp.windows.first { window in
                window.canBecomeMain && !window.isReleasedWhenClosed
            }
        }

        if let candidate {
            show(window: candidate)
        }
    }

    private static func show(window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

struct RecordingWindowLifecycleController: NSViewRepresentable {
    let recordingPresentationToken: UUID?
    let isRecordingActive: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }
            let registry = GlimpseMainWindowRegistry.shared
            registry.window = window

            if isRecordingActive,
               let recordingPresentationToken,
               registry.lastHiddenRecordingToken != recordingPresentationToken {
                registry.lastHiddenRecordingToken = recordingPresentationToken
                registry.isHiddenForRecording = true
                window.isExcludedFromWindowsMenu = true
                window.orderOut(nil)
            } else if !isRecordingActive, registry.isHiddenForRecording {
                registry.isHiddenForRecording = false
                registry.lastHiddenRecordingToken = nil
                window.isExcludedFromWindowsMenu = false
                GlimpseWindowPresenter.showMainWindow(preferredWindow: window)
            }
        }
    }
}

@MainActor
final class GlimpseAppDelegate: NSObject, NSApplicationDelegate {
    private weak var coordinator: RecordingCoordinator?
    private let recordingStatusItemController = RecordingStatusItemController()

    func attach(to coordinator: RecordingCoordinator) {
        guard self.coordinator !== coordinator else {
            return
        }

        self.coordinator = coordinator
        recordingStatusItemController.attach(to: coordinator)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        stopRecordingIfForegrounded()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if GlimpseMainWindowRegistry.shared.isHiddenForRecording {
            stopRecordingIfForegrounded()
            return false
        }
        if !flag {
            GlimpseWindowPresenter.showMainWindow()
        }
        return true
    }

    private func stopRecordingIfForegrounded() {
        guard let coordinator,
              RecordingAppActivationPolicy.shouldStopRecording(
                state: coordinator.state,
                isWindowHiddenForRecording: GlimpseMainWindowRegistry.shared.isHiddenForRecording
              ) else {
            return
        }

        Task { @MainActor [weak coordinator] in
            await coordinator?.stopRecording()
        }
    }
}
#endif
