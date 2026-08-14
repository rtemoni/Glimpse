#if os(macOS)
import Foundation
import Sparkle
import SwiftUI

enum AppUpdateAlertKind {
    case updateAvailable
    case installationChoice
    case information
}

struct AppUpdateAlert: Identifiable {
    let id = UUID()
    let kind: AppUpdateAlertKind
    let title: String
    let message: String
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Phase: Equatable {
        case unavailable
        case idle
        case checking
        case available(version: String)
        case downloading(percent: Int)
        case preparing
        case ready(version: String)
        case installing
        case failed
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var presentedAlert: AppUpdateAlert?

    /// Installed by the app shell so settings are flushed immediately before
    /// Sparkle is allowed to replace the bundle.
    var configurationBackupHandler: (() throws -> Void)?

    private let userDriver = GlimpseUpdateUserDriver()
    private var updater: SPUUpdater?
    private var canCheckObservation: NSKeyValueObservation?
    private var updateFoundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyToInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var informationDismissHandler: (() -> Void)?
    private var availableVersion: String?
    private var expectedDownloadBytes: UInt64 = 0
    private var receivedDownloadBytes: UInt64 = 0

    override init() {
        super.init()

        guard Self.isPackagedApplication else {
            phase = .unavailable
            statusMessage = "In-app updates are available in packaged builds."
            return
        }

        userDriver.owner = self
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self
        )
        self.updater = updater

        canCheckObservation = updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            Task { @MainActor in
                self?.canCheckForUpdates = change.newValue ?? false
            }
        }

