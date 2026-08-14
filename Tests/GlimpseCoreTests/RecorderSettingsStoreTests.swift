import Foundation
import XCTest
@testable import GlimpseCore

final class RecorderSettingsStoreTests: XCTestCase {
    func testSettingsRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RecorderSettingsStore(directoryURL: directory)
        var expected = RecorderSettings()
        expected.fileNamePrefix = "demo"
        expected.fileFormat = .mp4
        expected.selectedCameraID = "camera-1"
        expected.selectedMicrophoneID = "microphone-1"
        expected.microphoneEnabled = false
        expected.systemAudioGain = 0.45
        expected.overlay.position = .topRight
        expected.overlay.shape = .circle
        var exportSettings = ExportSettings()
        exportSettings.format = .mp4
        exportSettings.bitratePreset = .high

        let expectedSnapshot = RecorderSettingsStore.Snapshot(
            recorderSettings: expected,
            exportSettings: exportSettings
        )
        try store.save(expectedSnapshot)

        let reloadedStore = RecorderSettingsStore(directoryURL: directory)
        XCTAssertEqual(reloadedStore.load(), expectedSnapshot)
        XCTAssertEqual(reloadedStore.lastRecoverySource, .primary)
    }

    func testCorruptPrimaryRecoversPreviousValidBackup() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RecorderSettingsStore(directoryURL: directory)
        var first = RecorderSettings()
        first.fileNamePrefix = "known-good"
        try store.save(.init(recorderSettings: first))

        var second = first
        second.fileNamePrefix = "newer"
        try store.save(.init(recorderSettings: second))

        let primaryURL = directory.appendingPathComponent("glimpse-settings.json")
        try Data("not-json".utf8).write(to: primaryURL, options: .atomic)

        let recoveredStore = RecorderSettingsStore(directoryURL: directory)
        XCTAssertEqual(recoveredStore.load().recorderSettings, first)
        XCTAssertEqual(recoveredStore.lastRecoverySource, .backup)

        let repairedStore = RecorderSettingsStore(directoryURL: directory)
        XCTAssertEqual(repairedStore.load().recorderSettings, first)
        XCTAssertEqual(repairedStore.lastRecoverySource, .primary)
    }

    func testPreUpdateSnapshotContainsLatestSettings() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RecorderSettingsStore(directoryURL: directory)
        var settings = RecorderSettings()
        settings.outputDirectory = URL(fileURLWithPath: "/tmp/glimpse-recordings")
        settings.overlay.sizePreset = .large

        try store.createPreUpdateBackup(of: .init(recorderSettings: settings))

        let snapshotURL = directory.appendingPathComponent("glimpse-settings.pre-update.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertFalse(try Data(contentsOf: snapshotURL).isEmpty)

        let primaryURL = directory.appendingPathComponent("glimpse-settings.json")
        try Data("corrupt".utf8).write(to: primaryURL, options: .atomic)

        let recoveredStore = RecorderSettingsStore(directoryURL: directory)
        XCTAssertEqual(recoveredStore.load().recorderSettings, settings)
        XCTAssertEqual(recoveredStore.lastRecoverySource, .preUpdate)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GlimpseSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
