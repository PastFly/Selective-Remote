import Foundation

struct SelectiveRemoteUpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let downloadURL: URL
    let releaseNotesURL: URL?
    let releaseNotesHistoryURL: URL?
    let releaseNotesHistoryENURL: URL?
    let minimumMacOS: String?
}

struct GitHubUpdateRelease: Equatable, Sendable {
    struct Download: Equatable, Sendable {
        let url: URL
        let sha256: String
    }

    let version: String
    let pageURL: URL
    let download: Download?
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(SelectiveRemoteUpdateManifest)
    case incompatible(SelectiveRemoteUpdateManifest)
    case githubRelease(GitHubUpdateRelease)
}

enum UpdateServiceError: LocalizedError, Sendable {
    case feedNotConfigured
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .feedNotConfigured:
            UpdateLocalization.text(
                ru: "Канал обновлений ещё не настроен. При сборке задайте SELECTIVEREMOTE_UPDATE_FEED_URL.",
                en: "The update channel is not configured yet. Set SELECTIVEREMOTE_UPDATE_FEED_URL when building the app."
            )
        case .invalidResponse:
            UpdateLocalization.text(
                ru: "Сервер обновлений вернул некорректный ответ",
                en: "The update server returned an invalid response."
            )
        }
    }
}

enum UpdateService {
    typealias LoadResponse = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let githubRepository = "PastFly/Selective-Remote"
    private static let githubLatestReleaseURL = URL(
        string: "https://api.github.com/repos/\(githubRepository)/releases/latest"
    )!

    private struct GitHubReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let digest: String?
        }

        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }
    }

    static func check(
        feedURL: URL?,
        allowsInAppInstallation: Bool,
        currentVersion: String,
        currentBuild: Int,
        currentMacOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        load: LoadResponse = { try await URLSession.shared.data(for: $0) }
    ) async throws -> UpdateCheckResult {
        var officialResult: Result<UpdateCheckResult, Error> = .success(.upToDate)
        if allowsInAppInstallation {
            do {
                guard let feedURL else { throw UpdateServiceError.feedNotConfigured }
                let result = try await checkOfficialFeed(
                    feedURL: feedURL,
                    currentVersion: currentVersion,
                    currentBuild: currentBuild,
                    currentMacOS: currentMacOS,
                    load: load
                )
                if case .available = result { return result }
                officialResult = .success(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                officialResult = .failure(error)
            }
        }

        let githubRelease: GitHubUpdateRelease?
        do {
            githubRelease = try await latestGitHubRelease(after: currentVersion, load: load)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard allowsInAppInstallation, case let .success(result) = officialResult else { throw error }
            return result
        }
        if let release = githubRelease {
            if case let .success(.incompatible(manifest)) = officialResult,
               compareVersions(release.version, manifest.version) != .orderedDescending {
                return .incompatible(manifest)
            }
            return .githubRelease(release)
        }
        return try officialResult.get()
    }

    private static func checkOfficialFeed(
        feedURL: URL,
        currentVersion: String,
        currentBuild: Int,
        currentMacOS: OperatingSystemVersion,
        load: LoadResponse
    ) async throws -> UpdateCheckResult {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await load(request)
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

    private static func latestGitHubRelease(
        after currentVersion: String,
        load: LoadResponse
    ) async throws -> GitHubUpdateRelease? {
        var request = URLRequest(url: githubLatestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateServiceError.invalidResponse
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateServiceError.invalidResponse
        }

        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let tag = release.tagName
        guard !release.draft, !release.prerelease,
              tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
        else { return nil }
        let version = String(tag.dropFirst())
        let assetName = "SelectiveRemote-\(version)-arm64.dmg"
        guard version.split(separator: ".").allSatisfy({ Int($0) != nil }),
              compareVersions(version, currentVersion) == .orderedDescending,
              let asset = release.assets.first(where: { $0.name == assetName && $0.state == "uploaded" }),
              let pageURL = URL(string: "https://github.com/\(githubRepository)/releases/tag/\(tag)")
        else { return nil }

        let download: GitHubUpdateRelease.Download?
        if let digest = asset.digest,
           digest.range(of: #"^sha256:[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
           digest.utf8.count == 71,
           let url = URL(string: "https://github.com/\(githubRepository)/releases/download/\(tag)/\(assetName)") {
            download = .init(url: url, sha256: String(digest.dropFirst(7)).lowercased())
        } else {
            download = nil
        }
        // Only the configured publisher feed can produce an installable manifest.
        return GitHubUpdateRelease(version: version, pageURL: pageURL, download: download)
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
