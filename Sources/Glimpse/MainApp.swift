#if os(macOS)
import SwiftUI
import AppKit

@main
struct GlimpseApp: App {
    @NSApplicationDelegateAdaptor(GlimpseAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = RecordingCoordinator()
    @StateObject private var statusItemController = RecordingStatusItemController()

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
                .onAppear {
                    statusItemController.attach(to: coordinator)
                }
                .frame(minWidth: 380, minHeight: 220)
        }
        .defaultSize(width: 400, height: 240)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task {
                        await coordinator.checkForUpdates(userInitiated: true)
                    }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
    }

    private static func appIconImage() -> NSImage? {
        AppResources.image(named: "AppIcon", withExtension: "icns")
    }
}
#endif
