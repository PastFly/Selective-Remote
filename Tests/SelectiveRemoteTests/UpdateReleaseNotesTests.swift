import Foundation
import Testing
@testable import SelectiveRemote

struct UpdateReleaseNotesTests {
    @Test("0.32.0 introduces Cloud to existing 0.31.0 users in both languages")
    func publicCloudIntroductionDoesNotDescribeInternalIterations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (file, required, forbidden) in [
            (
                "CHANGELOG.md",
                ["Selective Remote Cloud", "Personal Vault", "Team Vault", "Mac", "браузер", "Hosts", "Credentials", "Snippets"],
                ["account-scoped", "causal history", "wrappers", "восстановлению доверенных", "стали устойчивее"]
            ),
            (
                "CHANGELOG_EN.md",
                ["Selective Remote Cloud", "Personal Vault", "Team Vault", "Mac", "browser", "Hosts", "Credentials", "Snippets"],
                ["account-scoped", "causal history", "wrappers", "recovery improvements", "more resilient"]
            )
        ] {
            let markdown = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let section = try #require(UpdateReleaseNotesParser.parse(
                markdown, currentVersion: "0.31.0", targetVersion: "0.32.0"
            ).first)
            let copy = section.changes.joined(separator: " ")
            for phrase in required { #expect(copy.localizedCaseInsensitiveContains(phrase), "Missing \(phrase) in \(file)") }
            for phrase in forbidden { #expect(!copy.localizedCaseInsensitiveContains(phrase), "Internal claim \(phrase) in \(file)") }
        }
    }

    @Test("Что нового показывает пропущенные версии от свежей к старой")
    func skippedVersionsAreNewestFirst() throws {
        let markdown = """
        ## 0.21.8

        - Встроено окно истории изменений.
        - Добавлена английская история.

        ## 0.21.7

        - Улучшена диагностика.

        ## 0.21.6

        - Исправлен Retina fullscreen.

        ## 0.21.5

        - Обновлён механизм обновлений.
        """

        let sections = try UpdateReleaseNotesParser.parse(
            markdown,
            currentVersion: "0.21.5",
            targetVersion: "0.21.8"
        )

        #expect(sections.map(\.version) == ["0.21.8", "0.21.7", "0.21.6"])
        #expect(sections[0].changes.count == 2)
        #expect(!sections.contains(where: { $0.version == "0.21.5" }))
    }

    @Test("Что нового не показывает установленную и более старые версии")
    func installedAndOlderVersionsAreExcluded() throws {
        let markdown = """
        ## 0.22.0
        - Новая ветка.

        ## 0.21.9
        - Следующее обновление.

        ## 0.21.8
        - Текущая версия.

        ## 0.21.7
        - Старая версия.
        """

        let sections = try UpdateReleaseNotesParser.parse(
            markdown,
            currentVersion: "0.21.8",
            targetVersion: "0.21.9"
        )

        #expect(sections.map(\.version) == ["0.21.9"])
    }

    @Test("Manifest поддерживает отдельные RU/EN URL истории изменений")
    func manifestDecodesLocalizedHistoryURLs() throws {
        let json = """
        {
          "version": "0.21.8",
          "build": 116,
          "downloadURL": "https://example.invalid/app.dmg",
          "releaseNotesURL": "https://example.invalid/release",
          "releaseNotesHistoryURL": "https://example.invalid/CHANGELOG.md",
          "releaseNotesHistoryENURL": "https://example.invalid/CHANGELOG_EN.md",
          "minimumMacOS": "14.0"
        }
        """

        let manifest = try JSONDecoder().decode(
            SelectiveRemoteUpdateManifest.self,
            from: Data(json.utf8)
        )

        #expect(
            manifest.releaseNotesHistoryURL?.absoluteString
                == "https://example.invalid/CHANGELOG.md"
        )
        #expect(
            manifest.releaseNotesHistoryENURL?.absoluteString
                == "https://example.invalid/CHANGELOG_EN.md"
        )
    }
}