        do {
            try updater.start()
        } catch {
            phase = .failed
            statusMessage = "Unable to start updates: \(error.localizedDescription)"
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var actionTitle: String {
        switch phase {
        case .unavailable:
            return "Unavailable"
        case .idle:
            return "Check"
        case .checking:
            return "Checking…"
        case .available:
            return "Download"
        case let .downloading(percent):
            return "\(percent)%"
        case .preparing:
            return "99%"
        case .ready:
            return "Update"
        case .installing:
            return "Updating…"
        case .failed:
            return "Retry"
        }
    }

    var actionSystemImage: String {
        switch phase {
        case .downloading, .preparing:
            return "arrow.down.circle.fill"
        case .ready:
            return "sparkles"
        case .installing:
            return "arrow.triangle.2.circlepath"
        default:
            return "arrow.down.circle"
        }
    }

    var isAttentionAction: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isActionEnabled: Bool {
        switch phase {
        case .idle, .failed:
            return canCheckForUpdates
        case .available:
            return updateFoundReply != nil
        case .ready:
            return readyToInstallReply != nil || updateFoundReply != nil
        case .unavailable, .checking, .downloading, .preparing, .installing:
            return false
        }
    }

    var alertBinding: Binding<Bool> {
        Binding(
            get: { self.presentedAlert != nil },
            set: { isPresented in
                if !isPresented {
                    self.dismissPresentedAlert()
                }
            }
        )
    }

    func performPrimaryAction() {
        switch phase {
        case .available:
            presentAvailableUpdateAlert()
        case .ready:
            presentInstallationChoiceAlert()
        case .idle, .failed:
            checkForUpdates()
        case .unavailable, .checking, .downloading, .preparing, .installing:
            break
        }
    }

    func checkForUpdates() {
        guard let updater else {
            statusMessage = "Build Glimpse.app to test in-app updates."
            return
        }

        phase = .checking
        statusMessage = "Checking for updates…"
        updater.checkForUpdates()
    }

    func downloadPresentedUpdate() {
        presentedAlert = nil
        guard let reply = takeUpdateFoundReply() else { return }
        phase = .downloading(percent: 0)
        statusMessage = "Downloading update… 0%"
        reply(.install)
    }

    func deferPresentedUpdate() {
        presentedAlert = nil
        guard let reply = takeUpdateFoundReply() else { return }
        phase = .idle
        statusMessage = "Update postponed."
        reply(.dismiss)
    }

    func installUpdateNow() {
        presentedAlert = nil
        guard prepareConfigurationBackup() else { return }
        phase = .installing
        statusMessage = "Installing update and relaunching…"

        if let reply = takeReadyToInstallReply() {
            reply(.install)
        } else if let reply = takeUpdateFoundReply() {
            reply(.install)
        }
    }

    func installUpdateOnNextLaunch() {
        presentedAlert = nil
        guard prepareConfigurationBackup() else { return }
        statusMessage = "Update will be installed after Glimpse quits, ready for the next launch."

        if let reply = takeReadyToInstallReply() {
            reply(.dismiss)
        } else if let reply = takeUpdateFoundReply() {
            reply(.dismiss)
        }
    }

    func cancelInstallationChoice() {
        presentedAlert = nil
    }

    func acknowledgeInformation() {
        presentedAlert = nil
        takeInformationDismissHandler()?()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        statusMessage = "Glimpse \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        phase = .idle
        statusMessage = "Glimpse is up to date."
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        let expectedSparkleResults = [1001, 4007, 4008]
        guard nsError.domain != SUSparkleErrorDomain || !expectedSparkleResults.contains(nsError.code) else {
            return
        }
        phase = .failed
        statusMessage = "Unable to check for updates: \(error.localizedDescription)"
    }

    fileprivate func showUserInitiatedCheck() {
        phase = .checking
        statusMessage = "Checking for updates…"
    }

    fileprivate func showFoundUpdate(
        _ item: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        availableVersion = item.displayVersionString

        guard !item.isInformationOnlyUpdate else {
            phase = .idle
            statusMessage = "Glimpse \(item.displayVersionString) requires a manual download."
            presentedAlert = AppUpdateAlert(
                kind: .information,
                title: "Update information",
                message: "This release cannot be installed automatically. Please use the release link in the update feed."
            )
            informationDismissHandler = {
                reply(.dismiss)
            }
            return
        }

        switch state.stage {
        case .notDownloaded:
            updateFoundReply = reply
            phase = .available(version: item.displayVersionString)
            statusMessage = "Glimpse \(item.displayVersionString) is ready to download."
            presentAvailableUpdateAlert()
        case .downloaded:
            phase = .preparing
            statusMessage = "Preparing downloaded update… 99%"
            reply(.install)
        case .installing:
            updateFoundReply = reply
            phase = .ready(version: item.displayVersionString)
            statusMessage = "Glimpse \(item.displayVersionString) is ready to update."
        @unknown default:
            updateFoundReply = reply
            phase = .available(version: item.displayVersionString)
            presentAvailableUpdateAlert()
        }
    }

    fileprivate func showNoUpdate(error: Error, acknowledgement: @escaping () -> Void) {
        phase = .idle
        statusMessage = "Glimpse is up to date."
        acknowledgement()
    }

    fileprivate func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .failed
        statusMessage = "Update failed: \(error.localizedDescription)"
        presentedAlert = AppUpdateAlert(
            kind: .information,
            title: "Update failed",
            message: error.localizedDescription
        )
        informationDismissHandler = acknowledgement
    }

    fileprivate func downloadStarted() {
        expectedDownloadBytes = 0
        receivedDownloadBytes = 0
        phase = .downloading(percent: 0)
        statusMessage = "Downloading update… 0%"
    }

    fileprivate func receivedExpectedDownloadLength(_ length: UInt64) {
        expectedDownloadBytes = length
        receivedDownloadBytes = 0
        updateDownloadProgress()
    }

    fileprivate func receivedDownloadData(length: UInt64) {
        receivedDownloadBytes += length
        if receivedDownloadBytes > expectedDownloadBytes {
            expectedDownloadBytes = receivedDownloadBytes
        }
        updateDownloadProgress()
    }

    fileprivate func extractionStarted() {
        phase = .preparing
        statusMessage = "Verifying and preparing update… 99%"
    }

    fileprivate func extractionProgressChanged(_ progress: Double) {
        phase = .preparing
        statusMessage = "Verifying and preparing update… 99%"
    }

