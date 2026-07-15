#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
import GlimpseCore
import SwiftUI

struct UpdateAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var downloadURL: URL?
    var releaseNotesURL: URL?
}

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var settings = RecorderSettings()
    @Published var availableCameras: [SourceDevice] = []
    @Published var availableMicrophones: [SourceDevice] = []
    @Published var previewImage: NSImage?
    @Published private(set) var cameraPreviewImage: NSImage?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var microphoneLevel: Double = 0
    @Published private(set) var systemAudioLevel: Double = 0
    @Published private(set) var elapsedSeconds: Int = 0
    @Published var isSystemAudioAvailable = true
    @Published private(set) var isSetupPreviewActive = false
    @Published private(set) var isSetupPreviewStarting = false
    @Published private(set) var recordingPresentationToken: UUID?
    @Published private(set) var permissionChecklist: [PermissionChecklistItem] = []
    @Published var recordingSummary: RecordingSummary?
    @Published var editingSession: EditingSession?
    @Published var exportSettings = ExportSettings()
    @Published private(set) var exportedVideos: [ExportedVideo] = []
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published var isCaptureTargetPickerPresented = false
    @Published private(set) var captureTargets: [ScreenCaptureTarget] = []
    @Published private(set) var isLoadingCaptureTargets = false
    @Published private(set) var selectedCaptureTarget: ScreenCaptureTarget?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var updateStatusMessage: String?
    @Published var updateAlert: UpdateAlert?

    private var stateMachine = RecordingStateMachine()
    private let screenCapture = ScreenCaptureService()
    private let cameraCapture = CameraCaptureService()
    private let audioCapture = AudioCaptureService()
    private let compositor = VideoCompositor()
    private let muxer = Muxer()
    private let recordingLeadTrimmer = RecordingLeadTrimmer()
    private let videoExporter = VideoExporter()
    private let updateChecker = GitHubUpdateChecker()
    private var elapsedTimer: Timer?
    private var permissionTimer: Timer?
    private var recordingStartedAt: Date?
    private var lastOutputURL: URL?
    private var activeSourceSet = RecordingSourceSet(camera: false, microphone: false, systemAudio: false)
    private var activeCaptureTargetKind: RecordingCaptureTargetKind = .display
    private var setupPreviewStartID: UUID?
    private var setupPreviewStartTask: Task<Void, Never>?
    private var lastCameraPreviewTimestamp = -Double.infinity
    private var lastMicrophoneLevelUpdate = -Double.infinity
    private var lastSystemAudioLevelUpdate = -Double.infinity
    private let lastAutomaticUpdateCheckKey = "Glimpse.lastAutomaticUpdateCheck"
    private let screenRecordingAccessPromptedKey = "Glimpse.screenRecordingAccessPrompted"
    /// Set after we send the user to Screen Recording settings (or a non-granted request).
    /// macOS only applies that TCC grant to a new process, so onboarding must offer relaunch.
    private var pendingScreenRecordingRelaunch = false

    init() {
        isSystemAudioAvailable = AudioCaptureService.isSystemAudioCaptureSupported
        refreshPermissionStatuses()
        wireCaptureCallbacks()
    }

    deinit {
        permissionTimer?.invalidate()
    }

    var canStart: Bool {
        state == .idle || state == .error
    }

    var canStop: Bool {
        switch state {
        case .preparing, .ready, .recording, .paused:
            return true
        case .idle, .stopping, .error:
            return false
        }
    }

    var canPauseOrResume: Bool {
        state == .recording || state == .paused
    }

    var requiredPermissionCount: Int {
        permissionChecklist.filter(\.isRequired).count
    }

    var approvedRequiredPermissionCount: Int {
        permissionChecklist.filter { $0.isRequired && $0.state.isApproved }.count
    }

    var isOnboardingComplete: Bool {
        let requiredItems = permissionChecklist.filter(\.isRequired)
        return !requiredItems.isEmpty && requiredItems.allSatisfy(\.isSatisfied)
    }

    var shouldShowOnboarding: Bool {
        !isOnboardingComplete && (state == .idle || state == .error)
    }

    var shouldShowCompactIdle: Bool {
        state == .idle && previewImage == nil && statusMessage == nil && recordingSummary == nil
    }

    var elapsedTimeLabel: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var hasErrorBinding: Binding<Bool> {
        Binding(
            get: { self.errorMessage != nil },
            set: { if !$0 { self.clearError() } }
        )
    }

    func refreshDevices() {
        availableCameras = CameraCaptureService.availableCameraDevices()
        availableMicrophones = AudioCaptureService.availableMicrophoneDevices()
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        settings.outputDirectory = url
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(settings.outputDirectory)
    }

    func checkForUpdatesIfNeeded() {
        let defaults = UserDefaults.standard
        let lastCheck = defaults.object(forKey: lastAutomaticUpdateCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) > 24 * 60 * 60 else {
            return
        }

        defaults.set(Date(), forKey: lastAutomaticUpdateCheckKey)
        Task {
            await checkForUpdates(userInitiated: false)
        }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        if userInitiated {
            updateStatusMessage = "Checking for updates..."
        }

        do {
            let result = try await updateChecker.check(currentVersion: appVersion)
            if result.isUpdateAvailable {
                updateStatusMessage = "Glimpse \(result.manifest.version) is available."
                updateAlert = UpdateAlert(
                    title: "Glimpse \(result.manifest.version) is available",
                    message: "You are running \(result.currentVersion). Download the latest release from GitHub.",
                    downloadURL: result.manifest.downloadURL,
                    releaseNotesURL: result.manifest.releaseNotesURL
                )
            } else if userInitiated {
                updateStatusMessage = "Glimpse is up to date."
                updateAlert = UpdateAlert(
                    title: "Glimpse is up to date",
                    message: "You are running the latest release, version \(result.currentVersion).",
                    downloadURL: nil,
                    releaseNotesURL: result.manifest.releaseNotesURL
                )
            }
        } catch {
            if userInitiated {
                updateStatusMessage = "Unable to check for updates."
                updateAlert = UpdateAlert(
                    title: "Unable to Check for Updates",
                    message: readableError(error),
                    downloadURL: nil,
                    releaseNotesURL: nil
                )
            }
        }

        isCheckingForUpdates = false
    }

    func openUpdateDownload(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func startPermissionMonitoring() {
        refreshPermissionStatuses()

        guard !isOnboardingComplete else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }

        permissionTimer?.invalidate()
        // Use `.common` so polling continues while menus/tracking run loops are active
        // (for example while the user is away in System Settings and returns).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionStatuses()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func stopPermissionMonitoring() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func refreshPermissionStatuses() {
        let screenState = screenRecordingPermissionState()
        permissionChecklist = [
            PermissionChecklistItem(
                requirement: .screenRecording,
                state: screenState,
                isRequired: true
            ),
            PermissionChecklistItem(
                requirement: .camera,
                state: permissionState(for: AVCaptureDevice.authorizationStatus(for: .video)),
                isRequired: true
            ),
            PermissionChecklistItem(
                requirement: .microphone,
                state: permissionState(for: AVCaptureDevice.authorizationStatus(for: .audio)),
                isRequired: true
            ),
            PermissionChecklistItem(
                requirement: .systemAudio,
                state: systemAudioPermissionState(screenState: screenState),
                isRequired: false
            )
        ]

        if isOnboardingComplete {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    func performPermissionAction(for requirement: PermissionRequirement) async {
        switch requirement {
        case .screenRecording:
            await handleScreenRecordingPermissionAction()
        case .camera:
            await requestOrOpenAVPermission(for: .video, requirement: .camera)
        case .microphone:
            await requestOrOpenAVPermission(for: .audio, requirement: .microphone)
        case .systemAudio:
            await handleSystemAudioPermissionAction()
        }

        refreshPermissionStatuses()
        refreshDevices()
    }

    /// Relaunches the running app so macOS TCC grants for Screen Recording take effect.
    func relaunchForUpdatedPermissions() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
            // Ensure we quit even if the open callback is delayed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
            return
        }

        // Unpackaged / `swift run` executable path.
        guard let executableURL = Bundle.main.executableURL else {
            statusMessage = "Quit and reopen Glimpse to apply Screen Recording permission."
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            statusMessage = "Quit and reopen Glimpse to apply Screen Recording permission."
        }
    }

    func startRecording() async {
        await startRecording(target: selectedCaptureTarget)
    }

    func startSetupPreview() async {
        guard state == .idle, !isSetupPreviewActive, !isSetupPreviewStarting else {
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            previewImage = nil
            statusMessage = "Enable Screen Recording to preview setup"
            refreshPermissionStatuses()
            return
        }

        isSetupPreviewStarting = true
        let startID = UUID()
        let startTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performSetupPreviewStart(id: startID)
        }
        setupPreviewStartID = startID
        setupPreviewStartTask = startTask

        await startTask.value

        if setupPreviewStartID == startID {
            setupPreviewStartID = nil
            setupPreviewStartTask = nil
        }
    }

    private func performSetupPreviewStart(id startID: UUID) async {
        defer {
            if setupPreviewStartID == startID {
                isSetupPreviewStarting = false
            }
        }
        var previewStatus = "Previewing setup"

        do {
            if selectedCaptureTarget == nil {
                await refreshCaptureTargets()
            }
            try Task.checkCancellation()
            guard setupPreviewStartID == startID, state == .idle else {
                return
            }

            _ = try await screenCapture.prepare(target: selectedCaptureTarget)
            try Task.checkCancellation()
            guard setupPreviewStartID == startID, state == .idle else {
                await screenCapture.stop()
                return
            }

            var includeCamera = false
            if settings.overlay.isEnabled {
                if await isCameraReadyForSetupPreview() {
                    try Task.checkCancellation()
                    guard setupPreviewStartID == startID, state == .idle else {
                        await screenCapture.stop()
                        return
                    }
                    do {
                        try cameraCapture.prepare(deviceID: settings.selectedCameraID)
                        includeCamera = true
                    } catch {
                        previewStatus = "Previewing screen only; camera unavailable"
                    }
                } else {
                    previewStatus = "Previewing screen only; camera permission needed"
                }
            }

            let includeMicrophone = settings.microphoneEnabled
                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let includeSystemAudio = settings.systemAudioEnabled && isSystemAudioAvailable
            var isAudioMonitorPrepared = false
            if includeMicrophone || includeSystemAudio {
                do {
                    try await audioCapture.prepare(
                        microphoneDeviceID: settings.selectedMicrophoneID,
                        includeMicrophone: includeMicrophone,
                        includeSystemAudio: includeSystemAudio
                    )
                    isAudioMonitorPrepared = true
                } catch {
                    previewStatus = "Previewing video; audio monitor unavailable"
                }
            }
            try Task.checkCancellation()
            guard setupPreviewStartID == startID, state == .idle else {
                await screenCapture.stop()
                cameraCapture.stop()
                await audioCapture.stop()
                return
            }

            try await screenCapture.start()
            try Task.checkCancellation()
            guard setupPreviewStartID == startID, state == .idle else {
                await screenCapture.stop()
                cameraCapture.stop()
                await audioCapture.stop()
                return
            }
            if includeCamera {
                cameraCapture.start()
            }
            if isAudioMonitorPrepared {
                do {
                    try await audioCapture.start()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await audioCapture.stop()
                    previewStatus = "Previewing video; audio monitor unavailable"
                }
            }
            try Task.checkCancellation()
            guard setupPreviewStartID == startID, state == .idle else {
                await screenCapture.stop()
                cameraCapture.stop()
                await audioCapture.stop()
                return
            }

            isSetupPreviewActive = true
            statusMessage = previewStatus
        } catch {
            await screenCapture.stop()
            cameraCapture.stop()
            await audioCapture.stop()
            if setupPreviewStartID == startID, !Task.isCancelled {
                errorMessage = readableError(error)
            }
        }

    }

    func stopSetupPreview() async {
        guard isSetupPreviewActive || isSetupPreviewStarting else {
            return
        }

        let startID = setupPreviewStartID
        let startTask = setupPreviewStartTask
        // ScreenCaptureKit preparation is asynchronous. Wait for a cancelled start to unwind
        // before another preview or an explicit recording reuses the capture service.
        startTask?.cancel()
        await startTask?.value
        if setupPreviewStartID == startID {
            setupPreviewStartID = nil
            setupPreviewStartTask = nil
        }

        await screenCapture.stop()
        cameraCapture.stop()
        await audioCapture.stop()
        isSetupPreviewActive = false
        isSetupPreviewStarting = false
        previewImage = nil
        cameraPreviewImage = nil
        microphoneLevel = 0
        systemAudioLevel = 0
        lastCameraPreviewTimestamp = -Double.infinity
        lastMicrophoneLevelUpdate = -Double.infinity
        lastSystemAudioLevelUpdate = -Double.infinity

        if statusMessage?.hasPrefix("Previewing") == true
            || statusMessage == "Enable Screen Recording to preview setup" {
            statusMessage = nil
        }
    }

    func restartSetupPreviewIfNeeded() async {
        guard isSetupPreviewActive || isSetupPreviewStarting else {
            return
        }

        await stopSetupPreview()
        await startSetupPreview()
    }

    func selectCaptureTarget(_ target: ScreenCaptureTarget) async {
        selectedCaptureTarget = target
        await restartSetupPreviewIfNeeded()
    }

    func openCaptureTargetPicker() {
        guard canStart else {
            refreshPermissionStatuses()
            return
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            openPermissionSettings(for: .screenRecording)
            errorMessage = "Screen recording permission is required before choosing what to record."
            refreshPermissionStatuses()
            return
        }

        isCaptureTargetPickerPresented = true
        Task {
            await refreshCaptureTargets()
        }
    }

    func dismissCaptureTargetPicker() {
        isCaptureTargetPickerPresented = false
    }

    func refreshCaptureTargets() async {
        isLoadingCaptureTargets = true
        do {
            let targets = try await ScreenCaptureService.availableTargets()
            captureTargets = targets
            reconcileSelectedCaptureTarget(with: targets)
        } catch {
            errorMessage = readableError(error)
            captureTargets = []
            selectedCaptureTarget = nil
        }
        isLoadingCaptureTargets = false
    }

    func startRecording(target: ScreenCaptureTarget) async {
        isCaptureTargetPickerPresented = false
        await startRecording(target: Optional(target))
    }

    private func startRecording(target: ScreenCaptureTarget?) async {
        guard canStart else {
            refreshPermissionStatuses()
            return
        }

        await stopSetupPreview()
        resetForNewRecording()
        do {
            try transition { try $0.startPreparing() }
            statusMessage = "Preparing"

            if settings.systemAudioEnabled && !isSystemAudioAvailable {
                settings.systemAudioEnabled = false
                statusMessage = systemAudioUnavailableMessage(includeMicrophone: settings.microphoneEnabled)
            }

            let includeCamera = settings.overlay.isEnabled
            let includeMicrophone = settings.microphoneEnabled
            let includeSystemAudio = settings.systemAudioEnabled && isSystemAudioAvailable
            try await verifyPermissions(includeCamera: includeCamera, includeMicrophone: includeMicrophone)
            activeCaptureTargetKind = target?.recordingCaptureTargetKind ?? .display

            settings.fileFormat = .mov
            let outputURL = try makeOutputURL()
            let captureSize = try await screenCapture.prepare(target: target)
            if includeCamera {
                try cameraCapture.prepare(deviceID: settings.selectedCameraID)
            }
            try await audioCapture.prepare(
                microphoneDeviceID: settings.selectedMicrophoneID,
                includeMicrophone: includeMicrophone,
                includeSystemAudio: includeSystemAudio
            )
            if includeSystemAudio && !audioCapture.isSystemAudioActive {
                settings.systemAudioEnabled = false
                statusMessage = systemAudioUnavailableMessage(includeMicrophone: includeMicrophone)
            }
            activeSourceSet = RecordingSourceSet(
                camera: includeCamera,
                microphone: includeMicrophone,
                systemAudio: includeSystemAudio && audioCapture.isSystemAudioActive
            )
            try muxer.start(
                outputURL: outputURL,
                videoSize: captureSize,
                fileFormat: .mov,
                includeMicrophone: includeMicrophone,
                includeSystemAudio: includeSystemAudio && audioCapture.isSystemAudioActive
            )

            try await screenCapture.start()
            if includeCamera {
                cameraCapture.start()
            }
            try await audioCapture.start()

            lastOutputURL = outputURL
            try transition { try $0.markReady() }
            try transition { try $0.startRecording() }
            recordingPresentationToken = UUID()
            recordingStartedAt = Date()
            startElapsedTimer()
            statusMessage = "Recording"
        } catch {
            await stopCaptureComponents()
            muxer.cancel()
            stateMachine.fail()
            state = stateMachine.state
            recordingPresentationToken = nil
            errorMessage = readableError(error)
            statusMessage = nil
        }
    }

    func stopRecording() async {
        guard canStop else {
            return
        }

        do {
            try transition { try $0.startStopping() }
        } catch {
            stateMachine.fail()
            state = stateMachine.state
            errorMessage = readableError(error)
            return
        }

        stopElapsedTimer()
        await stopCaptureComponents()
        statusMessage = "Finishing recording"

        do {
            try await muxer.finish()
            if let lastOutputURL {
                statusMessage = "Removing capture warmup"
                try await recordingLeadTrimmer.trimRecording(at: lastOutputURL)
            }
            try transition { try $0.finishStopped() }
            recordingPresentationToken = nil
            if let lastOutputURL {
                let summary = makeRecordingSummary(for: lastOutputURL, sources: activeSourceSet)
                recordingSummary = summary
                editingSession = EditingSession(sourceDuration: summary.duration)
                exportedVideos = []
                statusMessage = "Ready to edit"
            } else {
                statusMessage = "Recording saved"
            }
        } catch {
            muxer.cancel()
            stateMachine.fail()
            state = stateMachine.state
            recordingPresentationToken = nil
            errorMessage = readableError(error)
            statusMessage = nil
        }
    }

    func togglePause() {
        do {
            if state == .recording {
                try transition { try $0.pause() }
                muxer.setPaused(true)
                statusMessage = "Paused"
            } else if state == .paused {
                try transition { try $0.resume() }
                muxer.setPaused(false)
                statusMessage = "Recording"
            }
        } catch {
            stateMachine.fail()
            state = stateMachine.state
            errorMessage = readableError(error)
        }
    }

    func clearError() {
        errorMessage = nil
        if state == .error {
            stateMachine.reset()
            state = stateMachine.state
        }
    }

    func recordAgain() {
        recordingSummary = nil
        editingSession = nil
        exportedVideos = []
        statusMessage = nil
        previewImage = nil
        elapsedSeconds = 0
        if state == .error {
            stateMachine.reset()
            state = stateMachine.state
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func exportEditedRecording() async {
        guard let recordingSummary, let editingSession, !isExporting else {
            return
        }

        isExporting = true
        exportProgress = 0
        exportedVideos = []
        statusMessage = "Exporting"

        do {
            let outputVideos = try await videoExporter.export(
                sourceURL: recordingSummary.sourceURL,
                session: editingSession,
                settings: exportSettings,
                outputDirectory: settings.outputDirectory,
                fileNamePrefix: settings.fileNamePrefix,
                sourceBitrate: recordingSummary.sourceBitrate,
                sourceVideoSize: recordingSummary.videoSize,
                captureTargetKind: recordingSummary.captureTargetKind,
                recordingSources: recordingSummary.sources,
                overlaySettings: recordingSummary.overlaySettings,
                progressHandler: { [weak self] progress in
                    self?.exportProgress = progress
                }
            )
            exportedVideos = outputVideos
            exportProgress = 1
            statusMessage = outputVideos.count == 1 ? "Export complete" : "\(outputVideos.count) exports complete"
        } catch {
            errorMessage = readableError(error)
            statusMessage = nil
        }

        isExporting = false
    }

    private func wireCaptureCallbacks() {
        screenCapture.frameHandler = { [weak self] frame in
            Task { @MainActor in
                self?.handleScreenFrame(frame)
            }
        }
        cameraCapture.frameHandler = { [weak self] frame in
            Task { @MainActor in
                self?.handleCameraFrame(frame)
            }
        }
        audioCapture.sampleHandler = { [weak self] sampleBuffer, source in
            Task { @MainActor in
                guard let self, self.state == .recording else {
                    return
                }
                guard self.shouldRecordAudioSample(from: source) else {
                    if source == .microphone {
                        self.microphoneLevel = 0
                    }
                    return
                }
                self.muxer.appendAudioSampleBuffer(
                    sampleBuffer,
                    source: source,
                    gain: source == .microphone ? self.settings.microphoneGain : self.settings.systemAudioGain
                )
            }
        }
        audioCapture.levelHandler = { [weak self] level, source in
            Task { @MainActor in
                self?.handleAudioLevel(level, source: source)
            }
        }
    }

    private func handleCameraFrame(_ frame: CapturedVideoFrame) {
        compositor.updateCameraFrame(frame)

        guard settings.overlay.isEnabled,
              isSetupPreviewActive || isSetupPreviewStarting,
              frame.timestamp.seconds - lastCameraPreviewTimestamp >= 0.1 else {
            return
        }

        lastCameraPreviewTimestamp = frame.timestamp.seconds
        cameraPreviewImage = compositor.makePreviewImage(from: frame.pixelBuffer)
    }

    private func handleAudioLevel(_ level: Double, source: AudioSourceKind) {
        guard state == .recording || isSetupPreviewActive || isSetupPreviewStarting else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        switch source {
        case .microphone:
            guard settings.microphoneEnabled,
                  now - lastMicrophoneLevelUpdate >= 0.05 else {
                return
            }
            lastMicrophoneLevelUpdate = now
            microphoneLevel = level
        case .system:
            guard settings.systemAudioEnabled,
                  now - lastSystemAudioLevelUpdate >= 0.05 else {
                return
            }
            lastSystemAudioLevelUpdate = now
            systemAudioLevel = level
        }
    }

    private func shouldRecordAudioSample(from source: AudioSourceKind) -> Bool {
        switch source {
        case .microphone:
            return settings.microphoneEnabled
        case .system:
            return settings.systemAudioEnabled && audioCapture.isSystemAudioActive
        }
    }

    private func handleScreenFrame(_ frame: CapturedVideoFrame) {
        guard state == .recording || isSetupPreviewActive || isSetupPreviewStarting else {
            return
        }

        let pixelBuffer = compositor.compose(screenFrame: frame, settings: settings.overlay) ?? frame.pixelBuffer
        if state == .recording {
            muxer.appendVideoPixelBuffer(pixelBuffer, at: frame.timestamp)
        }
        previewImage = compositor.makePreviewImage(from: pixelBuffer)
    }

    private func isCameraReadyForSetupPreview() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func verifyPermissions(includeCamera: Bool, includeMicrophone: Bool) async throws {
        refreshPermissionStatuses()

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            openPermissionSettings(for: .screenRecording)
            throw RecorderRuntimeError.permissionDenied("Screen recording permission is required. Enable Glimpse in System Settings -> Privacy & Security -> Screen & System Audio Recording, then reopen the app.")
        }

        let isCameraAuthorized = includeCamera ? await requestAccess(for: .video) : true
        if !isCameraAuthorized {
            openPermissionSettings(for: .camera)
            throw RecorderRuntimeError.permissionDenied("Camera access is required to show the webcam overlay. Enable Glimpse in System Settings -> Privacy & Security -> Camera, then reopen the app.")
        }

        let isMicrophoneAuthorized = includeMicrophone ? await requestAccess(for: .audio) : true
        if !isMicrophoneAuthorized {
            openPermissionSettings(for: .microphone)
            throw RecorderRuntimeError.permissionDenied("Microphone access is required when the mic source is enabled. Enable Glimpse in System Settings -> Privacy & Security -> Microphone, or turn Mic off before starting.")
        }

        refreshPermissionStatuses()
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestOrOpenAVPermission(for mediaType: AVMediaType, requirement: PermissionRequirement) async {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return
        case .notDetermined:
            _ = await requestAccess(for: mediaType)
        case .denied:
            openPermissionSettings(for: requirement)
        case .restricted:
            return
        @unknown default:
            return
        }
    }

    private func handleScreenRecordingPermissionAction() async {
        if CGPreflightScreenCaptureAccess() {
            pendingScreenRecordingRelaunch = false
            markScreenRecordingAccessPrompted()
            return
        }

        let currentState = screenRecordingPermissionState()
        if currentState == .restartRequired {
            relaunchForUpdatedPermissions()
            return
        }

        markScreenRecordingAccessPrompted()

        // Register the app with TCC / show the system prompt when available.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        if CGPreflightScreenCaptureAccess() {
            pendingScreenRecordingRelaunch = false
            return
        }

        // Grants made in System Settings do not apply to this process until relaunch.
        openPermissionSettings(for: .screenRecording)
        pendingScreenRecordingRelaunch = true
    }

    private func handleSystemAudioPermissionAction() async {
        guard isSystemAudioAvailable else {
            return
        }

        // System audio shares the Screen & System Audio Recording TCC grant.
        if screenRecordingPermissionState() == .restartRequired {
            relaunchForUpdatedPermissions()
            return
        }

        await handleScreenRecordingPermissionAction()
    }

    private func screenRecordingPermissionState() -> PermissionApprovalState {
        if CGPreflightScreenCaptureAccess() {
            pendingScreenRecordingRelaunch = false
            markScreenRecordingAccessPrompted()
            return .approved
        }

        // After the user is sent to Settings (or request did not grant in-process),
        // keep showing relaunch until the next process sees the TCC grant.
        if pendingScreenRecordingRelaunch {
            return .restartRequired
        }

        if UserDefaults.standard.bool(forKey: screenRecordingAccessPromptedKey) {
            return .needsSettings
        }

        return .notRequested
    }

    private func systemAudioPermissionState(screenState: PermissionApprovalState) -> PermissionApprovalState {
        guard isSystemAudioAvailable else {
            return .unavailable
        }

        switch screenState {
        case .approved:
            return .approved
        case .restartRequired:
            // Same TCC grant as screen recording; same relaunch requirement.
            return .restartRequired
        case .notRequested, .needsSettings, .restricted, .waitingForScreenRecording, .unavailable:
            return .waitingForScreenRecording
        }
    }

    private func markScreenRecordingAccessPrompted() {
        UserDefaults.standard.set(true, forKey: screenRecordingAccessPromptedKey)
    }

    private func permissionState(for authorizationStatus: AVAuthorizationStatus) -> PermissionApprovalState {
        switch authorizationStatus {
        case .authorized:
            return .approved
        case .notDetermined:
            return .notRequested
        case .denied:
            return .needsSettings
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }

    private func openPermissionSettings(for requirement: PermissionRequirement) {
        let urlString: String
        switch requirement {
        case .screenRecording, .systemAudio:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .camera:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }

        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func makeOutputURL() throws -> URL {
        let directory = settings.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return settings.nextOutputURL()
    }

    private func makeRecordingSummary(for url: URL, sources: RecordingSourceSet) -> RecordingSummary {
        let asset = AVURLAsset(url: url)
        let videoTrack = asset.tracks(withMediaType: .video).first
        let transformedSize = videoTrack?.naturalSize.applying(videoTrack?.preferredTransform ?? .identity) ?? .zero
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let duration = CMTimeGetSeconds(asset.duration)

        return RecordingSummary(
            sourceURL: url,
            duration: duration.isFinite ? duration : 0,
            fileSizeBytes: fileSize,
            videoSize: PixelSize(
                width: abs(Double(transformedSize.width)),
                height: abs(Double(transformedSize.height))
            ),
            sourceBitrate: videoTrack.map { Int($0.estimatedDataRate) },
            sources: sources,
            overlaySettings: settings.overlay,
            captureTargetKind: activeCaptureTargetKind
        )
    }

    private func systemAudioUnavailableMessage(includeMicrophone: Bool) -> String {
        includeMicrophone
            ? "System audio unavailable; recording microphone only"
            : "System audio unavailable; recording without audio"
    }

    private func transition(_ mutation: (inout RecordingStateMachine) throws -> Void) throws {
        try mutation(&stateMachine)
        state = stateMachine.state
    }

    private func resetForNewRecording() {
        clearError()
        previewImage = nil
        cameraPreviewImage = nil
        microphoneLevel = 0
        systemAudioLevel = 0
        elapsedSeconds = 0
        lastOutputURL = nil
        recordingPresentationToken = nil
        recordingSummary = nil
        editingSession = nil
        exportedVideos = []
        stopElapsedTimer()
        if state != .idle {
            stateMachine.reset()
            state = stateMachine.state
        }
    }

    private func reconcileSelectedCaptureTarget(with targets: [ScreenCaptureTarget]) {
        guard !targets.isEmpty else {
            selectedCaptureTarget = nil
            return
        }

        if let selectedCaptureTarget,
           let refreshedTarget = targets.first(where: { $0.id == selectedCaptureTarget.id }) {
            self.selectedCaptureTarget = refreshedTarget
        } else {
            selectedCaptureTarget = targets.first
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recordingStartedAt = self.recordingStartedAt else {
                    return
                }
                self.elapsedSeconds = Int(Date().timeIntervalSince(recordingStartedAt))
            }
        }
        elapsedTimer?.tolerance = 0.1
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
    }

    private func stopCaptureComponents() async {
        await screenCapture.stop()
        cameraCapture.stop()
        await audioCapture.stop()
        microphoneLevel = 0
        systemAudioLevel = 0
        cameraPreviewImage = nil
    }

    private func readableError(_ error: Error) -> String {
        if let runtimeError = error as? RecorderRuntimeError {
            return runtimeError.localizedDescription
        }
        if let stateError = error as? RecordingStateMachineError {
            return stateError.description
        }
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("declined TCC")
            || description.localizedCaseInsensitiveContains("TCC")
            || description.localizedCaseInsensitiveContains("ScreenCaptureKit") {
            return """
            macOS denied screen capture for this app build. If Glimpse already appears enabled in Screen & System Audio Recording, remove it or toggle it off and back on, then quit and reopen the app. Local ad-hoc builds can appear approved while no longer matching the stored macOS privacy record.
            """
        }
        return description
    }
}

enum RecorderRuntimeError: LocalizedError {
    case permissionDenied(String)
    case captureUnavailable(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case let .permissionDenied(message),
             let .captureUnavailable(message),
             let .writerFailed(message):
            return message
        }
    }
}

private extension ScreenCaptureTarget {
    var recordingCaptureTargetKind: RecordingCaptureTargetKind {
        switch self {
        case .display:
            return .display
        case .window:
            return .window
        }
    }
}
#endif
