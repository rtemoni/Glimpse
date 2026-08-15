#if os(macOS)
import SwiftUI
import AppKit

@main
struct GlimpseApp: App {
    @NSApplicationDelegateAdaptor(GlimpseAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = RecordingCoordinator()
    @StateObject private var statusItemController = RecordingStatusItemController()
    @StateObject private var updateController = AppUpdateController()

    init() {
        // Application bundles resolve AppIcon from Assets.car so macOS can apply
        // the current default, dark, or tinted Liquid Glass appearance. `swift
        // run` has no application bundle, so give that launch path the legacy
        // icon explicitly.
        if Bundle.main.bundleURL.pathExtension != "app",
           let image = Self.appIconImage() {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(updateController)
                .onAppear {
                    statusItemController.attach(to: coordinator)
                }
                .frame(minWidth: 380, minHeight: 220)
        }
        .defaultSize(width: 400, height: 240)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(updateController.isAttentionAction ? "Install Update…" : "Check for Updates…") {
                    updateController.performPrimaryAction()
                }
                .disabled(!updateController.isActionEnabled)
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            TimelineEditingCommands()
        }
    }

    private static func appIconImage() -> NSImage? {
        AppResources.image(named: "AppIcon", withExtension: "icns")
    }
}

private struct TimelineEditingCommands: Commands {
    @FocusedValue(\.timelineEditingActions) private var actions

    var body: some Commands {
        CommandMenu("Timeline") {
            Button("Play or Pause") {
                actions?.playPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(actions == nil)

            Divider()

            Button("Undo Timeline Edit") {
                actions?.undo()
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(actions?.canUndo != true)

            Button("Select All Clips") {
                actions?.selectAll()
            }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(actions?.canSelectAll != true)

            Button("Deselect All Clips") {
                actions?.deselectAll()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button(actions?.splitTitle ?? "Split Clip") {
                actions?.split()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(actions?.canSplit != true)

            Button("Delete Selected Clips") {
                actions?.delete()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(actions?.canDelete != true)

            Divider()

            Button("Go to Start") {
                actions?.goToStart()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(actions == nil)

            Button("Previous Clip") {
                actions?.moveToPreviousClip()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.option])
            .disabled(actions?.canMoveToPreviousClip != true)

            Button("Next Clip") {
                actions?.moveToNextClip()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.option])
            .disabled(actions?.canMoveToNextClip != true)

            Button("Cycle Split Target") {
                actions?.cycleClipMode()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(actions == nil)
        }
    }
}
#endif