    fileprivate func readyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyToInstallReply = reply
        let version = availableVersion ?? "New version"
        phase = .ready(version: version)
        statusMessage = "Glimpse \(version) is ready to update."
    }

    fileprivate func installing() {
        phase = .installing
        statusMessage = "Installing update…"
    }

    fileprivate func installed(relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .idle
        statusMessage = relaunched ? "Update installed." : "Update installed and ready for next launch."
        acknowledgement()
    }

    fileprivate func dismissUpdateUI() {
        presentedAlert = nil
        updateFoundReply = nil
        readyToInstallReply = nil
        informationDismissHandler = nil
        if phase != .failed && phase != .installing {
            phase = .idle
        }
    }

    fileprivate func focusUpdateUI() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        if case .available = phase {
            presentAvailableUpdateAlert()
        } else if case .ready = phase {
            presentInstallationChoiceAlert()
        }
    }

    private func updateDownloadProgress() {
        let percent: Int
        if expectedDownloadBytes == 0 {
            percent = 0
        } else {
            let fraction = Double(receivedDownloadBytes) / Double(expectedDownloadBytes)
            percent = min(99, max(0, Int((fraction * 100).rounded(.down))))
        }
        phase = .downloading(percent: percent)
        statusMessage = "Downloading update… \(percent)%"
    }

    private func prepareConfigurationBackup() -> Bool {
        do {
            try configurationBackupHandler?()
            return true
        } catch {
            statusMessage = "Update paused because settings could not be backed up: \(error.localizedDescription)"
            presentedAlert = AppUpdateAlert(
                kind: .information,
                title: "Settings backup failed",
                message: "Glimpse did not start the update. Free some disk space or check your Application Support folder, then try again.\n\n\(error.localizedDescription)"
            )
            return false
        }
    }

    private func presentAvailableUpdateAlert() {
        guard case let .available(version) = phase else { return }
        presentedAlert = AppUpdateAlert(
            kind: .updateAvailable,
            title: "Glimpse \(version) is available",
            message: "Download the update now. You can keep using Glimpse while it downloads."
        )
    }

    private func presentInstallationChoiceAlert() {
        guard case let .ready(version) = phase else { return }
        presentedAlert = AppUpdateAlert(
            kind: .installationChoice,
            title: "Update Glimpse to \(version)?",
            message: "Update now to install and relaunch, or install after Glimpse quits so the new version is ready on your next launch."
        )
    }

    private func dismissPresentedAlert() {
        guard let alert = presentedAlert else { return }
        presentedAlert = nil
        if alert.kind == .updateAvailable {
            deferPresentedUpdate()
        } else if alert.kind == .information {
            takeInformationDismissHandler()?()
        }
    }

    private func takeUpdateFoundReply() -> ((SPUUserUpdateChoice) -> Void)? {
        defer { updateFoundReply = nil }
        return updateFoundReply
    }

    private func takeReadyToInstallReply() -> ((SPUUserUpdateChoice) -> Void)? {
        defer { readyToInstallReply = nil }
        return readyToInstallReply
    }

    private func takeInformationDismissHandler() -> (() -> Void)? {
        defer { informationDismissHandler = nil }
        return informationDismissHandler
    }

    private static var isPackagedApplication: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !publicKey.isEmpty && !publicKey.hasPrefix("$")
    }
}

@MainActor
private final class GlimpseUpdateUserDriver: NSObject, SPUUserDriver {
    weak var owner: AppUpdateController?

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.showUserInitiatedCheck()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        owner?.showFoundUpdate(appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.showNoUpdate(error: error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.downloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.receivedExpectedDownloadLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.receivedDownloadData(length: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.extractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        owner?.extractionProgressChanged(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.readyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        owner?.installing()
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        owner?.installed(relaunched: relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        owner?.dismissUpdateUI()
    }

    func showUpdateInFocus() {
        owner?.focusUpdateUI()
    }
}
#endif
