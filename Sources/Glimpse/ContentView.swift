#if os(macOS)
import AppKit
import AVKit
import CoreImage
import GlimpseCore
import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @State private var hasStartedPermissionOnboarding = false

    var body: some View {
        Group {
            if let summary = coordinator.recordingSummary, coordinator.editingSession != nil {
                EditorWorkspace(summary: summary)
                    .environmentObject(coordinator)
            } else if coordinator.shouldShowOnboarding && !hasStartedPermissionOnboarding {
                GetStartedView {
                    hasStartedPermissionOnboarding = true
                    coordinator.startPermissionMonitoring()
                }
            } else if coordinator.shouldShowOnboarding {
                PermissionOnboardingView()
                    .environmentObject(coordinator)
            } else if coordinator.state == .idle {
                CompactIdleView()
                    .environmentObject(coordinator)
            } else {
                RecorderWorkspace()
                    .environmentObject(coordinator)
            }
        }
        .background(WindowSizingController(mode: windowPresentationMode))
        .background(
            RecordingWindowLifecycleController(
                recordingPresentationToken: coordinator.recordingPresentationToken,
                shouldRestoreAfterRecording: coordinator.recordingSummary != nil
            )
        )
        .onAppear {
            coordinator.refreshDevices()
            coordinator.startPermissionMonitoring()
            coordinator.checkForUpdatesIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermissionStatuses()
            coordinator.refreshDevices()
            coordinator.startPermissionMonitoring()
            coordinator.checkForUpdatesIfNeeded()
        }
        .alert("Recording Error", isPresented: coordinator.hasErrorBinding) {
            Button("OK", role: .cancel) {
                coordinator.clearError()
            }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .alert(item: $coordinator.updateAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: updatePrimaryButton(for: alert),
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $coordinator.isCaptureTargetPickerPresented) {
            CaptureTargetPickerSheet()
                .environmentObject(coordinator)
        }
    }

    private func updatePrimaryButton(for alert: UpdateAlert) -> Alert.Button {
        if let downloadURL = alert.downloadURL {
            return .default(Text("Download")) {
                coordinator.openUpdateDownload(downloadURL)
            }
        }

        if let releaseNotesURL = alert.releaseNotesURL {
            return .default(Text("View Release")) {
                coordinator.openUpdateDownload(releaseNotesURL)
            }
        }

        return .default(Text("OK"))
    }

    private var windowPresentationMode: WindowPresentationMode {
        if coordinator.recordingSummary != nil {
            return .editor
        }
        if coordinator.shouldShowOnboarding && !hasStartedPermissionOnboarding {
            return .getStarted
        }
        if coordinator.shouldShowOnboarding {
            return .onboarding
        }
        if coordinator.state == .idle {
            return .splash
        }
        return .workspace
    }
}

private struct RecorderWorkspace: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            HSplitView {
                VStack(spacing: 12) {
                    RecordingStatusPane()
                        .environmentObject(coordinator)
                        .padding(10)
                        .liquidGlassSurface(cornerRadius: 24)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    ControlBar()
                        .environmentObject(coordinator)
                }
                .padding(12)
                .frame(minWidth: 320)

