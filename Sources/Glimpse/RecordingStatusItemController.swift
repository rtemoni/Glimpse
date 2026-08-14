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
    private var pulseTimer: Timer?
    private var isPulseBright = true

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
        pulseTimer?.invalidate()
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
        updatePulse(for: coordinator.state)
        if let button = statusItem.button {
            button.image = statusImage(for: coordinator)
            button.imagePosition = .imageLeading
            button.contentTintColor = statusTintColor(for: coordinator)
            button.alphaValue = coordinator.state == .recording && !isPulseBright ? 0.45 : 1
            button.attributedTitle = NSAttributedString(
                string: coordinator.menuBarElapsedTimeLabel,
                attributes: [
                    .foregroundColor: statusTintColor(for: coordinator),
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                ]
            )
            button.target = self
            button.action = #selector(stopRecording)
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = "\(statusTitle(for: coordinator)) — click to stop"
            button.setAccessibilityLabel(statusTitle(for: coordinator))
            button.setAccessibilityHelp("Stops the recording and returns to the Glimpse editor")
        }
        statusItem.menu = nil
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
        stopPulse()
        guard let statusItem else {
            return
        }

        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
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

    private func statusTintColor(for coordinator: RecordingCoordinator) -> NSColor {
        switch coordinator.state {
        case .paused:
            return .systemOrange
        case .stopping:
            return .secondaryLabelColor
        default:
            return .systemRed
        }
    }

    private func updatePulse(for state: RecordingState) {
        guard state == .recording else {
            stopPulse()
            return
        }
        guard pulseTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.coordinator?.state == .recording else {
                    self?.stopPulse()
                    return
                }
                self.isPulseBright.toggle()
                self.refresh()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        isPulseBright = true
        statusItem?.button?.alphaValue = 1
    }

    @objc private func stopRecording() {
        guard coordinator?.canStop == true else {
            return
        }
        Task { @MainActor in
            await coordinator?.stopRecording()
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
