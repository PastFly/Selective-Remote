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

    #expect(manifestVersion == version)
    #expect(manifestBuild == Int(build))
    #expect(
        downloadURL
            == "https://github.com/PastFly/Selective-Remote/releases/download/"
                + "v\(version)/SelectiveRemote-\(version)-arm64.dmg"
    )
    #expect(
        releaseNotesURL
            == "https://github.com/PastFly/Selective-Remote/releases/tag/v\(version)"
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