                SettingsPane()
                    .environmentObject(coordinator)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct EditorWorkspace: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let summary: RecordingSummary
    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    @State private var keyEventMonitor: Any?
    @State private var currentTime: Double = 0
    @State private var selectedVideoClips: [TimelineRange] = []
    @State private var selectedAudioClips: [TimelineRange] = []
    @State private var selectedTrack: TimelineTrack = .video
    @State private var clipMode: TimelineClipMode = .video
    @State private var undoSnapshot: EditingSession?
    @State private var undoSnapshotTime: Double = 0
    @State private var undoPlayheadTime: Double?
    @State private var isSkippingPlaybackGap = false
    @State private var thumbnails: [TimelineThumbnail] = []
    @State private var waveformSamples: [TimelineWaveformSample] = []
    @State private var sidebarPreviewImage: NSImage?
    @State private var sidebarPreviewRequest = 0
    @State private var lastSidebarPreviewTime: Double = -1

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            if let session = coordinator.editingSession {
                HSplitView {
                    VStack(spacing: 8) {
                        FramedVideoPreview(
                            player: player,
                            sourceAspectRatio: videoAspectRatio,
                            settings: coordinator.exportSettings.framedCapture,
                            roundsForeground: summary.captureTargetKind == .window
                        )
                            .previewSurface(cornerRadius: 24)
                            .frame(minWidth: 420, maxWidth: .infinity, alignment: .top)
                            .layoutPriority(1)

                        TimelineEditorView(
                            session: session,
                            duration: summary.duration,
                            thumbnails: thumbnails,
                            waveformSamples: waveformSamples,
                            currentTime: $currentTime,
                            selectedVideoClips: $selectedVideoClips,
                            selectedAudioClips: $selectedAudioClips,
                            selectedTrack: $selectedTrack,
                            clipMode: $clipMode,
                            scrub: scrub,
                            resetPlayhead: resetPlayhead,
                            moveToNextClip: moveToNextClip,
                            moveToLastClip: moveToLastClip,
                            undoLastAction: undoLastAction,
                            toggleClipMode: toggleClipMode,
                            selectClip: selectClip,
                            selectAudioClip: selectAudioClip,
                            splitAtPlayhead: splitAtPlayhead,
                            canUndo: canUndo
                        )
                        .liquidGlassSurface(cornerRadius: 24)
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 12)

                    ExportPanel(summary: summary, session: session, previewImage: sidebarPreviewImage)
                        .environmentObject(coordinator)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                        .padding(.trailing, 12)
                        .padding(.vertical, 12)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: summary.sourceURL))
            installTimeObserver()
            installKeyEventMonitor()
            if let session = coordinator.editingSession {
                reconcileSelectedClip(with: session)
                applyPreviewAudioMute(at: currentTime)
            }
            loadThumbnails()
            loadWaveform()
            loadSidebarPreview(force: true)
        }
        .onDisappear {
            player.pause()
            player.isMuted = false
            removeTimeObserver()
            removeKeyEventMonitor()
        }
        .onChange(of: coordinator.editingSession) { session in
            if let session {
                reconcileSelectedClip(with: session)
                applyPreviewAudioMute(at: currentTime)
            } else {
                selectedVideoClips = []
                selectedAudioClips = []
                selectedTrack = .video
                clipMode = .video
                undoSnapshot = nil
                undoPlayheadTime = nil
                player.isMuted = false
            }
        }
    }

    private var videoAspectRatio: CGFloat {
        let width = max(summary.videoSize.width, 1)
        let height = max(summary.videoSize.height, 1)
        return CGFloat(width / height)
    }

    private func splitAtPlayhead() {
        switch clipMode {
        case .video:
            splitVideoAtPlayhead(syncAudio: false)
        case .audio:
            guard var session = coordinator.editingSession else {
                return
            }
            splitAudioAtPlayhead(in: &session)
        case .both:
            splitBothAtPlayhead()
        }
    }

    private func splitVideoAtPlayhead(syncAudio: Bool) {
        guard var session = coordinator.editingSession else {
            return
        }

        let previousSession = session
        let splitTime = splitCandidate(in: session.clipRanges, selected: primaryVideoClip, near: currentTime)
        var appliedSplitTime = splitTime
        var didSplit = session.split(at: splitTime, syncAudio: syncAudio)
        if !didSplit,
           let fallbackClip = primaryVideoClip ?? session.clipRanges.first(where: { $0.contains(currentTime) }) {
            let fallbackSplitTime = fallbackClip.start + (fallbackClip.duration / 2)
            if session.split(at: fallbackSplitTime, syncAudio: syncAudio) {
                appliedSplitTime = fallbackSplitTime
                didSplit = true
            }
        }

        guard didSplit else {
            return
        }

        storeSessionUndo(previousSession)
        coordinator.editingSession = session
        selectedVideoClips = preferredClip(afterSplitAt: appliedSplitTime, in: session).map { [$0] } ?? []
        if syncAudio {
            selectedAudioClips = preferredClip(afterSplitAt: appliedSplitTime, in: session.audioClipRanges).map { [$0] } ?? []
        }
        selectedTrack = .video
        scrub(to: appliedSplitTime)
    }

    private func splitAudioAtPlayhead(in session: inout EditingSession) {
        let previousSession = session
        let splitTime = splitCandidate(in: session.audioClipRanges, selected: primaryAudioClip, near: currentTime)
        var appliedSplitTime = splitTime
        var didSplit = session.splitAudio(at: splitTime)
        if !didSplit,
           let fallbackClip = primaryAudioClip ?? session.audioClipRanges.first(where: { $0.contains(currentTime) }) {
            let fallbackSplitTime = fallbackClip.start + (fallbackClip.duration / 2)
            if session.splitAudio(at: fallbackSplitTime) {
                appliedSplitTime = fallbackSplitTime
                didSplit = true
            }
        }

        guard didSplit else {
            return
        }

        storeSessionUndo(previousSession)
        coordinator.editingSession = session
        selectedAudioClips = preferredClip(afterSplitAt: appliedSplitTime, in: session.audioClipRanges).map { [$0] } ?? []
        selectedTrack = .audio
        scrub(to: appliedSplitTime)
    }

    private func splitBothAtPlayhead() {
        guard var session = coordinator.editingSession else {
            return
        }

        let previousSession = session
        let splitTime = splitCandidateForBoth(in: session, near: currentTime)
        var didSplit = false

        if session.split(at: splitTime, syncAudio: false) {
            didSplit = true
        }
        if session.splitAudio(at: splitTime) {
            didSplit = true
        }

        guard didSplit else {
            return
        }

        storeSessionUndo(previousSession)
        coordinator.editingSession = session
        selectedVideoClips = preferredClip(afterSplitAt: splitTime, in: session).map { [$0] } ?? []
        selectedAudioClips = preferredClip(afterSplitAt: splitTime, in: session.audioClipRanges).map { [$0] } ?? []
        selectedTrack = .video
        scrub(to: splitTime)
    }

    private func deleteSelectedClip() {
        guard var session = coordinator.editingSession else {
            return
        }

        let previousSession = session
        let videoClips = selectedVideoClips.filter { session.clipRanges.contains($0) }
        let audioClips = selectedAudioClips.filter { session.audioClipRanges.contains($0) }
        guard !videoClips.isEmpty || !audioClips.isEmpty else {
            return
        }

        player.pause()
        for clip in videoClips {
            session.deleteClip(clip)
        }
        for clip in audioClips {
            session.deleteAudioClip(clip)
        }

        storeSessionUndo(previousSession)
        coordinator.editingSession = session
        let nextTime = (videoClips + audioClips).map(\.end).min() ?? currentTime
        selectedVideoClips = session.clipRanges.first { $0.start >= nextTime }.map { [$0] } ?? session.clipRanges.last.map { [$0] } ?? []
        selectedAudioClips = session.audioClipRanges.first { $0.start >= nextTime }.map { [$0] } ?? session.audioClipRanges.last.map { [$0] } ?? []
        if let target = selectedTrack == .audio ? selectedAudioClips.first : selectedVideoClips.first {
            scrub(to: target.start)
        }
    }

    private func resetPlayhead() {
        guard currentTime > 0 else {
            return
        }
        storePlayheadUndo()
        scrub(to: 0)
    }

    private func moveToNextClip() {
        guard let session = coordinator.editingSession,
              let start = session.clipRanges.map(\.start).first(where: { $0 > currentTime + 0.001 }) else {
            return
        }
        storePlayheadUndo()
        scrub(to: start)
    }

    private func moveToLastClip() {
        guard let session = coordinator.editingSession,
              let start = session.clipRanges.map(\.start).last(where: { $0 < currentTime - 0.001 }) else {
            return
        }
        storePlayheadUndo()
        scrub(to: start)
    }

    private func undoLastAction() {
        if let undoSnapshot {
            let restoredSession = undoSnapshot
            let restoredTime = undoSnapshotTime
            self.undoSnapshot = nil
            undoPlayheadTime = nil
            coordinator.editingSession = restoredSession
            reconcileSelectedClip(with: restoredSession)
            scrub(to: restoredTime)
        } else if let undoPlayheadTime {
            self.undoPlayheadTime = nil
            scrub(to: undoPlayheadTime)
        }
    }

    private func toggleClipMode() {
        clipMode = clipMode.next
    }

    private var canUndo: Bool {
        undoSnapshot != nil || undoPlayheadTime != nil
    }

    private func storeSessionUndo(_ session: EditingSession) {
        undoSnapshot = session
        undoSnapshotTime = currentTime
        undoPlayheadTime = nil
    }

    private func storePlayheadUndo() {
        undoSnapshot = nil
        undoPlayheadTime = currentTime
    }

    private func selectClip(_ clip: TimelineRange, interaction: TimelineSelectionInteraction) {
        selectedTrack = .video
        switch interaction {
        case .single:
            selectedVideoClips = [clip]
            selectedAudioClips = []
        case .additive:
            selectedVideoClips.togglePresence(of: clip)
        case .pair:
            selectedVideoClips.addIfMissing(clip)
            selectedAudioClips.add(contentsOf: pairedAudioClips(for: clip))
        }
    }

    private func selectAudioClip(_ clip: TimelineRange, interaction: TimelineSelectionInteraction) {
        selectedTrack = .audio
        switch interaction {
        case .single:
            selectedAudioClips = [clip]
            selectedVideoClips = []
        case .additive:
            selectedAudioClips.togglePresence(of: clip)
        case .pair:
            selectedAudioClips.addIfMissing(clip)
            selectedVideoClips.add(contentsOf: pairedVideoClips(for: clip))
        }
    }

    private func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
            return
        }

        if currentTime >= summary.duration {
            scrub(to: coordinator.editingSession?.clipRanges.first?.start ?? 0)
        } else if let session = coordinator.editingSession,
                  !session.clipRanges.contains(where: { $0.contains(currentTime) }),
                  let nextClip = session.clipRanges.first(where: { currentTime < $0.start }) ?? session.clipRanges.first {
            scrub(to: nextClip.start)
        }
        player.play()
    }

    private func scrub(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(summary.duration, 0))
        currentTime = clamped
        player.pause()
        applyPreviewAudioMute(at: clamped)
        loadSidebarPreview(time: clamped, force: true)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func installTimeObserver() {
        removeTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = min(max(CMTimeGetSeconds(time), 0), max(summary.duration, 0))
            Task { @MainActor in
                handleObservedPlaybackTime(seconds)
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func installKeyEventMonitor() {
        removeKeyEventMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
    }

    private func removeKeyEventMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField {
            return event
        }

        let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if shortcutModifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k":
                splitAtPlayhead()
                return nil
            case "0":
                resetPlayhead()
                return nil
            case "]":
                moveToNextClip()
                return nil
            case "l":
                moveToLastClip()
                return nil
            case "t":
                toggleClipMode()
                return nil
            case "z":
                undoLastAction()
                return nil
            default:
                break
            }
        }

        let commandModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard commandModifiers.isEmpty else {
            return event
        }

        switch event.keyCode {
        case 49:
            togglePlayback()
            return nil
        case 51, 117:
            deleteSelectedClip()
            return nil
        default:
            return event
        }
    }

    private func handleObservedPlaybackTime(_ seconds: Double) {
        if isSkippingPlaybackGap {
            return
        }

        if player.timeControlStatus == .playing,
           let session = coordinator.editingSession,
           !session.clipRanges.contains(where: { $0.contains(seconds) }) {
            if let nextClip = session.clipRanges.first(where: { seconds < $0.start }) {
                skipPlaybackGap(to: nextClip.start)
            } else {
                player.pause()
                currentTime = max(summary.duration, 0)
            }
        } else {
            currentTime = seconds
            applyPreviewAudioMute(at: seconds)
            loadSidebarPreview(time: seconds)
        }
    }

    private func skipPlaybackGap(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(summary.duration, 0))
        currentTime = clamped
        applyPreviewAudioMute(at: clamped)
        loadSidebarPreview(time: clamped, force: true)
        isSkippingPlaybackGap = true
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { _ in
            Task { @MainActor in
                isSkippingPlaybackGap = false
                if player.timeControlStatus != .playing {
                    player.play()
                }
            }
        }
    }

    private func reconcileSelectedClip(with session: EditingSession) {
        selectedVideoClips = selectedVideoClips.filter { session.clipRanges.contains($0) }
        selectedAudioClips = selectedAudioClips.filter { session.audioClipRanges.contains($0) }

        if selectedVideoClips.isEmpty {
            selectedVideoClips = session.clipRanges.first { $0.contains(currentTime) }.map { [$0] }
                ?? session.clipRanges.first.map { [$0] }
                ?? []
        }

        if selectedAudioClips.isEmpty {
            selectedAudioClips = session.audioClipRanges.first { $0.contains(currentTime) }.map { [$0] }
                ?? session.audioClipRanges.first.map { [$0] }
                ?? []
        }

        if selectedTrack == .audio, selectedAudioClips.isEmpty {
            selectedTrack = .video
        }
    }

    private func preferredClip(afterSplitAt time: Double, in session: EditingSession) -> TimelineRange? {
        preferredClip(afterSplitAt: time, in: session.clipRanges)
    }

    private func preferredClip(afterSplitAt time: Double, in clips: [TimelineRange]) -> TimelineRange? {
        clips.first { abs($0.start - time) < 0.001 }
            ?? clips.first { $0.contains(time) }
            ?? clips.first
    }

    private func splitCandidate(in clips: [TimelineRange], selected: TimelineRange?, near time: Double) -> Double {
        let minimumClipDuration: Double = 0.05
        if let clip = clips.first(where: {
            time > $0.start + minimumClipDuration && time < $0.end - minimumClipDuration
        }) {
            return min(max(time, clip.start + minimumClipDuration), clip.end - minimumClipDuration)
        }

        let fallbackClip = selected
            ?? clips.first(where: { $0.contains(time) })
            ?? clips.first
        guard let fallbackClip else {
            return time
        }
        return fallbackClip.start + (fallbackClip.duration / 2)
    }

    private func splitCandidateForBoth(in session: EditingSession, near time: Double) -> Double {
        let minimumClipDuration: Double = 0.05
        if session.clipRanges.contains(where: {
            time > $0.start + minimumClipDuration && time < $0.end - minimumClipDuration
        }) || session.audioClipRanges.contains(where: {
            time > $0.start + minimumClipDuration && time < $0.end - minimumClipDuration
        }) {
            return time
        }

        let fallbackClip = primaryVideoClip
            ?? primaryAudioClip
            ?? session.clipRanges.first
            ?? session.audioClipRanges.first
        guard let fallbackClip else {
            return time
        }
        return fallbackClip.start + (fallbackClip.duration / 2)
    }

    private var primaryVideoClip: TimelineRange? {
        selectedVideoClips.first
    }

    private var primaryAudioClip: TimelineRange? {
        selectedAudioClips.first
    }

    private func pairedAudioClips(for clip: TimelineRange) -> [TimelineRange] {
        coordinator.editingSession?.audioClipRanges.filter { $0.intersection(with: clip) != nil } ?? []
    }

    private func pairedVideoClips(for clip: TimelineRange) -> [TimelineRange] {
        coordinator.editingSession?.clipRanges.filter { $0.intersection(with: clip) != nil } ?? []
    }

    private func applyPreviewAudioMute(at seconds: Double) {
        guard let session = coordinator.editingSession else {
            player.isMuted = false
            return
        }
        player.isMuted = !session.audioKeptRanges.contains { $0.contains(seconds) }
    }

    private func loadThumbnails() {
        thumbnails = []
        let url = summary.sourceURL
        let duration = max(summary.duration, 0)
        Task {
            let generated = await Task.detached {
                TimelineThumbnailGenerator.generate(url: url, duration: duration, count: 24)
            }.value
            thumbnails = generated
        }
    }

    private func loadWaveform() {
        waveformSamples = []
        let url = summary.sourceURL
        let duration = max(summary.duration, 0)
        Task {
            let generated = await Task.detached {
                TimelineWaveformGenerator.generate(url: url, duration: duration, count: 420)
            }.value
            waveformSamples = generated
        }
    }

    private func loadSidebarPreview(time: Double? = nil, force: Bool = false) {
        let targetTime = min(max(time ?? currentTime, 0), max(summary.duration, 0))
        guard force || abs(targetTime - lastSidebarPreviewTime) >= 0.12 else {
            return
        }
        lastSidebarPreviewTime = targetTime
        sidebarPreviewRequest += 1
        let request = sidebarPreviewRequest
        let url = summary.sourceURL
        Task {
            let frame = await Task.detached {
                TimelineGeneratedFrame(
                    image: TimelineFrameGenerator.image(
                        url: url,
                        time: targetTime,
                        maximumSize: CGSize(width: 1920, height: 1920)
                    )
                )
            }.value
            if request == sidebarPreviewRequest {
                sidebarPreviewImage = frame.image
            }
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = videoGravity
        view.wantsLayer = true
        view.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.videoGravity = videoGravity
        nsView.layer?.contentsScale = nsView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

private struct FramedVideoPreview: View {
    let player: AVPlayer
    let sourceAspectRatio: CGFloat
    let settings: FramedCaptureSettings
    let roundsForeground: Bool

    var body: some View {
        if settings.isEnabled {
            GeometryReader { proxy in
                let canvasSize = proxy.size
                let padding = scaledPadding(for: canvasSize)
                let shadow = scaledShadow(for: canvasSize)

                ZStack {
                    FramedCaptureBackgroundView(settings: settings)

                    PlayerSurface(player: player, videoGravity: .resizeAspect)
                        .aspectRatio(sourceAspectRatio, contentMode: .fit)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: roundsForeground ? scaledCornerRadius(for: canvasSize) : 0,
                                style: .continuous
                            )
                        )
                        .shadow(
                            color: settings.shadow.previewColor,
                            radius: shadow.radius,
                            x: 0,
                            y: shadow.yOffset
                        )
                        .padding(padding)
                        .frame(
                            width: canvasSize.width,
                            height: canvasSize.height,
                            alignment: settings.alignment.swiftUIAlignment
                        )
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .clipped()
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            PlayerSurface(player: player, videoGravity: .resizeAspect)
                .aspectRatio(sourceAspectRatio, contentMode: .fit)
        }
    }

    private func scaledPadding(for size: CGSize) -> CGFloat {
        let scale = min(size.width / 1920, size.height / 1080)
        let desiredPadding = max(0, CGFloat(settings.padding) * max(scale, 0.35))
        let maximumPadding = max(0, min(size.width, size.height) * 0.22)
        return min(desiredPadding, maximumPadding)
    }

    private func scaledCornerRadius(for size: CGSize) -> CGFloat {
        let scale = min(size.width / 1920, size.height / 1080)
        let desiredRadius = max(0, CGFloat(settings.cornerRadius) * max(scale, 0.35))
        let maximumRadius = max(0, min(size.width, size.height) * 0.12)
        return min(desiredRadius, maximumRadius)
    }

    private func scaledShadow(for size: CGSize) -> (radius: CGFloat, yOffset: CGFloat) {
        let scale = max(min(size.width / 1920, size.height / 1080), 0.35)
        let maximumRadius = max(0, min(size.width, size.height) * 0.08)
        let radius = min(settings.shadow.previewRadius * scale, maximumRadius)
        let yOffset = min(settings.shadow.previewYOffset * scale, maximumRadius)
        return (radius, yOffset)
    }
}

private struct FramedCaptureBackgroundView: View {
    let settings: FramedCaptureSettings

    var body: some View {
        switch settings.background {
        case .gradient:
            LinearGradient(
                colors: [
                    Color(hex: settings.gradientStartHex),
                    Color(hex: settings.gradientEndHex)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .solidColor:
            Color(hex: settings.solidColorHex)
        }
    }
}

private struct TimelineThumbnail: Identifiable, @unchecked Sendable {
    let index: Int
    let time: Double
    let image: NSImage?

    var id: Int { index }
}

private struct TimelineWaveformSample: Identifiable, @unchecked Sendable {
    let index: Int
    let time: Double
    let amplitude: Double

    var id: Int { index }
}

private struct TimelineGeneratedFrame: @unchecked Sendable {
    let image: NSImage?
}

private enum TimelineTrack: String, CaseIterable, Identifiable {
    case video
    case audio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .video:
            return "film"
        case .audio:
            return "waveform"
        }
    }
}

private enum TimelineClipMode: String, CaseIterable, Identifiable {
    case video
    case audio
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        case .both:
            return "Both"
        }
    }

    var systemImage: String {
        switch self {
        case .video:
            return "film"
        case .audio:
            return "waveform"
        case .both:
            return "rectangle.2.swap"
        }
    }

    var clipButtonTitle: String {
        switch self {
        case .video:
            return "Clip Video"
        case .audio:
            return "Clip Audio"
        case .both:
            return "Clip Both"
        }
    }

    var next: TimelineClipMode {
        switch self {
        case .video:
            return .audio
        case .audio:
            return .both
        case .both:
            return .video
        }
    }
}

