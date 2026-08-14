#if os(macOS)
import Foundation
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var statusMessage: String?

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()

        guard Self.isPackagedApplication else {
            statusMessage = "In-app updates are available in packaged builds."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            Task { @MainActor in
                self?.canCheckForUpdates = change.newValue ?? false
            }
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    func checkForUpdates() {
        guard let updaterController else {
            statusMessage = "Build Glimpse.app to test in-app updates."
            return
        }

        statusMessage = "Checking for updates…"
        updaterController.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusMessage = "Glimpse \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        statusMessage = "Glimpse is up to date."
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        // These Objective-C OSStatus constants are not exposed to Swift in every
        // binary distribution: no update, installation cancelled, install later.
        let expectedSparkleResults = [1001, 4007, 4008]
        guard nsError.domain != SUSparkleErrorDomain || !expectedSparkleResults.contains(nsError.code) else {
            return
        }
        statusMessage = "Unable to check for updates: \(error.localizedDescription)"
    }

    private static var isPackagedApplication: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !publicKey.isEmpty && !publicKey.hasPrefix("$")
    }
}
#endif
