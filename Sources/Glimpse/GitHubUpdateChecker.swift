#if os(macOS)
import Foundation

struct UpdateConfiguration: Sendable {
    var owner: String
    var repository: String
    var branch: String

    static let glimpse = UpdateConfiguration(
        owner: "rtemoni",
        repository: "Glimpse",
        branch: "main"
    )

    var manifestURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(branch)/updates/latest.json")!
    }
}

struct UpdateManifest: Decodable, Sendable {
    var version: String
    var build: String?
    var tag: String
    var releaseDate: String?
    var minimumSystemVersion: String?
    var downloadURL: URL
    var releaseNotesURL: URL
    var branch: String?
}

struct UpdateCheckResult: Sendable {
    var manifest: UpdateManifest
    var currentVersion: String

    var isUpdateAvailable: Bool {
        VersionNumber(manifest.version) > VersionNumber(currentVersion)
    }
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The update feed returned an unreadable response."
        case .server(let statusCode):
            return "The update feed returned HTTP \(statusCode)."
        }
    }
}

struct GitHubUpdateChecker: Sendable {
    var configuration: UpdateConfiguration = .glimpse
    var session: URLSession = .shared

    func check(currentVersion: String) async throws -> UpdateCheckResult {
        var request = URLRequest(url: configuration.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("Glimpse", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw UpdateCheckError.server(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let manifest = try decoder.decode(UpdateManifest.self, from: data)
        return UpdateCheckResult(manifest: manifest, currentVersion: currentVersion)
    }
}

private struct VersionNumber: Comparable, Sendable {
    private var components: [Int]

    init(_ value: String) {
        components = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in
                let numericPrefix = component.prefix { $0.isNumber }
                return Int(numericPrefix) ?? 0
            }
    }

    static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}
#endif