private enum TimelineSelectionInteraction: Equatable {
    case single
    case additive
    case pair
}

private enum TimelineThumbnailGenerator {
    static func generate(url: URL, duration: Double, count: Int) -> [TimelineThumbnail] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        let thumbnailCount = max(1, count)
        let safeDuration = max(duration, 0)
        return (0..<thumbnailCount).map { index in
            let denominator = max(thumbnailCount - 1, 1)
            let time = safeDuration * Double(index) / Double(denominator)
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            let image: NSImage?
            if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            } else {
                image = nil
            }
            return TimelineThumbnail(index: index, time: time, image: image)
        }
    }
}

private enum TimelineFrameGenerator {
    static func image(url: URL, time: Double, maximumSize: CGSize) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        let cmTime = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private enum TimelineWaveformGenerator {
    static func generate(url: URL, duration: Double, count: Int) -> [TimelineWaveformSample] {
        let sampleCount = max(1, count)
        let safeDuration = max(duration, 0.001)
        var peaks = Array(repeating: 0.0, count: sampleCount)
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            return []
        }

        for track in tracks {
            accumulate(track: track, asset: asset, duration: safeDuration, peaks: &peaks)
        }

        let maximumPeak = max(peaks.max() ?? 0, 0.0001)
        return peaks.enumerated().map { index, peak in
            TimelineWaveformSample(
                index: index,
                time: safeDuration * Double(index) / Double(max(sampleCount - 1, 1)),
                amplitude: min(max(peak / maximumPeak, 0), 1)
            )
        }
    }

    private static func accumulate(
        track: AVAssetTrack,
        asset: AVAsset,
        duration: Double,
        peaks: inout [Double]
    ) {
        guard let reader = try? AVAssetReader(asset: asset) else {
            return
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 12_000
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            return
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            accumulate(sampleBuffer: sampleBuffer, duration: duration, peaks: &peaks)
        }
    }

    private static func accumulate(
        sampleBuffer: CMSampleBuffer,
        duration: Double,
        peaks: inout [Double]
    ) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else {
            return
        }

        let floatCount = totalLength / MemoryLayout<Float>.size
        guard floatCount > 0 else {
            return
        }

        let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        let audioDescription = description.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let channelCount = max(1, Int(audioDescription?.mChannelsPerFrame ?? 1))
        let sampleRate = max(1, Double(audioDescription?.mSampleRate ?? 12_000))
        let frameCount = floatCount / channelCount
        guard frameCount > 0 else {
            return
        }

        let startTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard startTime.isFinite else {
            return
        }

        dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { samples in
            for frameIndex in 0..<frameCount {
                let time = startTime + (Double(frameIndex) / sampleRate)
                guard time.isFinite, time >= 0 else {
                    continue
                }
                let bucket = min(max(Int((time / duration) * Double(peaks.count)), 0), peaks.count - 1)
                var peak: Float = 0
                for channelIndex in 0..<channelCount {
                    peak = max(peak, abs(samples[(frameIndex * channelCount) + channelIndex]))
                }
                peaks[bucket] = max(peaks[bucket], Double(peak))
            }
        }
    }
}

private struct TimelineEditorView: View {
    let session: EditingSession
    let duration: Double
    let thumbnails: [TimelineThumbnail]
    let waveformSamples: [TimelineWaveformSample]
    @Binding var currentTime: Double
    @Binding var selectedVideoClips: [TimelineRange]
    @Binding var selectedAudioClips: [TimelineRange]
    @Binding var selectedTrack: TimelineTrack
    @Binding var clipMode: TimelineClipMode
    let scrub: (Double) -> Void
    let resetPlayhead: () -> Void
    let moveToNextClip: () -> Void
    let moveToLastClip: () -> Void
    let undoLastAction: () -> Void
    let toggleClipMode: () -> Void
    let selectClip: (TimelineRange, TimelineSelectionInteraction) -> Void
    let selectAudioClip: (TimelineRange, TimelineSelectionInteraction) -> Void
    let splitAtPlayhead: () -> Void
    let canUndo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Label("Timeline", systemImage: "timeline.selection")
                        .font(.headline)
                    Text("\(session.clipRanges.count) \(session.clipRanges.count == 1 ? "clip" : "clips")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Divider()
                        .frame(height: 18)
                    Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(formatTime(totalKeptDuration)) export")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("Clip Mode", selection: $clipMode) {
                        ForEach(TimelineClipMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    Button(action: toggleClipMode) {
                        ShortcutPill("CMD+T")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("t", modifiers: [.command])
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ClipTimelineStrip(
                session: session,
                duration: max(duration, 0.1),
                thumbnails: thumbnails,
                waveformSamples: waveformSamples,
                currentTime: currentTime,
                selectedVideoClips: $selectedVideoClips,
                selectedAudioClips: $selectedAudioClips,
                selectedTrack: $selectedTrack,
                scrub: scrub,
                selectClip: selectClip,
                selectAudioClip: selectAudioClip
            )
            .frame(height: 60)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(action: undoLastAction) {
                        TimelineButtonLabel(title: "Undo", systemImage: "arrow.uturn.backward", shortcut: "CMD+Z")
                    }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!canUndo)

                    Button {
                        splitAtPlayhead()
                    } label: {
                        TimelineButtonLabel(title: clipMode.clipButtonTitle, systemImage: "scissors", shortcut: "CMD+K")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(!canSplitSelectedTrack)

                    Button(action: resetPlayhead) {
                        TimelineButtonLabel(title: "Reset", systemImage: "backward.end", shortcut: "CMD+0")
                    }
                    .keyboardShortcut("0", modifiers: [.command])
                    .disabled(currentTime <= 0)

                    Button(action: moveToLastClip) {
                        TimelineButtonLabel(title: "Last Clip", systemImage: "backward.end", shortcut: "CMD+L")
                    }
                    .keyboardShortcut("l", modifiers: [.command])
                    .disabled(previousClipStart == nil)

                    Button(action: moveToNextClip) {
                        TimelineButtonLabel(title: "Next Clip", systemImage: "forward.end", shortcut: "CMD+]")
                    }
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(nextClipStart == nil)
                }
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    private var totalKeptDuration: Double {
        session.keptRanges.reduce(0) { $0 + $1.duration }
    }

    private var canSplitSelectedTrack: Bool {
        switch clipMode {
        case .video:
            return session.clipRanges.contains { $0.duration > 0.1 }
        case .audio:
            return session.audioClipRanges.contains { $0.duration > 0.1 }
        case .both:
            return session.clipRanges.contains { $0.duration > 0.1 }
                || session.audioClipRanges.contains { $0.duration > 0.1 }
        }
    }

    private var nextClipStart: Double? {
        session.clipRanges.map(\.start).first { $0 > currentTime + 0.001 }
    }

    private var previousClipStart: Double? {
        session.clipRanges.map(\.start).last { $0 < currentTime - 0.001 }
    }
}

private struct TimelineButtonLabel: View {
    let title: String
    let systemImage: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            ShortcutPill(shortcut)
        }
        .lineLimit(1)
    }
}

private struct ShortcutPill: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 2) {
            if let commandKey {
                Image(systemName: "command")
                    .imageScale(.small)
                Text(commandKey)
                    .font(.caption2.monospaced().weight(.semibold))
            } else {
                Text(text)
                    .font(.caption2.monospaced().weight(.semibold))
            }
        }
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.18), in: Capsule())
    }

    private var commandKey: String? {
        guard text.hasPrefix("CMD+") else {
            return nil
        }
        return String(text.dropFirst(4))
    }
}

private struct ClipTimelineStrip: View {
    let session: EditingSession
    let duration: Double
    let thumbnails: [TimelineThumbnail]
    let waveformSamples: [TimelineWaveformSample]
    let currentTime: Double
    @Binding var selectedVideoClips: [TimelineRange]
    @Binding var selectedAudioClips: [TimelineRange]
    @Binding var selectedTrack: TimelineTrack
    let scrub: (Double) -> Void
    let selectClip: (TimelineRange, TimelineSelectionInteraction) -> Void
    let selectAudioClip: (TimelineRange, TimelineSelectionInteraction) -> Void

