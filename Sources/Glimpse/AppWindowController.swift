#if os(macOS)
import AppKit
import Foundation
import GlimpseCore
import SwiftUI

@MainActor
private final class GlimpseMainWindowRegistry {
    static let shared = GlimpseMainWindowRegistry()

    weak var window: NSWindow?
    var lastMinimizedRecordingToken: UUID?
    var didRestoreCompletedRecording = false
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
    let shouldRestoreAfterRecording: Bool

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

            if let recordingPresentationToken,
               registry.lastMinimizedRecordingToken != recordingPresentationToken {
                registry.lastMinimizedRecordingToken = recordingPresentationToken
                window.miniaturize(nil)
            }

            if shouldRestoreAfterRecording,
               !registry.didRestoreCompletedRecording {
                registry.didRestoreCompletedRecording = true
                GlimpseWindowPresenter.showMainWindow(preferredWindow: window)
            } else if !shouldRestoreAfterRecording {
                registry.didRestoreCompletedRecording = false
            }
        }
    }
}

@MainActor
final class GlimpseAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            GlimpseWindowPresenter.showMainWindow()
        }
        return true
    }
}
#endif
