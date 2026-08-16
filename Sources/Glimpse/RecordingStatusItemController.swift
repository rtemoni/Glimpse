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

        coordinator.$state
            .combineLatest(coordinator.$elapsedSeconds)
            .sink { [weak self] state, elapsedSeconds in
                self?.refresh(state: state, elapsedSeconds: elapsedSeconds)
            }
            .store(in: &cancellables)

        ensureStatusItem().isVisible = false
        refresh(state: coordinator.state, elapsedSeconds: coordinator.elapsedSeconds)
    }

    deinit {
        pulseTimer?.invalidate()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func refresh(state: RecordingState, elapsedSeconds: Int) {
        guard shouldShowStatusItem(for: state) else {
            hideStatusItem()
            return
        }

        let statusItem = ensureStatusItem()
        statusItem.isVisible = true
        updatePulse(for: state)
        if let button = statusItem.button {
            button.image = statusImage(for: state, elapsedSeconds: elapsedSeconds)
            button.imagePosition = .imageLeading
            button.contentTintColor = statusTintColor(for: state)
            button.alphaValue = state == .recording && !isPulseBright ? 0.45 : 1
            button.attributedTitle = NSAttributedString(
                string: elapsedTimeLabel(elapsedSeconds),
                attributes: [
                    .foregroundColor: statusTintColor(for: state),
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                ]
            )
            button.target = self
            button.action = #selector(stopRecording)
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = "\(statusTitle(for: state, elapsedSeconds: elapsedSeconds)) — click to stop"
            button.setAccessibilityLabel(statusTitle(for: state, elapsedSeconds: elapsedSeconds))
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

    private func hideStatusItem() {
        stopPulse()
        statusItem?.isVisible = false
    }

    private func shouldShowStatusItem(for state: RecordingState) -> Bool {
        state == .recording || state == .paused || state == .stopping
    }

    private func statusTitle(for state: RecordingState, elapsedSeconds: Int) -> String {
        switch state {
        case .paused:
            return "Paused \(detailedElapsedTimeLabel(elapsedSeconds))"
        case .stopping:
            return "Stopping"
        default:
            return "Recording \(detailedElapsedTimeLabel(elapsedSeconds))"
        }
    }

    private func statusImage(for state: RecordingState, elapsedSeconds: Int) -> NSImage? {
        let image = NSImage(
            systemSymbolName: statusSystemImage(for: state),
            accessibilityDescription: statusTitle(for: state, elapsedSeconds: elapsedSeconds)
        )?
        .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = true
        return image
    }

    private func statusSystemImage(for state: RecordingState) -> String {
        switch state {
        case .paused:
            return "pause.circle.fill"
        case .stopping:
            return "stop.circle.fill"
        default:
            return "record.circle.fill"
        }
    }

    private func statusTintColor(for state: RecordingState) -> NSColor {
        switch state {
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
                if let coordinator = self.coordinator {
                    self.refresh(state: coordinator.state, elapsedSeconds: coordinator.elapsedSeconds)
                }
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

    private func elapsedTimeLabel(_ elapsedSeconds: Int) -> String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func detailedElapsedTimeLabel(_ elapsedSeconds: Int) -> String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
#endif