    private let idealGapWidth: Double = 40
    private let minimumGapWidth: Double = 20
    private let minimumClipWidth: Double = 140
    private let verticalInset: Double = 4
    private let trackGap: Double = 2
    @State private var lastModifiedSelectionID: String?

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = max(proxy.size.width, 1)
            let height = proxy.size.height
            let laneHeights = laneHeights(totalHeight: height)
            let trackHeight = laneHeights.video + laneHeights.audio + trackGap
            let layout = timelineLayout(viewportWidth: viewportWidth)

            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    if layout.frames.isEmpty {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.12))
                    }

                    HStack(spacing: 0) {
                        ForEach(layout.segments) { segment in
                            switch segment.kind {
                            case .clip(let frame):
                                TimelineClipSegmentBlock(
                                    frame: frame,
                                    thumbnails: thumbnails(for: frame.range),
                                    waveformSamples: waveformSamples,
                                    audioFrames: layout.audioFrames.filter { $0.parentClipID == frame.id },
                                    currentTime: currentTime,
                                    selectedVideoClips: selectedVideoClips,
                                    selectedAudioClips: selectedAudioClips,
                                    selectedTrack: selectedTrack,
                                    videoHeight: laneHeights.video,
                                    audioHeight: laneHeights.audio,
                                    trackGap: trackGap
                                )
                                .frame(width: CGFloat(frame.width), height: CGFloat(trackHeight))
                                .clipped()
                            case .gap(let gap):
                                TimelineAirGap()
                                    .frame(width: CGFloat(gap.width), height: CGFloat(trackHeight))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(width: CGFloat(layout.contentWidth), height: CGFloat(trackHeight), alignment: .leading)
                    .padding(.vertical, CGFloat(verticalInset))

                    playhead(frames: layout.frames, gapWidth: layout.gapWidth, height: trackHeight)
                        .offset(y: verticalInset)
                }
                .frame(width: layout.contentWidth, height: height)
                .id(layout.identity)
                .coordinateSpace(name: "clipTimeline")
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTimeline"))
                        .onChanged { value in
                            let interaction = selectionInteraction
                            let canModifySelection = interaction != .single
                            let isAudioLane = value.location.y >= verticalInset + laneHeights.video + trackGap
                            if isAudioLane,
                               let target = audioTarget(for: value.location.x, frames: layout.audioFrames) {
                                selectedTrack = .audio
                                if !canModifySelection || lastModifiedSelectionID != target.id {
                                    selectAudioClip(target.clip, interaction)
                                    lastModifiedSelectionID = canModifySelection ? target.id : nil
                                }
                                scrub(target.time)
                                return
                            }
                            if let target = videoTarget(for: value.location.x, frames: layout.frames) {
                                selectedTrack = .video
                                if !canModifySelection || lastModifiedSelectionID != target.id {
                                    selectClip(target.clip, interaction)
                                    lastModifiedSelectionID = canModifySelection ? target.id : nil
                                }
                                scrub(target.time)
                            }
                        }
                        .onEnded { _ in
                            lastModifiedSelectionID = nil
                        }
                )
            }
        }
    }

    private func laneHeights(totalHeight: Double) -> TimelineLaneHeights {
        let availableHeight = max(1, totalHeight - (verticalInset * 2) - trackGap)
        let videoHeight = min(38, max(28, availableHeight * 0.68))
        let audioHeight = max(12, availableHeight - videoHeight)
        return TimelineLaneHeights(video: videoHeight, audio: audioHeight)
    }

    private func timelineLayout(viewportWidth: Double) -> TimelineLayout {
        let clips = session.clipRanges
        guard !clips.isEmpty else {
            return TimelineLayout(contentWidth: viewportWidth, gapWidth: 0, frames: [], audioFrames: [], gaps: [], segments: [])
        }

        let clipCount = clips.count
        let totalClipDuration = clips.reduce(0) { $0 + $1.duration }
        let clipGapCount = Double(max(clipCount - 1, 0))
        let responsiveGapWidth = clipGapCount == 0
            ? 0
            : min(idealGapWidth, max(minimumGapWidth, viewportWidth * 0.18))
        let clipImageWidth = max(viewportWidth, Double(clipCount) * minimumClipWidth)
        let contentWidth = clipImageWidth + (clipGapCount * responsiveGapWidth)
        let flexibleClipWidth = max(0, clipImageWidth - (Double(clipCount) * minimumClipWidth))
        var cursor: Double = 0

        var gaps: [TimelineGapFrame] = []
        let frames = clips.enumerated().map { index, clip in
            let clipWidth = minimumClipWidth + flexibleClipWidth * (clip.duration / max(totalClipDuration, 0.1))
            let frame = TimelineClipFrame(id: "\(index)-\(clip.start)-\(clip.end)", range: clip, minX: cursor, width: clipWidth)
            defer {
                if index < clips.count - 1 {
                    gaps.append(
                        TimelineGapFrame(
                            id: index,
                            minX: cursor + clipWidth,
                            width: responsiveGapWidth
                        )
                    )
                }
                cursor += clipWidth + responsiveGapWidth
            }
            return frame
        }

        var segments: [TimelineSegment] = []
        for index in frames.indices {
            segments.append(TimelineSegment(id: "clip-\(frames[index].id)", kind: .clip(frames[index])))
            if gaps.indices.contains(index) {
                segments.append(TimelineSegment(id: "gap-\(gaps[index].id)", kind: .gap(gaps[index])))
            }
        }
        let audioFrames = audioFrames(for: frames)

        return TimelineLayout(
            contentWidth: contentWidth,
            gapWidth: responsiveGapWidth,
            frames: frames,
            audioFrames: audioFrames,
            gaps: gaps,
            segments: segments
        )
    }

    private func audioFrames(for frames: [TimelineClipFrame]) -> [TimelineAudioClipFrame] {
        var audioFrames: [TimelineAudioClipFrame] = []
        for frame in frames {
            for audioClip in session.audioClipRanges {
                guard let range = frame.range.intersection(with: audioClip) else {
                    continue
                }
                let startProgress = (range.start - frame.range.start) / max(frame.range.duration, 0.1)
                let widthProgress = range.duration / max(frame.range.duration, 0.1)
                audioFrames.append(
                    TimelineAudioClipFrame(
                        id: "\(frame.id)-audio-\(range.start)-\(range.end)",
                        parentClipID: frame.id,
                        range: range,
                        minX: frame.minX + (frame.width * startProgress),
                        width: max(1, frame.width * widthProgress)
                    )
                )
            }
        }
        return audioFrames
    }

    private func thumbnails(for clip: TimelineRange) -> [TimelineThumbnail] {
        let contained = thumbnails.filter { thumbnail in
            thumbnail.time >= clip.start && thumbnail.time <= clip.end
        }
        if !contained.isEmpty {
            return contained
        }

        let midpoint = clip.start + (clip.duration / 2)
        if let nearest = thumbnails.min(by: { abs($0.time - midpoint) < abs($1.time - midpoint) }) {
            return [nearest]
        }

        return [
            TimelineThumbnail(
                index: Int(clip.start * 1000),
                time: midpoint,
                image: nil
            )
        ]
    }

    private var selectionInteraction: TimelineSelectionInteraction {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            return .pair
        }
        if modifiers.contains(.command) {
            return .additive
        }
        return .single
    }

    private func videoTarget(for x: Double, frames: [TimelineClipFrame]) -> (id: String, clip: TimelineRange, time: Double)? {
        guard !frames.isEmpty else {
            return nil
        }

        for frame in frames {
            if x >= frame.minX && x <= frame.maxX {
                let progress = (x - frame.minX) / max(frame.width, 1)
                let time = frame.range.start + (frame.range.duration * progress)
                return (frame.id, frame.range, time)
            }
        }

        let nearest = frames.min { lhs, rhs in
            lhs.distance(to: x) < rhs.distance(to: x)
        }
        guard let nearest else {
            return nil
        }
        let time = x < nearest.minX ? nearest.range.start : nearest.range.end
        return (nearest.id, nearest.range, time)
    }

    private func audioTarget(for x: Double, frames: [TimelineAudioClipFrame]) -> (id: String, clip: TimelineRange, time: Double)? {
        guard !frames.isEmpty else {
            return nil
        }

        for frame in frames {
            if x >= frame.minX && x <= frame.maxX {
                let progress = (x - frame.minX) / max(frame.width, 1)
                let time = frame.range.start + (frame.range.duration * progress)
                return (frame.id, frame.range, time)
            }
        }

        let nearest = frames.min { lhs, rhs in
            lhs.distance(to: x) < rhs.distance(to: x)
        }
        guard let nearest else {
            return nil
        }
        let time = x < nearest.minX ? nearest.range.start : nearest.range.end
        return (nearest.id, nearest.range, time)
    }

    private func playhead(frames: [TimelineClipFrame], gapWidth: Double, height: Double) -> some View {
        let playheadX = x(for: currentTime, frames: frames, gapWidth: gapWidth)
        return ZStack {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: height)
                .shadow(radius: 2)
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .offset(y: -8)
        }
        .offset(x: playheadX - 1)
        .allowsHitTesting(false)
    }

    private func x(for time: Double, frames: [TimelineClipFrame], gapWidth: Double) -> Double {
        guard !frames.isEmpty else {
            return 0
        }

        for frame in frames {
            if frame.range.contains(time) {
                let progress = (time - frame.range.start) / max(frame.range.duration, 0.1)
                return frame.minX + (frame.width * progress)
            }
            if time < frame.range.start {
                return frame.minX
            }
        }

        return frames.last?.maxX ?? 0
    }
}

private struct TimelineLayout {
    let contentWidth: Double
    let gapWidth: Double
    let frames: [TimelineClipFrame]
    let audioFrames: [TimelineAudioClipFrame]
    let gaps: [TimelineGapFrame]
    let segments: [TimelineSegment]

    var identity: String {
        (frames.map { $0.id } + audioFrames.map { $0.id }).joined(separator: "|")
    }
}

private struct TimelineLaneHeights {
    let video: Double
    let audio: Double
}

private struct TimelineSegment: Identifiable {
    enum Kind {
        case clip(TimelineClipFrame)
        case gap(TimelineGapFrame)
    }

    let id: String
    let kind: Kind
}

private struct TimelineClipFrame: Identifiable {
    let id: String
    let range: TimelineRange
    let minX: Double
    let width: Double

    var maxX: Double {
        minX + width
    }

    func distance(to x: Double) -> Double {
        if x < minX {
            return minX - x
        }
        if x > maxX {
            return x - maxX
        }
        return 0
    }
}

private struct TimelineAudioClipFrame: Identifiable {
    let id: String
    let parentClipID: String
    let range: TimelineRange
    let minX: Double
    let width: Double

    var maxX: Double {
        minX + width
    }

    func distance(to x: Double) -> Double {
        if x < minX {
            return minX - x
        }
        if x > maxX {
            return x - maxX
        }
        return 0
    }
}

private struct TimelineGapFrame: Identifiable {
    let id: Int
    let minX: Double
    let width: Double
}

private extension TimelineRange {
    func intersection(with other: TimelineRange) -> TimelineRange? {
        let range = TimelineRange(start: max(start, other.start), end: min(end, other.end))
        return range.duration > 0 ? range : nil
    }
}

private extension Array where Element: Equatable {
    mutating func addIfMissing(_ element: Element) {
        guard !contains(element) else {
            return
        }
        append(element)
    }

    mutating func add(contentsOf elements: [Element]) {
        for element in elements {
            addIfMissing(element)
        }
    }

    mutating func togglePresence(of element: Element) {
        if let index = firstIndex(of: element) {
            remove(at: index)
        } else {
            append(element)
        }
    }
}

private struct TimelineAirGap: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.42))
            .overlay {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: 1)
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: 1)
                }
            }
    }
}

private struct TimelineClipSegmentBlock: View {
    let frame: TimelineClipFrame
    let thumbnails: [TimelineThumbnail]
    let waveformSamples: [TimelineWaveformSample]
    let audioFrames: [TimelineAudioClipFrame]
    let currentTime: Double
    let selectedVideoClips: [TimelineRange]
    let selectedAudioClips: [TimelineRange]
    let selectedTrack: TimelineTrack
    let videoHeight: Double
    let audioHeight: Double
    let trackGap: Double

