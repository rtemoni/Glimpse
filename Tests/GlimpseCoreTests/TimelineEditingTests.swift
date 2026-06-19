import XCTest
@testable import GlimpseCore

final class TimelineEditingTests: XCTestCase {
    func testDefaultSessionKeepsFullDuration() {
        let session = EditingSession(sourceDuration: 12)

        XCTAssertEqual(session.trimStart, 0)
        XCTAssertEqual(session.trimEnd, 12)
        XCTAssertEqual(session.keptRanges, [TimelineRange(start: 0, end: 12)])
    }

    func testTrimClampsToSourceDuration() {
        var session = EditingSession(sourceDuration: 12)

        session.setTrim(start: -4, end: 20)

        XCTAssertEqual(session.trimStart, 0)
        XCTAssertEqual(session.trimEnd, 12)
    }

    func testCutsAreClampedMergedAndSubtractedFromKeptRanges() {
        var session = EditingSession(sourceDuration: 20)
        session.setTrim(start: 2, end: 18)
        session.addRemovedRange(start: 4, end: 7)
        session.addRemovedRange(start: 6, end: 10)
        session.addRemovedRange(start: 16, end: 25)

        XCTAssertEqual(
            session.removedRanges,
            [
                TimelineRange(start: 4, end: 10),
                TimelineRange(start: 16, end: 18)
            ]
        )
        XCTAssertEqual(
            session.keptRanges,
            [
                TimelineRange(start: 2, end: 4),
                TimelineRange(start: 10, end: 16)
            ]
        )
    }

    func testSplitCreatesSeparateClipRangesWithoutChangingExportDuration() {
        var session = EditingSession(sourceDuration: 12)

        XCTAssertTrue(session.split(at: 4))
        XCTAssertTrue(session.split(at: 9))

        XCTAssertEqual(session.splitPoints, [4, 9])
        XCTAssertEqual(
            session.clipRanges,
            [
                TimelineRange(start: 0, end: 4),
                TimelineRange(start: 4, end: 9),
                TimelineRange(start: 9, end: 12)
            ]
        )
        XCTAssertEqual(session.keptRanges, [TimelineRange(start: 0, end: 12)])
    }

    func testSplitReportsNoChangeAtExistingBoundary() {
        var session = EditingSession(sourceDuration: 12)

        XCTAssertTrue(session.split(at: 4))
        XCTAssertFalse(session.split(at: 4))
        XCTAssertFalse(session.split(at: 0))
        XCTAssertFalse(session.split(at: 12))
        XCTAssertEqual(session.splitPoints, [4])
    }

    func testDeletingSplitClipRemovesThatClipFromExport() {
        var session = EditingSession(sourceDuration: 12)
        session.split(at: 4)
        session.split(at: 9)

        session.deleteClip(TimelineRange(start: 4, end: 9))

        XCTAssertEqual(session.removedRanges, [TimelineRange(start: 4, end: 9)])
        XCTAssertEqual(session.splitPoints, [])
        XCTAssertEqual(
            session.clipRanges,
            [
                TimelineRange(start: 0, end: 4),
                TimelineRange(start: 9, end: 12)
            ]
        )
        XCTAssertEqual(
            session.keptRanges,
            [
                TimelineRange(start: 0, end: 4),
                TimelineRange(start: 9, end: 12)
            ]
        )
        XCTAssertEqual(
            session.audioKeptRanges,
            [
                TimelineRange(start: 0, end: 4),
                TimelineRange(start: 9, end: 12)
            ]
        )
    }

    func testAudioCanBeSplitAndDeletedIndependently() {
        var session = EditingSession(sourceDuration: 12)

        XCTAssertTrue(session.splitAudio(at: 3))
        XCTAssertTrue(session.splitAudio(at: 8))
        session.deleteAudioClip(TimelineRange(start: 3, end: 8))

        XCTAssertEqual(session.keptRanges, [TimelineRange(start: 0, end: 12)])
        XCTAssertEqual(
            session.audioKeptRanges,
            [
                TimelineRange(start: 0, end: 3),
                TimelineRange(start: 8, end: 12)
            ]
        )
        XCTAssertEqual(
            session.audioClipRanges,
            [
                TimelineRange(start: 0, end: 3),
                TimelineRange(start: 8, end: 12)
            ]
        )
    }

    func testVideoSplitAlsoCreatesAudioEditBoundaryWhenAudioExistsAtTime() {
        var session = EditingSession(sourceDuration: 12)

        XCTAssertTrue(session.split(at: 5))

        XCTAssertEqual(session.clipRanges, [TimelineRange(start: 0, end: 5), TimelineRange(start: 5, end: 12)])
        XCTAssertEqual(session.audioClipRanges, [TimelineRange(start: 0, end: 5), TimelineRange(start: 5, end: 12)])
    }

    func testVideoOnlySplitDoesNotCreateAudioEditBoundary() {
        var session = EditingSession(sourceDuration: 12)

        XCTAssertTrue(session.split(at: 5, syncAudio: false))

        XCTAssertEqual(session.clipRanges, [TimelineRange(start: 0, end: 5), TimelineRange(start: 5, end: 12)])
        XCTAssertEqual(session.audioClipRanges, [TimelineRange(start: 0, end: 12)])
    }

    func testTrimChangeDropsCutsOutsideNewTrimRange() {
        var session = EditingSession(sourceDuration: 20)
        session.addRemovedRange(start: 2, end: 4)
        session.addRemovedRange(start: 12, end: 15)

        session.setTrim(start: 10, end: 18)

        XCTAssertEqual(session.removedRanges, [TimelineRange(start: 12, end: 15)])
        XCTAssertEqual(
            session.keptRanges,
            [
                TimelineRange(start: 10, end: 12),
                TimelineRange(start: 15, end: 18)
            ]
        )
    }

    func testExportBitratePresetsResolveToBitsPerSecond() {
        XCTAssertEqual(ExportBitratePreset.low.bitrateBitsPerSecond(sourceBitrate: nil, customMegabits: 20), 5_000_000)
        XCTAssertEqual(ExportBitratePreset.medium.bitrateBitsPerSecond(sourceBitrate: nil, customMegabits: 20), 12_000_000)
        XCTAssertEqual(ExportBitratePreset.high.bitrateBitsPerSecond(sourceBitrate: nil, customMegabits: 20), 30_000_000)
        XCTAssertEqual(ExportBitratePreset.sourceQuality.bitrateBitsPerSecond(sourceBitrate: 44_000_000, customMegabits: 20), 44_000_000)
        XCTAssertEqual(ExportBitratePreset.custom.bitrateBitsPerSecond(sourceBitrate: nil, customMegabits: 18.5), 18_500_000)
    }

    func testFramedCaptureSettingsAreDisabledByDefaultAndCodable() throws {
        var settings = ExportSettings()
        XCTAssertFalse(settings.framedCapture.isEnabled)
        XCTAssertEqual(settings.framedCapture.padding, 30)
        XCTAssertEqual(settings.framedCapture.cornerRadius, 20)
        XCTAssertEqual(settings.normalizedAspectPresets, [.wide16x9])

        settings.framedCapture.isEnabled = true
        settings.framedCapture.background = .solidColor
        settings.framedCapture.padding = 96
        settings.framedCapture.cornerRadius = 28
        settings.framedCapture.shadow = .strong
        settings.framedCapture.alignment = .top
        settings.aspectPresets = [.wide16x9, .feed4x5, .vertical9x16]

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: encoded)

        XCTAssertEqual(decoded, settings)
    }
}
