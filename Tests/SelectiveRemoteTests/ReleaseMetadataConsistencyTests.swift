import Foundation
import Testing
@testable import SelectiveRemote

private func releaseAssignment(
    _ key: String,
    in script: String
) -> String? {
    let prefix = key + "=\""
    return script
        .split(separator: "\n")
        .map(String.init)
        .first(where: { $0.hasPrefix(prefix) && $0.hasSuffix("\"") })
        .map { String($0.dropFirst(prefix.count).dropLast()) }
}

@Test("Release metadata stays synchronized")
func releaseMetadataStaysSynchronized() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let buildScript = try String(
        contentsOf: root.appendingPathComponent("scripts/build_app.sh"),
        encoding: .utf8
    )
    let manifestData = try Data(
        contentsOf: root.appendingPathComponent("Resources/updates.json")
    )
    let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]

    let version = try #require(releaseAssignment("VERSION", in: buildScript))
    let build = try #require(releaseAssignment("BUILD_NUMBER", in: buildScript))
    let manifestVersion = try #require(manifest?["version"] as? String)
    let manifestBuild = try #require(manifest?["build"] as? Int)
    let downloadURL = try #require(manifest?["downloadURL"] as? String)
    let releaseNotesURL = try #require(manifest?["releaseNotesURL"] as? String)

    let isMinimalCommunityPreview = FileManager.default.fileExists(
        atPath: root.appendingPathComponent("releases/0.32.0-minimal-community.md").path
    )
    if isMinimalCommunityPreview {
        // The 0.32 preview is not in the public update feed. Requiring a
        // separate marker prevents accidentally promoting a non-notarized DMG.
        #expect(version == "0.32.0")
        #expect(build == "163")
        #expect(manifestVersion == "0.31.0")
        #expect(manifestBuild == 162)
    } else {
        #expect(manifestVersion == version)
        #expect(manifestBuild == Int(build))
    }
    #expect(
        downloadURL
            == "https://github.com/PastFly/Selective-Remote/releases/download/"
                + "v\(manifestVersion)/SelectiveRemote-\(manifestVersion)-arm64.dmg"
    )
    #expect(
        releaseNotesURL
            == "https://github.com/PastFly/Selective-Remote/releases/tag/v\(manifestVersion)"
    )

    let changelog = try String(
        contentsOf: root.appendingPathComponent("CHANGELOG.md"),
        encoding: .utf8
    )
    let changelogEN = try String(
        contentsOf: root.appendingPathComponent("CHANGELOG_EN.md"),
        encoding: .utf8
    )
    #expect(changelog.hasPrefix("## \(version)\n"))
    #expect(changelogEN.hasPrefix("## \(version)\n"))
}