    var body: some View {
        VStack(spacing: CGFloat(trackGap)) {
            TimelineClipBlock(
                thumbnails: thumbnails,
                isSelected: selectedVideoClips.contains(frame.range),
                isFocused: selectedTrack == .video && selectedVideoClips.contains(frame.range)
            )
            .frame(height: CGFloat(videoHeight))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.24))

                ForEach(audioFrames) { audioFrame in
                    TimelineWaveformBlock(
                        clip: audioFrame.range,
                        samples: waveformSamples,
                        currentTime: currentTime,
                        isSelected: selectedAudioClips.contains(audioFrame.range),
                        isFocused: selectedTrack == .audio && selectedAudioClips.contains(audioFrame.range)
                    )
                    .frame(width: CGFloat(audioFrame.width), height: CGFloat(audioHeight))
                    .offset(x: CGFloat(audioFrame.minX - frame.minX))
                }
            }
            .frame(height: CGFloat(audioHeight))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

private struct TimelineClipBlock: View {
    let thumbnails: [TimelineThumbnail]
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 1) {
                ForEach(thumbnails) { thumbnail in
                    TimelineThumbnailCard(thumbnail: thumbnail, showsTime: false)
                        .frame(maxWidth: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.22)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.20))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? (isFocused ? Color.accentColor : Color.white.opacity(0.74)) : Color.white.opacity(0.36),
                    lineWidth: isSelected ? 2 : 1
                )
        }
    }
}

private struct TimelineWaveformBlock: View {
    let clip: TimelineRange
    let samples: [TimelineWaveformSample]
    let currentTime: Double
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, canvasSize in
                let clipSamples = samples.filter { sample in
                    sample.time >= clip.start && sample.time <= clip.end
                }
                let barCount = max(1, Int(canvasSize.width / 3))
                let barWidth = max(1, canvasSize.width / CGFloat(barCount))

                if clipSamples.isEmpty {
                    let rect = CGRect(
                        x: 0,
                        y: (canvasSize.height / 2) - 0.5,
                        width: canvasSize.width,
                        height: 1
                    )
                    context.fill(Path(rect), with: .color(.white.opacity(0.38)))
                } else {
                    let peaks = peaksByBar(samples: clipSamples, barCount: barCount)
                    for index in peaks.indices {
                        let sampleTime = clip.start + (clip.duration * Double(index) / Double(max(barCount - 1, 1)))
                        let isPlayed = sampleTime <= currentTime
                        let amplitude = max(peaks[index], 0.06)
                        let barHeight = max(1, canvasSize.height * CGFloat(amplitude))
                        let rect = CGRect(
                            x: CGFloat(index) * barWidth,
                            y: (canvasSize.height - barHeight) / 2,
                            width: max(1, barWidth - 1),
                            height: barHeight
                        )
                        let path = Path(roundedRect: rect, cornerRadius: 1)
                        context.fill(
                            path,
                            with: .color(isPlayed ? Color.accentColor.opacity(0.86) : Color.white.opacity(0.58))
                        )
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isSelected ? (isFocused ? Color.accentColor : Color.white.opacity(0.70)) : Color.white.opacity(0.18),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private func peaksByBar(samples: [TimelineWaveformSample], barCount: Int) -> [Double] {
        var peaks = Array(repeating: 0.0, count: barCount)
        for sample in samples {
            let progress = (sample.time - clip.start) / max(clip.duration, 0.001)
            let index = min(max(Int(progress * Double(barCount)), 0), barCount - 1)
            peaks[index] = max(peaks[index], sample.amplitude)
        }
        return peaks
    }
}

private struct TimelineThumbnailCard: View {
    let thumbnail: TimelineThumbnail
    var showsTime = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = thumbnail.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.25), Color(nsColor: .controlBackgroundColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            if showsTime {
                Text(formatTime(thumbnail.time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.48), in: Capsule())
                    .padding(5)
            }
        }
        .clipped()
    }
}

