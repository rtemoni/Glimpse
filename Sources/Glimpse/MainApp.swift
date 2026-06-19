#if os(macOS)
import SwiftUI
import AppKit

@main
struct GlimpseApp: App {
    @StateObject private var coordinator = RecordingCoordinator()

    init() {
        if let image = Self.appIconImage() {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 380, minHeight: 220)
        }
        .defaultSize(width: 400, height: 240)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private static func appIconImage() -> NSImage? {
        if let bundledIconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: bundledIconURL)
        }
        return Bundle.module.image(forResource: "AppIcon")
    }
}
#endif
