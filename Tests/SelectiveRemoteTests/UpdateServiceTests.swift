import Foundation
import Testing
@testable import SelectiveRemote

struct UpdateServiceTests {
    private static let feedURL = URL(string: "https://updates.example.test/updates.json")!
    private static let githubURL = URL(
        string: "https://api.github.com/repos/PastFly/Selective-Remote/releases/latest"
    )!
    private static let macOS15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    private struct GitHubRelease: Sendable {
        var tag = "v0.32.1"
        var draft = false
        var prerelease = false
        var asset = "SelectiveRemote-0.32.1-arm64.dmg"
        var state = "uploaded"

        func data() throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "tag_name": tag,
                "draft": draft,
                "prerelease": prerelease,
                "assets": [["name": asset, "state": state]],
                "html_url": "https://example.test/ignore-this-url"
            ])
        }
    }

    private static func response(
        url: URL,
        status: Int = 200,
        data: Data = Data()
    ) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        ))
        return (data, response)
    }

    private static func manifest(version: String, minimum: String = "15.0") -> SelectiveRemoteUpdateManifest {
        SelectiveRemoteUpdateManifest(
            version: version,
            build: 164,
            downloadURL: URL(string: "https://updates.example.test/update.dmg")!,
            releaseNotesURL: nil,
            releaseNotesHistoryURL: nil,
            releaseNotesHistoryENURL: nil,
            minimumMacOS: minimum
        )
    }

    @Test func staleOfficialFeedStillReportsThePublishedGitHubRelease() async throws {
        let result = try await UpdateService.check(
            feedURL: Self.feedURL, allowsInAppInstallation: true, currentVersion: "0.32.0", currentBuild: 163
        ) { request in
            if request.url == Self.feedURL {
                return try Self.response(url: Self.feedURL, data: JSONEncoder().encode(Self.manifest(version: "0.31.0")))
            }
            #expect(request.url == Self.githubURL)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            return try Self.response(url: Self.githubURL, data: GitHubRelease().data())
        }
        #expect(result == .githubRelease(GitHubUpdateRelease(
            version: "0.32.1",
            pageURL: URL(string: "https://github.com/PastFly/Selective-Remote/releases/tag/v0.32.1")!
        )))
    }

    @Test func pinnedPublisherKeepsTheInAppInstallationPath() async throws {
        let manifest = Self.manifest(version: "0.32.1")
        let result = try await UpdateService.check(
            feedURL: Self.feedURL, allowsInAppInstallation: true, currentVersion: "0.32.0", currentBuild: 163,
            currentMacOS: Self.macOS15
        ) { request in
            #expect(request.url == Self.feedURL)
            return try Self.response(url: Self.feedURL, data: JSONEncoder().encode(manifest))
        }
        #expect(result == .available(manifest))
    }

    @Test func communityWithoutPublisherPinOnlyOffersTheReleasePage() async throws {
        let result = try await UpdateService.check(
            feedURL: Self.feedURL, allowsInAppInstallation: false, currentVersion: "0.32.0", currentBuild: 163
        ) { request in
            #expect(request.url == Self.githubURL)
            return try Self.response(url: Self.githubURL, data: GitHubRelease().data())
        }
        guard case let .githubRelease(release) = result else {
            Issue.record("Expected the manual GitHub release")
            return
        }
        #expect(release.version == "0.32.1")
    }

    @Test func releaseWithKnownIncompatibleMinimumRemainsIncompatible() async throws {
        let manifest = Self.manifest(version: "0.32.1", minimum: "26.0")
        let result = try await UpdateService.check(
            feedURL: Self.feedURL, allowsInAppInstallation: true, currentVersion: "0.32.0", currentBuild: 163,
            currentMacOS: Self.macOS15
        ) { request in
            if request.url == Self.feedURL {
                return try Self.response(url: Self.feedURL, data: JSONEncoder().encode(manifest))
            }
            return try Self.response(url: Self.githubURL, data: GitHubRelease().data())
        }
        #expect(result == .incompatible(manifest))
    }

    @Test(arguments: [
        GitHubRelease(draft: true),
        GitHubRelease(prerelease: true),
        GitHubRelease(tag: "v0.32.1-rc.1"),
        GitHubRelease(asset: "SelectiveRemote-0.32.1-arm64.dmg.sha256"),
        GitHubRelease(state: "starter"),
        GitHubRelease(tag: "v0.32.0", asset: "SelectiveRemote-0.32.0-arm64.dmg"),
        GitHubRelease(tag: "v0.31.0", asset: "SelectiveRemote-0.31.0-arm64.dmg")
    ])
    private func ineligibleReleaseDoesNotOfferAnUpdate(_ release: GitHubRelease) async throws {
        let result = try await UpdateService.check(
            feedURL: Self.feedURL, allowsInAppInstallation: false, currentVersion: "0.32.0", currentBuild: 163
        ) { _ in
            try Self.response(url: Self.githubURL, data: release.data())
        }
        #expect(result == .upToDate)
    }

    @Test func networkFailureIsNotReportedAsCurrent() async {
        await #expect(throws: UpdateServiceError.self) {
            try await UpdateService.check(
                feedURL: Self.feedURL, allowsInAppInstallation: false, currentVersion: "0.32.0", currentBuild: 163
            ) { _ in
                try Self.response(url: Self.githubURL, status: 403)
            }
        }
    }
}