private struct ExportPanel: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let summary: RecordingSummary
    let session: EditingSession
    let previewImage: NSImage?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SidebarAspectPreviewGrid(summary: summary, previewImage: previewImage)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit Recording")
                        .font(.title3.weight(.semibold))

                    Text(summary.sourceURL.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    if let status = coordinator.statusMessage {
                        StatusPill(
                            text: status,
                            systemImage: coordinator.isExporting ? "square.and.arrow.up" : "checkmark.circle"
                        )
                    }
                }

                VStack(spacing: 8) {
                    Button {
                        coordinator.revealInFinder(summary.sourceURL)
                    } label: {
                        Label("Reveal Master", systemImage: "folder")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        coordinator.recordAgain()
                    } label: {
                        Label("Record Again", systemImage: "record.circle")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Clips", "\(session.clipRanges.count)")
                    infoRow("Export", formatTime(exportDuration))
                    infoRow("Master", summary.sourceURL.lastPathComponent)
                    infoRow("Duration", formatTime(summary.duration))
                    infoRow("Size", formatFileSize(summary.fileSizeBytes))
                    infoRow("Frame", "\(Int(summary.videoSize.width)) x \(Int(summary.videoSize.height))")
                    infoRow("Sources", sourceSummary(summary.sources))
                }

                Divider()

                FramedCaptureControls(settings: $coordinator.exportSettings.framedCapture)

                Divider()

                Text("Export")
                    .font(.headline)

                ExportAspectPresetPicker(settings: $coordinator.exportSettings)

                Picker("Format", selection: $coordinator.exportSettings.format) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                Picker("Bitrate", selection: $coordinator.exportSettings.bitratePreset) {
                    ForEach(ExportBitratePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                if coordinator.exportSettings.bitratePreset == .custom {
                    HStack {
                        Text("Mbps")
                        TextField(
                            "Mbps",
                            value: $coordinator.exportSettings.customBitrateMegabits,
                            format: .number.precision(.fractionLength(1))
                        )
                        .frame(width: 74)
                    }
                }

                Button {
                    Task {
                        await coordinator.exportEditedRecording()
                    }
                } label: {
                    Label(coordinator.isExporting ? "Exporting" : "Export Edited Video", systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isExporting || coordinator.editingSession?.keptRanges.isEmpty == true)

                if coordinator.isExporting {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: coordinator.exportProgress)
                            .progressViewStyle(.linear)
                        Text("\(Int((coordinator.exportProgress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if !coordinator.exportedVideos.isEmpty {
                    Divider()
                    Text(coordinator.exportedVideos.count == 1 ? "Export complete" : "Exports complete")
                        .font(.headline)

                    ForEach(coordinator.exportedVideos) { exportedVideo in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(exportedVideo.preset.displayName) \(exportedVideo.preset.description)")
                                .font(.callout.weight(.semibold))

                            HStack(spacing: 8) {
                                Button {
                                    coordinator.openFile(exportedVideo.url)
                                } label: {
                                    Label("Open", systemImage: "play.rectangle")
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                }
                                Button {
                                    coordinator.revealInFinder(exportedVideo.url)
                                } label: {
                                    Label("Reveal", systemImage: "folder")
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .liquidGlassSurface(cornerRadius: 24)
    }

    private var exportDuration: Double {
        session.keptRanges.reduce(0) { $0 + $1.duration }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.callout)
    }

    private func sourceSummary(_ sources: RecordingSourceSet) -> String {
        var parts: [String] = []
        if sources.camera {
            parts.append("Camera")
        }
        if sources.microphone {
            parts.append("Mic")
        }
        if sources.systemAudio {
            parts.append("System")
        }
        return parts.isEmpty ? "Screen only" : parts.joined(separator: ", ")
    }
}

private struct ExportAspectPresetPicker: View {
    @Binding var settings: ExportSettings

    var body: some View {
        Menu {
            Button("All 3 Variations") {
                settings.aspectPresets = ExportAspectPreset.allCases
            }

            Divider()

            ForEach(ExportAspectPreset.allCases) { preset in
                Toggle(isOn: binding(for: preset)) {
                    Text("\(preset.displayName) \(preset.description)")
                }
            }
        } label: {
            HStack {
                Label("Exports", systemImage: "square.grid.2x2")
                Spacer()
                Text(selectionSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var selectionSummary: String {
        let presets = settings.normalizedAspectPresets
        if presets.count == ExportAspectPreset.allCases.count {
            return "All 3"
        }
        return presets.map(\.displayName).joined(separator: ", ")
    }

    private func binding(for preset: ExportAspectPreset) -> Binding<Bool> {
        Binding(
            get: {
                settings.normalizedAspectPresets.contains(preset)
            },
            set: { isSelected in
                var presets = settings.normalizedAspectPresets
                if isSelected {
                    if !presets.contains(preset) {
                        presets.append(preset)
                    }
                } else if presets.count > 1 {
                    presets.removeAll { $0 == preset }
                }
                settings.aspectPresets = presets
            }
        )
    }
}

private enum FramedGradientPreset: String, CaseIterable, Identifiable {
    case blueCoral
    case graphite
    case aurora
    case sunset

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blueCoral:
            return "Blue Coral"
        case .graphite:
            return "Graphite"
        case .aurora:
            return "Aurora"
        case .sunset:
            return "Sunset"
        }
    }

    var colors: (start: String, end: String) {
        switch self {
        case .blueCoral:
            return ("#246BFE", "#FB6F4D")
        case .graphite:
            return ("#111318", "#4B5563")
        case .aurora:
            return ("#00A676", "#4F46E5")
        case .sunset:
            return ("#F97316", "#DB2777")
        }
    }
}

private struct FramedCaptureControls: View {
    @Binding var settings: FramedCaptureSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Background & Frame", isOn: $settings.isEnabled)
                .font(.headline)

            if settings.isEnabled {
                Picker("Background", selection: $settings.background) {
                    ForEach(FramedCaptureBackground.allCases) { background in
                        Text(background.displayName).tag(background)
                    }
                }

                backgroundControls

                VStack(alignment: .leading, spacing: 5) {
                    settingValueLabel("Padding", "\(Int(settings.padding))")
                    Slider(value: $settings.padding, in: 0...180)
                }

                VStack(alignment: .leading, spacing: 5) {
                    settingValueLabel("Corner Radius", "\(Int(settings.cornerRadius))")
                    Slider(value: $settings.cornerRadius, in: 0...48)
                }

                Picker("Shadow", selection: $settings.shadow) {
                    ForEach(FramedCaptureShadow.allCases) { shadow in
                        Text(shadow.displayName).tag(shadow)
                    }
                }

                Picker("Alignment", selection: $settings.alignment) {
                    ForEach(FramedCaptureAlignment.allCases) { alignment in
                        Text(alignment.displayName).tag(alignment)
                    }
                }

                Text("Applies only to the full 16:9 master.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var backgroundControls: some View {
        switch settings.background {
        case .gradient:
            Menu {
                ForEach(FramedGradientPreset.allCases) { preset in
                    Button(preset.displayName) {
                        let colors = preset.colors
                        settings.gradientStartHex = colors.start
                        settings.gradientEndHex = colors.end
                    }
                }
            } label: {
                Label("Gradient Presets", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity)
            }

            ColorPicker("Start", selection: colorBinding(\.gradientStartHex), supportsOpacity: false)
            ColorPicker("End", selection: colorBinding(\.gradientEndHex), supportsOpacity: false)
        case .solidColor:
            ColorPicker("Color", selection: colorBinding(\.solidColorHex), supportsOpacity: false)
        }
    }

    private func settingValueLabel(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<FramedCaptureSettings, String>) -> Binding<Color> {
        Binding(
            get: {
                Color(hex: settings[keyPath: keyPath])
            },
            set: { color in
                if let hex = color.hexString {
                    settings[keyPath: keyPath] = hex
                }
            }
        )
    }
}

private struct SidebarAspectPreviewGrid: View {
    let summary: RecordingSummary
    let previewImage: NSImage?

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 0), spacing: 10),
                GridItem(.flexible(minimum: 0), spacing: 10)
            ],
            alignment: .leading,
            spacing: 10
        ) {
            SidebarAspectPreviewCard(
                title: "4:5",
                subtitle: "Feed",
                aspectRatio: 4.0 / 5.0,
                cameraCrop: cameraCrop,
                previewImage: previewImage
            )
            SidebarAspectPreviewCard(
                title: "9:16",
                subtitle: "Short",
                aspectRatio: 9.0 / 16.0,
                cameraCrop: cameraCrop,
                previewImage: previewImage
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var cameraCrop: CGRect? {
        guard summary.sources.camera,
              summary.videoSize.width > 0,
              summary.videoSize.height > 0,
              let rect = VideoCompositorLayout.overlayRect(
                screen: summary.videoSize,
                camera: PixelSize(width: 16, height: 9),
                settings: summary.overlaySettings
              ) else {
            return nil
        }

        return CGRect(
            x: rect.x / summary.videoSize.width,
            y: rect.y / summary.videoSize.height,
            width: rect.width / summary.videoSize.width,
            height: rect.height / summary.videoSize.height
        )
    }
}

private struct SidebarAspectPreviewCard: View {
    let title: String
    let subtitle: String
    let aspectRatio: Double
    let cameraCrop: CGRect?
    let previewImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    GeometryReader { proxy in
                        previewBody(size: proxy.size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                }

            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func previewBody(size: CGSize) -> some View {
        let cameraHeight = cameraCrop == nil
            ? 0
            : min(size.height * 0.46, size.width * 9.0 / 16.0)
        let topHeight = max(0, size.height - cameraHeight)

        return VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.18)

                if let previewImage {
                    let topImage = previewImage.croppedAspectFillImage(
                        targetAspectRatio: Double(size.width / max(topHeight, 1)),
                        excludingNormalizedRect: cameraCrop
                    ) ?? previewImage
                    Image(nsImage: topImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: topHeight)
                        .clipped()
                } else {
                    Image(systemName: "rectangle.dashed")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: topHeight)
            .clipped()

            if cameraHeight > 0 {
                ZStack {
                    Color.black.opacity(0.34)

                    if let previewImage,
                       let cameraCrop,
                       let cameraImage = previewImage.cropped(toNormalizedRect: cameraCrop) {
                        Image(nsImage: cameraImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: cameraHeight)
                            .clipped()
                    } else if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: cameraHeight)
                            .clipped()
                    }
                }
                .frame(width: size.width, height: cameraHeight)
                .clipped()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

private extension NSImage {
    func croppedAspectFillImage(
        targetAspectRatio: Double,
        excludingNormalizedRect excludedRect: CGRect?
    ) -> NSImage? {
        guard let cropRect = normalizedAspectFillCrop(
            targetAspectRatio: targetAspectRatio,
            excluding: excludedRect
        ) else {
            return nil
        }
        return cropped(toNormalizedRect: cropRect)
    }

    func cropped(toNormalizedRect normalizedRect: CGRect) -> NSImage? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let clampedRect = normalizedRect
            .standardized
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 else {
            return nil
        }

        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: clampedRect.minX * sourceWidth,
            y: (1 - clampedRect.maxY) * sourceHeight,
            width: clampedRect.width * sourceWidth,
            height: clampedRect.height * sourceHeight
        )
        .integral

        let sourceImage = CIImage(cgImage: cgImage)
        let croppedImage = sourceImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        let outputRect = CGRect(origin: .zero, size: cropRect.size)
        guard let outputCGImage = SidebarImageCropper.context.createCGImage(croppedImage, from: outputRect) else {
            return nil
        }

        return NSImage(
            cgImage: outputCGImage,
            size: NSSize(width: outputCGImage.width, height: outputCGImage.height)
        )
    }

    private func normalizedAspectFillCrop(
        targetAspectRatio: Double,
        excluding excludedRect: CGRect?
    ) -> CGRect? {
        guard targetAspectRatio.isFinite, targetAspectRatio > 0,
              let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let sourceAspectRatio = Double(cgImage.width) / Double(max(cgImage.height, 1))
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let centeredCrop = Self.aspectCrop(
            inside: fullRect,
            targetAspectRatio: targetAspectRatio,
            sourceAspectRatio: sourceAspectRatio
        )

        guard let excludedRect else {
            return centeredCrop
        }

        let clampedExcluded = excludedRect
            .standardized
            .intersection(fullRect)
        guard !clampedExcluded.isNull else {
            return centeredCrop
        }

        let candidateBounds = [
            CGRect(x: 0, y: 0, width: 1, height: clampedExcluded.minY),
            CGRect(x: 0, y: clampedExcluded.maxY, width: 1, height: 1 - clampedExcluded.maxY),
            CGRect(x: 0, y: 0, width: clampedExcluded.minX, height: 1),
            CGRect(x: clampedExcluded.maxX, y: 0, width: 1 - clampedExcluded.maxX, height: 1)
        ]

        let candidates = candidateBounds.compactMap { bounds in
            Self.aspectCrop(
                inside: bounds,
                targetAspectRatio: targetAspectRatio,
                sourceAspectRatio: sourceAspectRatio
            )
        }
        let bestCandidate = candidates.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }

        return bestCandidate ?? centeredCrop
    }

    private static func aspectCrop(
        inside bounds: CGRect,
        targetAspectRatio: Double,
        sourceAspectRatio: Double
    ) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let boundsAspectRatio = Double(bounds.width / bounds.height) * sourceAspectRatio
        let cropWidth: Double
        let cropHeight: Double
        if boundsAspectRatio > targetAspectRatio {
            cropHeight = Double(bounds.height)
            cropWidth = cropHeight * targetAspectRatio / sourceAspectRatio
        } else {
            cropWidth = Double(bounds.width)
            cropHeight = cropWidth * sourceAspectRatio / targetAspectRatio
        }

        guard cropWidth > 0, cropHeight > 0,
              cropWidth <= Double(bounds.width) + 0.0001,
              cropHeight <= Double(bounds.height) + 0.0001 else {
            return nil
        }

        return CGRect(
            x: bounds.midX - CGFloat(cropWidth / 2),
            y: bounds.midY - CGFloat(cropHeight / 2),
            width: CGFloat(cropWidth),
            height: CGFloat(cropHeight)
        )
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

private enum SidebarImageCropper {
    static let context = CIContext(options: nil)
}

private extension FramedCaptureShadow {
    var previewColor: Color {
        switch self {
        case .off:
            return .clear
        case .soft:
            return .black.opacity(0.26)
        case .strong:
            return .black.opacity(0.42)
        }
    }

    var previewRadius: CGFloat {
        switch self {
        case .off:
            return 0
        case .soft:
            return 14
        case .strong:
            return 24
        }
    }

    var previewYOffset: CGFloat {
        switch self {
        case .off:
            return 0
        case .soft:
            return 8
        case .strong:
            return 14
        }
    }
}

private extension FramedCaptureAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .center:
            return .center
        case .top:
            return .top
        case .bottom:
            return .bottom
        }
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: cleaned)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        switch cleaned.count {
        case 6:
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
        default:
            red = 0.07
            green = 0.08
            blue = 0.10
        }

        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return nil
        }

        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private struct CaptureTargetPickerSheet: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose What to Record")
                        .font(.title2.weight(.semibold))
                    Text("Pick a display or a single window before recording starts.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await coordinator.refreshCaptureTargets()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isLoadingCaptureTargets)
            }

            Group {
                if coordinator.isLoadingCaptureTargets {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading windows and displays")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if coordinator.captureTargets.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "display.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Capture Targets")
                            .font(.headline)
                        Text("No displays or windows are available. Check Screen Recording permission and try again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 240), spacing: 12)
                            ],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(coordinator.captureTargets) { target in
                                Button {
                                    Task {
                                        await coordinator.startRecording(target: target)
                                    }
                                } label: {
                                    CaptureTargetCard(target: target)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(minHeight: 330)

            HStack {
                Spacer()
                Button("Cancel") {
                    coordinator.dismissCaptureTargetPicker()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 460)
        .task {
            await coordinator.refreshCaptureTargets()
        }
    }
}

private struct CaptureTargetCard: View {
    let target: ScreenCaptureTarget
    var actionTitle = "Record"
    var actionSystemImage = "record.circle"
    var isSelected = false
    @State private var previewImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.32))

                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else {
                        Image(systemName: target.systemImage)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 136)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(target.subtitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(target.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Label(actionTitle, systemImage: actionSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.10), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipped()
        .task(id: target.id) {
            previewImage = target.previewImage(maximumSize: CGSize(width: 520, height: 320))
        }
    }
}

private struct CompactIdleView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    readyHeader
                    readyColumns
                    recordingFooter
                }
                .padding(20)
                .frame(maxWidth: 1120, alignment: .topLeading)
                .liquidGlassSurface(cornerRadius: 26)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await coordinator.refreshCaptureTargets()
            await coordinator.startSetupPreview()
        }
        .onChange(of: coordinator.settings.overlay.isEnabled) { _ in
            restartPreview()
        }
        .onChange(of: coordinator.settings.selectedCameraID) { _ in
            restartPreview()
        }
        .onChange(of: coordinator.settings.microphoneEnabled) { _ in
            restartPreview()
        }
        .onChange(of: coordinator.settings.selectedMicrophoneID) { _ in
            restartPreview()
        }
        .onChange(of: coordinator.settings.systemAudioEnabled) { _ in
            restartPreview()
        }
        .onDisappear {
            Task {
                await coordinator.stopSetupPreview()
            }
        }
    }

    private var readyHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 38, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red, .red.opacity(0.18))

            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to record")
                    .font(.title2.weight(.semibold))
                Text("Check each source, then start when everything looks and sounds right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var readyColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            ReadyCameraColumn()
                .environmentObject(coordinator)
                .frame(maxWidth: .infinity)
            ReadyMicrophoneColumn()
                .environmentObject(coordinator)
                .frame(maxWidth: .infinity)
            ReadySystemAudioColumn()
                .environmentObject(coordinator)
                .frame(maxWidth: .infinity)
            ReadyScreenColumn()
                .environmentObject(coordinator)
                .frame(maxWidth: .infinity)
        }
    }

    private var recordingFooter: some View {
        HStack(spacing: 12) {
            Label(
                "Saving to \(coordinator.settings.outputDirectory.lastPathComponent)",
                systemImage: "folder"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Button("Change Folder") {
                coordinator.chooseOutputDirectory()
            }

            HStack(spacing: 6) {
                Text("Name prefix")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextField("screen-recording", text: $coordinator.settings.fileNamePrefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 156)
                    .accessibilityLabel("Recording file name prefix")
                    .accessibilityHint("The recording date and time are added automatically")
            }

            Spacer()

            Button {
                Task {
                    await coordinator.startRecording()
                }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .liquidGlassSurface(cornerRadius: 16, tint: .red.opacity(0.22), interactive: true)
            .disabled(!coordinator.canStart)
            .keyboardShortcut("r", modifiers: [.command])
        }
    }

    private func restartPreview() {
        Task {
            await coordinator.restartSetupPreviewIfNeeded()
        }
    }
}

private struct ReadySourceCard<Content: View>: View {
    let title: String
    let systemImage: String
    let accentColor: Color
    let content: Content

    init(
        title: String,
        systemImage: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 68, height: 68)
                .background(accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Divider()

            content

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 390, maxHeight: 390, alignment: .top)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct ReadyCameraColumn: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ReadySourceCard(title: "Camera", systemImage: "video.fill", accentColor: .blue) {
            Toggle("Include camera", isOn: $coordinator.settings.overlay.isEnabled)
                .toggleStyle(.switch)

            ReadyCameraPreview()
                .environmentObject(coordinator)

            Picker("Camera", selection: $coordinator.settings.selectedCameraID) {
                Text("Default Camera").tag(String?.none)
                ForEach(coordinator.availableCameras) { camera in
                    Text(camera.name).tag(Optional(camera.id))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Camera")

            Picker("Size", selection: $coordinator.settings.overlay.sizePreset) {
                ForEach(OverlaySizePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!coordinator.settings.overlay.isEnabled)
            .accessibilityLabel("Camera overlay size")
        }
    }
}

private struct ReadyCameraPreview: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.24))

            if !coordinator.settings.overlay.isEnabled {
                previewPlaceholder(systemImage: "video.slash", text: "Camera off")
            } else if let image = coordinator.cameraPreviewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("Live camera preview")
            } else if coordinator.isSetupPreviewStarting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Starting camera preview")
            } else {
                previewPlaceholder(systemImage: "video", text: "Waiting for camera")
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func previewPlaceholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

private struct ReadyMicrophoneColumn: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ReadySourceCard(title: "Microphone", systemImage: "mic.fill", accentColor: .green) {
            Toggle("Include microphone", isOn: $coordinator.settings.microphoneEnabled)
                .toggleStyle(.switch)

            ReadyAudioFeedback(
                level: coordinator.microphoneLevel,
                isEnabled: coordinator.settings.microphoneEnabled,
                listeningText: "Listening to microphone",
                color: .green
            )

            Picker("Microphone", selection: $coordinator.settings.selectedMicrophoneID) {
                Text("Default Microphone").tag(String?.none)
                ForEach(coordinator.availableMicrophones) { microphone in
                    Text(microphone.name).tag(Optional(microphone.id))
                }
            }
            .labelsHidden()
            .disabled(!coordinator.settings.microphoneEnabled)
            .accessibilityLabel("Microphone")

            ReadyGainSlider(
                title: "Mic gain",
                value: $coordinator.settings.microphoneGain,
                systemImage: "mic"
            )
            .disabled(!coordinator.settings.microphoneEnabled)
        }
    }
}

