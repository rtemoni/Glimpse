#if os(macOS)
import AppKit
import Combine
import Foundation
import GlimpseCore

@MainActor
final class RecordingStatusItemController: NSObject, ObservableObject {
    private weak var coordinator: RecordingCoordinator?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func attach(to coordinator: RecordingCoordinator) {
        guard self.coordinator !== coordinator else {
            return
        }

        self.coordinator = coordinator
        cancellables.removeAll()

        coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            }
            .store(in: &cancellables)

        refresh()
    }

    deinit {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func refresh() {
        guard let coordinator, coordinator.shouldShowRecordingStatusItem else {
            removeStatusItem()
            return
        }

        let statusItem = ensureStatusItem()
        if let button = statusItem.button {
            button.image = statusImage(for: coordinator)
            button.imagePosition = .imageLeading
            button.contentTintColor = .systemRed
            button.attributedTitle = NSAttributedString(
                string: coordinator.menuBarElapsedTimeLabel,
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                ]
            )
            button.toolTip = statusTitle(for: coordinator)
            button.setAccessibilityLabel(statusTitle(for: coordinator))
        }
        statusItem.menu = makeMenu(for: coordinator)
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        return item
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }

        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func makeMenu(for coordinator: RecordingCoordinator) -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusTitle(for: coordinator), action: nil, keyEquivalent: "")
        status.image = statusImage(for: coordinator)
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Glimpse", action: #selector(showGlimpse), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let pauseTitle = coordinator.state == .paused ? "Resume" : "Pause"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.isEnabled = coordinator.canPauseOrResume
        menu.addItem(pause)

        let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = coordinator.canStop
        menu.addItem(stop)

        return menu
    }

    private func statusTitle(for coordinator: RecordingCoordinator) -> String {
        switch coordinator.state {
        case .paused:
            return "Paused \(coordinator.elapsedTimeLabel)"
        case .stopping:
            return "Stopping"
        default:
            return "Recording \(coordinator.elapsedTimeLabel)"
        }
    }

    private func statusImage(for coordinator: RecordingCoordinator) -> NSImage? {
        let image = NSImage(
            systemSymbolName: coordinator.recordingStatusSystemImage,
            accessibilityDescription: statusTitle(for: coordinator)
        )?
        .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = true
        return image
    }

    @objc private func showGlimpse() {
        GlimpseWindowPresenter.showMainWindow()
    }

    @objc private func togglePause() {
        coordinator?.togglePause()
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            await coordinator?.stopRecording()
            GlimpseWindowPresenter.showMainWindow()
        }
    }
}

private extension RecordingCoordinator {
    var shouldShowRecordingStatusItem: Bool {
        state == .recording || state == .paused || state == .stopping
    }

    var recordingStatusSystemImage: String {
        switch state {
        case .paused:
            return "pause.circle.fill"
        case .stopping:
            return "stop.circle.fill"
        default:
            return "record.circle.fill"
        }
    }

    var menuBarElapsedTimeLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
#endif
