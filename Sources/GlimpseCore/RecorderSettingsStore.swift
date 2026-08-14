import Foundation

/// Persists user configuration outside of the replaceable application bundle.
///
/// Every write is validated and atomic. The previous valid document is retained
/// as a fallback, and an explicit pre-update snapshot can be created before
/// Sparkle hands control to its installer.
public final class RecorderSettingsStore {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var recorderSettings: RecorderSettings
        public var exportSettings: ExportSettings

        public init(
            recorderSettings: RecorderSettings = RecorderSettings(),
            exportSettings: ExportSettings = ExportSettings()
        ) {
            self.recorderSettings = recorderSettings
            self.exportSettings = exportSettings
        }
    }

    public enum RecoverySource: Equatable, Sendable {
        case defaults
        case primary
        case backup
        case preUpdate
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let snapshot: Snapshot
    }

    public let directoryURL: URL
    public private(set) var lastRecoverySource: RecoverySource = .defaults

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var primaryURL: URL {
        directoryURL.appendingPathComponent("glimpse-settings.json")
    }

    private var backupURL: URL {
        directoryURL.appendingPathComponent("glimpse-settings.backup.json")
    }

    private var preUpdateURL: URL {
        directoryURL.appendingPathComponent("glimpse-settings.pre-update.json")
    }

    public convenience init() {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(
            directoryURL: baseURL
                .appendingPathComponent("com.rtemoni.Glimpse", isDirectory: true)
                .appendingPathComponent("Configuration", isDirectory: true)
        )
    }

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load(defaults: Snapshot = Snapshot()) -> Snapshot {
        if let settings = decodeSnapshot(at: primaryURL) {
            lastRecoverySource = .primary
            return settings
        }

        if let settings = decodeSnapshot(at: backupURL) {
            lastRecoverySource = .backup
            try? write(settings, rotatingBackup: false)
            return settings
        }

        if let settings = decodeSnapshot(at: preUpdateURL) {
            lastRecoverySource = .preUpdate
            try? write(settings, rotatingBackup: false)
            return settings
        }

        lastRecoverySource = .defaults
        return defaults
    }

    public func save(_ snapshot: Snapshot) throws {
        try write(snapshot, rotatingBackup: true)
    }

    /// Saves the latest in-memory settings and keeps a stable snapshot that an
    /// updated build can recover from if its primary document is ever damaged.
    public func createPreUpdateBackup(of snapshot: Snapshot) throws {
        try write(snapshot, rotatingBackup: true)
        let data = try Data(contentsOf: primaryURL)
        _ = try decoder.decode(Document.self, from: data)
        try data.write(to: preUpdateURL, options: .atomic)
    }

    private func write(_ snapshot: Snapshot, rotatingBackup: Bool) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let document = Document(
            schemaVersion: 1,
            savedAt: Date(),
            snapshot: snapshot
        )
        let data = try encoder.encode(document)
        _ = try decoder.decode(Document.self, from: data)

        if rotatingBackup,
           fileManager.fileExists(atPath: primaryURL.path),
           decodeSnapshot(at: primaryURL) != nil {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: primaryURL, to: backupURL)
        }

        try data.write(to: primaryURL, options: .atomic)
    }

    private func decodeSnapshot(at url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              let document = try? decoder.decode(Document.self, from: data),
              document.schemaVersion == 1 else {
            return nil
        }
        return document.snapshot
    }
}