private struct ReadySystemAudioColumn: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ReadySourceCard(title: "System Audio", systemImage: "speaker.wave.2.fill", accentColor: .purple) {
            Toggle("Include system audio", isOn: $coordinator.settings.systemAudioEnabled)
                .toggleStyle(.switch)
                .disabled(!coordinator.isSystemAudioAvailable)

            ReadyAudioFeedback(
                level: coordinator.systemAudioLevel,
                isEnabled: coordinator.settings.systemAudioEnabled && coordinator.isSystemAudioAvailable,
                listeningText: coordinator.isSystemAudioAvailable ? "Listening to Mac audio" : "Unavailable on this Mac",
                color: .purple
            )

            Text("Play something to check that its level moves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ReadyGainSlider(
                title: "System gain",
                value: $coordinator.settings.systemAudioGain,
                systemImage: "speaker.wave.2"
            )
            .disabled(!coordinator.settings.systemAudioEnabled || !coordinator.isSystemAudioAvailable)
        }
    }
}

private struct ReadyScreenColumn: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ReadySourceCard(title: "Screen Recording", systemImage: "display", accentColor: .orange) {
            Label("Always included", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

            ReadyScreenPreview()
                .environmentObject(coordinator)

            Menu {
                ForEach(coordinator.captureTargets) { target in
                    Button {
                        Task {
                            await coordinator.selectCaptureTarget(target)
                        }
                    } label: {
                        Label(
                            target.title,
                            systemImage: target.id == coordinator.selectedCaptureTarget?.id
                                ? "checkmark.circle.fill"
                                : target.systemImage
                        )
                    }
                }
            } label: {
                Label(
                    coordinator.selectedCaptureTarget?.title ?? "Choose a screen or window",
                    systemImage: coordinator.selectedCaptureTarget?.systemImage ?? "display"
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(coordinator.isLoadingCaptureTargets || coordinator.captureTargets.isEmpty)
            .accessibilityLabel("Screen recording target")

            HStack(spacing: 8) {
                Text(screenTargetDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task {
                        await coordinator.refreshCaptureTargets()
                        await coordinator.restartSetupPreviewIfNeeded()
                    }
                } label: {
                    if coordinator.isLoadingCaptureTargets {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(coordinator.isLoadingCaptureTargets)
                .help("Refresh screens and windows")
                .accessibilityLabel("Refresh screens and windows")
            }
        }
    }

    private var screenTargetDetail: String {
        if coordinator.isLoadingCaptureTargets {
            return "Finding screens and windows…"
        }
        if let selectedTarget = coordinator.selectedCaptureTarget {
            return selectedTarget.subtitle
        }
        return "No capture target available"
    }
}

private struct ReadyScreenPreview: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.24))

            if let image = coordinator.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("Live screen preview")
            } else if coordinator.isSetupPreviewStarting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Starting screen preview")
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "display")
                        .font(.title2)
                    Text("Waiting for screen")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ReadyAudioFeedback: View {
    private static let barProfile: [Double] = [
        0.30, 0.48, 0.72, 0.44, 0.88, 0.58, 1.00, 0.67,
        0.42, 0.82, 0.54, 0.94, 0.61, 0.76, 0.46, 0.28
    ]

    let level: Double
    let isEnabled: Bool
    let listeningText: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(Self.barProfile.indices, id: \.self) { index in
                    Capsule()
                        .fill(isEnabled ? color : Color.secondary.opacity(0.35))
                        .frame(width: 4, height: barHeight(at: index))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76)
            .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.08), value: level)

            Text(isEnabled ? listeningText : "Source off")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(listeningText)
        .accessibilityValue(isEnabled ? "Level \(Int(min(1, max(0, level)) * 100)) percent" : "Off")
    }

    private func barHeight(at index: Int) -> Double {
        guard isEnabled else {
            return 4
        }
        let visibleLevel = max(0.035, min(1, level * 2.6))
        return max(4, 68 * Self.barProfile[index] * visibleLevel)
    }
}

private struct ReadyGainSlider: View {
    let title: String
    @Binding var value: Float
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(Int(value * 100))%")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Slider(value: $value, in: 0...2)
                .accessibilityLabel(title)
        }
    }
}

private struct GetStartedView: View {
    private static let repositoryURL = URL(string: "https://github.com/rtemoni/glimpse")!
    let start: () -> Void

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 18) {
                    GlimpseStartIconView()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Glimpse")
                            .font(.system(size: 46, weight: .semibold, design: .rounded))

                        Link("github.com/rtemoni/glimpse", destination: Self.repositoryURL)
                            .font(.callout.weight(.medium))

                        Text("an open source native macos screen/camera recorder and clip editor")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("by rtemoni")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 600, alignment: .center)

                Button(action: start) {
                    Label("Start", systemImage: "arrow.right.circle.fill")
                        .frame(width: 136)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .liquidGlassSurface(cornerRadius: 14, tint: .accentColor.opacity(0.16), interactive: true)
            }
            .padding(36)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GlimpseStartIconView: View {
    var body: some View {
        Group {
            if let image = Self.packageImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "record.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .secondary)
                    .scaledToFit()
            }
        }
        .frame(width: 108, height: 108)
        .offset(y: -4)
        .accessibilityHidden(true)
    }

    private static var packageImage: NSImage? {
        AppResources.image(named: "GlimpseStartIcon", withExtension: "png")
    }
}

private struct PermissionOnboardingView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Set Up Permissions", systemImage: "checklist")
                    .font(.system(size: 28, weight: .semibold))
                Text("Grant the required macOS permissions before setting up a recording. Glimpse checks the current permission state each time this window appears and whenever you return from System Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(coordinator.permissionChecklist) { item in
                    PermissionChecklistRow(item: item) {
                        Task {
                            await coordinator.performPermissionAction(for: item.requirement)
                        }
                    }

                    if item.id != coordinator.permissionChecklist.last?.id {
                        Divider()
                            .padding(.leading, 62)
                    }
                }
            }
            .liquidGlassSurface(cornerRadius: 22)

            HStack(spacing: 12) {
                Button {
                    coordinator.refreshPermissionStatuses()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .liquidGlassSurface(cornerRadius: 14, interactive: true)

                Spacer()

                Label(
                    "\(coordinator.approvedRequiredPermissionCount) of \(coordinator.requiredPermissionCount) detected",
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(34)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LiquidGlassBackdrop())
        .onAppear {
            coordinator.startPermissionMonitoring()
        }
        .onDisappear {
            coordinator.stopPermissionMonitoring()
        }
    }
}

private struct PermissionChecklistRow: View {
    let item: PermissionChecklistItem
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.requirement.systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 34, height: 34)
                .background(statusColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.requirement.title)
                        .font(.headline)
                    if !item.isRequired {
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(item.requirement.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            Label(item.state.label, systemImage: statusImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .frame(width: 128, alignment: .leading)

            if let actionTitle = item.actionTitle {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionImage)
                        .frame(width: 122)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusImage: String {
        switch item.state {
        case .approved:
            return "checkmark.circle.fill"
        case .notRequested:
            return "circle"
        case .needsSettings:
            return "gearshape"
        case .restricted:
            return "lock.fill"
        case .waitingForScreenRecording:
            return "clock"
        case .unavailable:
            return "slash.circle"
        }
    }

    private var actionImage: String {
        item.state == .notRequested ? "hand.tap" : "gearshape"
    }

    private var statusColor: Color {
        switch item.state {
        case .approved:
            return .green
        case .notRequested:
            return .accentColor
        case .needsSettings:
            return .orange
        case .restricted:
            return .red
        case .waitingForScreenRecording:
            return .secondary
        case .unavailable:
            return .secondary
        }
    }
}

private struct RecordingStatusPane: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: statusImage)
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(statusColor)
                .frame(width: 72, height: 72)

            Text(coordinator.elapsedTimeLabel)
                .font(.system(size: 34, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 8) {
                StatusPill(text: coordinator.state.displayName, systemImage: statePillImage)
                if coordinator.settings.systemAudioEnabled {
                    StatusPill(text: "System", systemImage: "speaker.wave.2")
                }
                if coordinator.settings.microphoneEnabled {
                    StatusPill(text: "Mic", systemImage: "mic")
                }
                if coordinator.settings.overlay.isEnabled {
                    StatusPill(text: "Camera", systemImage: "video")
                }
            }

            if let status = coordinator.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.08))
        }
    }

    private var statusImage: String {
        switch coordinator.state {
        case .recording:
            return "record.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .preparing, .ready:
            return "hourglass.circle"
        case .stopping:
            return "stop.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "circle"
        }
    }

    private var statePillImage: String {
        switch coordinator.state {
        case .recording:
            return "record.circle"
        case .paused:
            return "pause.circle"
        case .error:
            return "exclamationmark.triangle"
        default:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .recording:
            return .red
        case .paused:
            return .orange
        case .error:
            return .red
        default:
            return .secondary
        }
    }
}

