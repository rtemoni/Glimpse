#if os(macOS)
import AppKit
import Foundation
import GlimpseCore
import SwiftUI

enum GlimpseWindowPresenter {
    static func showMainWindow(preferredWindow: NSWindow? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let preferredWindow {
            show(window: preferredWindow)
            return
        }

        let candidate = NSApp.windows.first { window in
            window.canBecomeMain && !window.isReleasedWhenClosed
        } ?? NSApp.windows.first

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

            if let recordingPresentationToken,
               context.coordinator.lastMinimizedToken != recordingPresentationToken {
                context.coordinator.lastMinimizedToken = recordingPresentationToken
                window.miniaturize(nil)
            }

            if shouldRestoreAfterRecording,
               !context.coordinator.didRestoreAfterRecording {
                context.coordinator.didRestoreAfterRecording = true
                GlimpseWindowPresenter.showMainWindow(preferredWindow: window)
            } else if !shouldRestoreAfterRecording {
                context.coordinator.didRestoreAfterRecording = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastMinimizedToken: UUID?
        var didRestoreAfterRecording = false
    }
}
#endif
