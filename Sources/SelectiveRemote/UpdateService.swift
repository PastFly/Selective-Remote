import Foundation

struct SelectiveRemoteUpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let downloadURL: URL
    let releaseNotesURL: URL?
    let minimumMacOS: String?
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(SelectiveRemoteUpdateManifest)
    case incompatible(SelectiveRemoteUpdateManifest)
}

enum UpdateServiceError: LocalizedError, Sendable {
    case feedNotConfigured
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .feedNotConfigured:
            "Канал обновлений ещё не настроен. При сборке задайте SELECTIVEREMOTE_UPDATE_FEED_URL."
        case .invalidResponse:
            "Сервер обновлений вернул некорректный ответ"
        }
    }
}

enum UpdateService {
    static func check(
        feedURL: URL,
        currentVersion: String,
        currentBuild: Int,
        currentMacOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        session: URLSession = .shared
    ) async throws -> UpdateCheckResult {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { throw UpdateServiceError.invalidResponse }

        let manifest = try JSONDecoder().decode(SelectiveRemoteUpdateManifest.self, from: data)
        if isNewer(
            candidateVersion: manifest.version,
            candidateBuild: manifest.build,
            currentVersion: currentVersion,
            currentBuild: currentBuild
        ) {
            guard isMacOSSupported(
                minimumVersion: manifest.minimumMacOS,
                currentVersion: currentMacOS
            ) else {
                return .incompatible(manifest)
            }
            return .available(manifest)
        }
        return .upToDate
    }

    static func configuredFeedURL(bundle: Bundle = .main) throws -> URL {
        guard let raw = bundle.object(forInfoDictionaryKey: "SelectiveRemoteUpdateFeedURL") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https"
        else { throw UpdateServiceError.feedNotConfigured }
        return url
    }

    static func isNewer(
        candidateVersion: String,
        candidateBuild: Int,
        currentVersion: String,
        currentBuild: Int
    ) -> Bool {
        let comparison = compareVersions(candidateVersion, currentVersion)
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return candidateBuild > currentBuild
    }

    static func isMacOSSupported(
        minimumVersion: String?,
        currentVersion: OperatingSystemVersion
    ) -> Bool {
        guard let minimumVersion,
              !minimumVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return true }

        let current = [
            currentVersion.majorVersion,
            currentVersion.minorVersion,
            currentVersion.patchVersion
        ].map(String.init).joined(separator: ".")
        return compareVersions(current, minimumVersion) != .orderedAscending
    }

    private static func compareVersions(_ lhsVersion: String, _ rhsVersion: String) -> ComparisonResult {
        let lhsComponents = numericComponents(lhsVersion)
        let rhsComponents = numericComponents(rhsVersion)
        let count = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<count {
            let lhs = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhs = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}
