#if os(macOS)
import AppKit
import Foundation

enum AppResources {
    private static let packageBundleName = "Glimpse_Glimpse.bundle"

    static func image(named name: String, withExtension fileExtension: String) -> NSImage? {
        guard let url = url(forResource: name, withExtension: fileExtension) else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        let fileName = "\(name).\(fileExtension)"

        for directory in resourceDirectories {
            let candidate = directory.appendingPathComponent(fileName, isDirectory: false)
            if FileManager.default.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static var resourceDirectories: [URL] {
        var directories: [URL] = []

        func append(_ url: URL?) {
            guard let url else { return }
            let standardizedURL = url.standardizedFileURL
            guard !directories.contains(standardizedURL) else { return }
            directories.append(standardizedURL)
        }

        append(Bundle.main.resourceURL)
        append(Bundle.main.resourceURL?.appendingPathComponent(packageBundleName, isDirectory: true))
        append(Bundle.main.bundleURL.appendingPathComponent(packageBundleName, isDirectory: true))

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            append(executableDirectory)
            append(executableDirectory.appendingPathComponent(packageBundleName, isDirectory: true))
        }

        return directories
    }
}
#endif