private struct StatusPill: View {
    var text: String
    var systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .liquidGlassSurface(cornerRadius: 10)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ControlBar: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalControls
            compactControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlassSurface(cornerRadius: 20)
    }

    private var horizontalControls: some View {
        HStack(spacing: 12) {
            recordingButtons

            Divider()
                .frame(height: 24)

            TimerBadge(label: coordinator.elapsedTimeLabel)

            sourceToggles

            AudioLevelMeter(level: coordinator.microphoneLevel)
                .frame(width: 96)

            Spacer(minLength: 12)

            statusText
        }
    }

    private var compactControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                recordingIconButtons
                Spacer(minLength: 8)
                TimerBadge(label: coordinator.elapsedTimeLabel)
            }

            HStack(spacing: 10) {
                sourceToggles
                AudioLevelMeter(level: coordinator.microphoneLevel)
                    .frame(width: 82)
                Spacer(minLength: 8)
                statusText
            }
        }
    }

    private var recordingButtons: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.openCaptureTargetPicker()
            } label: {
                Label("Choose & Start", systemImage: "record.circle")
                    .lineLimit(1)
            }
            .disabled(!coordinator.canStart)
            .keyboardShortcut("r", modifiers: [.command])

            Button {
                coordinator.togglePause()
            } label: {
                Label(coordinator.state == .paused ? "Resume" : "Pause", systemImage: coordinator.state == .paused ? "play.circle" : "pause.circle")
                    .lineLimit(1)
            }
            .disabled(!coordinator.canPauseOrResume)

            Button(role: .destructive) {
                Task {
                    await coordinator.stopRecording()
                }
            } label: {
                Label("Stop", systemImage: "stop.circle")
                    .lineLimit(1)
            }
            .disabled(!coordinator.canStop)
            .keyboardShortcut(".", modifiers: [.command])
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var recordingIconButtons: some View {
        HStack(spacing: 6) {
            Button {
                coordinator.openCaptureTargetPicker()
            } label: {
                Image(systemName: "record.circle")
                    .frame(width: 22)
            }
            .disabled(!coordinator.canStart)
            .help("Start Recording")
            .accessibilityLabel("Start Recording")

            Button {
                coordinator.togglePause()
            } label: {
                Image(systemName: coordinator.state == .paused ? "play.circle" : "pause.circle")
                    .frame(width: 22)
            }
            .disabled(!coordinator.canPauseOrResume)
            .help(coordinator.state == .paused ? "Resume Recording" : "Pause Recording")
            .accessibilityLabel(coordinator.state == .paused ? "Resume Recording" : "Pause Recording")

            Button(role: .destructive) {
                Task {
                    await coordinator.stopRecording()
                }
            } label: {
                Image(systemName: "stop.circle")
                    .frame(width: 22)
            }
            .disabled(!coordinator.canStop)
            .help("Stop Recording")
            .accessibilityLabel("Stop Recording")
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sourceToggles: some View {
        HStack(spacing: 6) {
            SourceToggle(
                title: "Camera",
                systemImage: "video",
                isOn: $coordinator.settings.overlay.isEnabled
            )

            SourceToggle(
                title: "Mic",
                systemImage: "mic",
                isOn: $coordinator.settings.microphoneEnabled
            )

            SourceToggle(
                title: "System",
                systemImage: "speaker.wave.2",
                isOn: $coordinator.settings.systemAudioEnabled
            )
            .disabled(!coordinator.isSystemAudioAvailable)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var statusText: some View {
        if let status = coordinator.statusMessage {
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
        }
    }
}

private struct TimerBadge: View {
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "timer")
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(.body, design: .monospaced).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Elapsed time \(label)")
    }
}

private struct SourceToggle: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: displayedSystemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.primary : Color.secondary)
        .frame(width: 32, height: 28)
        .liquidGlassSurface(
            cornerRadius: 14,
            tint: isOn ? Color.accentColor.opacity(0.18) : nil,
            interactive: true
        )
        .opacity(isEnabled ? 1 : 0.45)
        .help(isOn ? "\(title) On" : "\(title) Off")
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var displayedSystemImage: String {
        isOn ? systemImage : sourceDisabledSystemImage(for: systemImage)
    }
}

private func sourceDisabledSystemImage(for systemImage: String) -> String {
    switch systemImage {
    case "video":
        return "video.slash"
    case "mic":
        return "mic.slash"
    case "speaker.wave.2":
        return "speaker.slash"
    default:
        return systemImage
    }
}

private struct AudioLevelMeter: View {
    var level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                RoundedRectangle(cornerRadius: 4)
                    .fill(level > 0.8 ? Color.red : Color.accentColor)
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Microphone level")
    }
}

private struct SettingsPane: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.title3.weight(.semibold))

                OutputSettings()
                    .environmentObject(coordinator)
                Divider()

                VideoSettings()
                    .environmentObject(coordinator)
                Divider()

                AudioSettings()
                    .environmentObject(coordinator)
                Divider()

                OverlaySettingsView()
                    .environmentObject(coordinator)
                Divider()

                ReleaseSettingsView()
                    .environmentObject(coordinator)
            }
            .padding(18)
        }
        .liquidGlassSurface(cornerRadius: 24)
        .padding(12)
    }
}

private struct OutputSettings: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output")
                .font(.headline)

            HStack(alignment: .center, spacing: 8) {
                Label {
                    Text(coordinator.settings.outputDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    coordinator.chooseOutputDirectory()
                } label: {
                    Label("Choose", systemImage: "folder.badge.gearshape")
                }

                Button {
                    coordinator.openOutputDirectory()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open output folder in Finder")
            }

            TextField("File Prefix", text: $coordinator.settings.fileNamePrefix)
            Label("Records a high-quality MOV master for editing. Choose final format during export.", systemImage: "film")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct VideoSettings: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Video")
                .font(.headline)
            Picker("Camera", selection: $coordinator.settings.selectedCameraID) {
                Text("Default Camera").tag(String?.none)
                ForEach(coordinator.availableCameras) { camera in
                    Text(camera.name).tag(Optional(camera.id))
                }
            }
        }
    }
}

private struct AudioSettings: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio")
                .font(.headline)
            Picker("Microphone", selection: $coordinator.settings.selectedMicrophoneID) {
                Text("Default Microphone").tag(String?.none)
                ForEach(coordinator.availableMicrophones) { microphone in
                    Text(microphone.name).tag(Optional(microphone.id))
                }
            }
            Toggle("Microphone", isOn: $coordinator.settings.microphoneEnabled)
            Toggle("System Audio", isOn: $coordinator.settings.systemAudioEnabled)
                .disabled(!coordinator.isSystemAudioAvailable)
            Slider(value: $coordinator.settings.microphoneGain, in: 0...2) {
                Text("Mic Gain")
            } minimumValueLabel: {
                Image(systemName: "mic.slash")
            } maximumValueLabel: {
                Image(systemName: "mic")
            }
            Slider(value: $coordinator.settings.systemAudioGain, in: 0...2) {
                Text("System Gain")
            } minimumValueLabel: {
                Image(systemName: "speaker.slash")
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.2")
            }
        }
    }
}

private struct OverlaySettingsView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overlay")
                .font(.headline)
            Toggle("Camera Overlay", isOn: $coordinator.settings.overlay.isEnabled)
            Picker("Size", selection: $coordinator.settings.overlay.sizePreset) {
                ForEach(OverlaySizePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            Picker("Position", selection: $coordinator.settings.overlay.position) {
                ForEach(OverlayPosition.allCases) { position in
                    Label(position.displayName, systemImage: position.systemImage)
                        .tag(position)
                }
            }
            Picker("Shape", selection: $coordinator.settings.overlay.shape) {
                ForEach(OverlayShape.allCases) { shape in
                    Label(shape.displayName, systemImage: shape.systemImage)
                        .tag(shape)
                }
            }
            Toggle("Shadow", isOn: $coordinator.settings.overlay.hasShadow)
            Slider(value: $coordinator.settings.overlay.cornerRadius, in: 0...32) {
                Text("Corner Radius")
            }
            .disabled(coordinator.settings.overlay.shape == .circle)
        }
    }
}

private struct ReleaseSettingsView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Release")
                .font(.headline)

            HStack(spacing: 8) {
                Label("Version \(coordinator.appVersion)", systemImage: "shippingbox")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task {
                        await coordinator.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    if coordinator.isCheckingForUpdates {
                        Label("Checking", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Check", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(coordinator.isCheckingForUpdates)
            }

            if let status = coordinator.updateStatusMessage {
                Label(status, systemImage: "sparkle.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LiquidGlassBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.cyan.opacity(0.14),
                    Color.orange.opacity(0.10),
                    Color(nsColor: .windowBackgroundColor).opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct LiquidGlassCluster<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    content
                }
            } else {
                content
            }
        }
    }
}

private extension View {
    func previewSurface(cornerRadius: CGFloat) -> some View {
        self
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    func liquidGlassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(
                    .regular
                        .tint(tint)
                        .interactive(interactive),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                self.glassEffect(
                    .regular
                        .interactive(interactive),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

private extension OverlayPosition {
    var systemImage: String {
        switch self {
        case .bottomLeft:
            return "arrow.down.left"
        case .topLeft:
            return "arrow.up.left"
        case .topRight:
            return "arrow.up.right"
        case .bottomRight:
            return "arrow.down.right"
        case .topMiddle:
            return "arrow.up"
        case .bottomMiddle:
            return "arrow.down"
        }
    }
}

private extension OverlayShape {
    var systemImage: String {
        switch self {
        case .rectangle:
            return "rectangle"
        case .square:
            return "square"
        case .circle:
            return "circle"
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else {
        return "00:00"
    }
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

private func formatFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private enum WindowPresentationMode: Equatable {
    case getStarted
    case splash
    case editor
    case onboarding
    case workspace

    var minimumSize: NSSize {
        switch self {
        case .getStarted:
            return NSSize(width: 540, height: 480)
        case .splash:
            return NSSize(width: 900, height: 600)
        case .editor:
            return NSSize(width: 880, height: 620)
        case .onboarding:
            return NSSize(width: 680, height: 500)
        case .workspace:
            return NSSize(width: 560, height: 360)
        }
    }

    var preferredSize: NSSize {
        switch self {
        case .getStarted:
            return NSSize(width: 640, height: 540)
        case .splash:
            return NSSize(width: 1060, height: 660)
        case .editor:
            return NSSize(width: 1120, height: 720)
        case .onboarding:
            return NSSize(width: 760, height: 640)
        case .workspace:
            return NSSize(width: 900, height: 480)
        }
    }
}

private struct WindowSizingController: NSViewRepresentable {
    let mode: WindowPresentationMode

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }

            window.minSize = mode.minimumSize
            guard context.coordinator.lastMode != mode else {
                return
            }

            context.coordinator.lastMode = mode
            window.setContentSize(mode.preferredSize)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastMode: WindowPresentationMode?
    }
}
#endif
