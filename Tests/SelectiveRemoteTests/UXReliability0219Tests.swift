import Foundation
import Testing
@testable import SelectiveRemote

struct UXReliability0219Tests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("Установленная история показывает текущую и более старые версии")
    func installedReleaseHistoryIsNewestFirst() throws {
        let markdown = """
        ## 0.22.0
        - Будущее.

        ## 0.21.9
        - Текущая версия.

        ## 0.21.8
        - Предыдущая версия.

        ## 0.21.7
        - Более старая версия.
        """

        let sections = try UpdateReleaseNotesParser.parseInstalledHistory(
            markdown,
            currentVersion: "0.21.9",
            limit: 2
        )

        #expect(sections.map(\.version) == ["0.21.9", "0.21.8"])
    }

    @Test("Справка содержит постоянный пункт Что нового")
    func helpMenuContainsPermanentWhatsNew() throws {
        let app = try source("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        #expect(app.contains("Button(\"Что нового…\", systemImage: \"sparkles\")"))
        #expect(app.contains("model.openInstalledReleaseNotes()"))
        #expect(app.contains("model.presentWhatsNewAfterUpgradeIfNeeded()"))
    }

    @Test("Release history попадает внутрь application bundle")
    func changelogsAreBundledForOfflineUse() throws {
        let build = try source("scripts/build_app.sh")
        #expect(build.contains("cp \"$ROOT/CHANGELOG.md\" \"$RES_DIR/CHANGELOG.md\""))
        #expect(build.contains("cp \"$ROOT/CHANGELOG_EN.md\" \"$RES_DIR/CHANGELOG_EN.md\""))
    }

    @Test("Update Experience показывает этапы и последнюю успешную проверку")
    func updateExperienceStagesAndLastCheckExist() throws {
        let model = try source("Sources/SelectiveRemote/AppModel.swift")
        let installer = try source("Sources/SelectiveRemote/UpdateInstaller.swift")
        let view = try source("Sources/SelectiveRemote/UpdateExperienceView.swift")
        #expect(installer.contains("enum UpdateDownloadStage"))
        #expect(model.contains("lastSuccessfulUpdateCheckDate"))
        #expect(model.contains("updateDownloadStage"))
        #expect(view.contains("Готово к установке"))
        #expect(view.contains("Последняя проверка:"))
    }

    @Test("Terminal имеет поиск по output и клавиатурную навигацию")
    func terminalSearchAndNavigationContractsExist() throws {
        let js = try source("Sources/SelectiveRemote/TerminalResources/terminal-host.js")
        let swift = try source("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
        #expect(js.contains("const buffer = terminal.buffer.active"))
        #expect(js.contains("row < buffer.length"))
        #expect(js.contains("buffer.getLine(row)?.translateToString(true)"))
        #expect(js.contains("event.metaKey && event.key.toLocaleLowerCase() === \"f\""))
        #expect(js.contains("terminalNavigation"))
        #expect(swift.contains("navigationMessageName = \"terminalNavigation\""))
        #expect(swift.contains("navigateTabs("))
    }

    @Test("Keychain имеет поиск и сортировку")
    func keychainSearchAndSortContractsExist() throws {
        let source = try source("Sources/SelectiveRemote/CredentialVaultView.swift")
        #expect(source.contains("private enum VaultSortMode"))
        #expect(source.contains("TextField(\"Поиск в Связке ключей\""))
        #expect(source.contains("SelectiveRemote.keychain.sort.v1"))
    }

    @Test("Diagnostics содержит безопасную системную проверку")
    func diagnosticsSystemCheckContractsExist() throws {
        let center = try source("Sources/SelectiveRemote/DiagnosticsCenter.swift")
        let checks = try source("Sources/SelectiveRemote/SystemDiagnosticsCheck.swift")
        #expect(center.contains("case systemCheck"))
        #expect(center.contains("DiagnosticsSystemCheckView(model: model)"))
        #expect(checks.contains("SecItemCopyMatching"))
        #expect(checks.contains("AVCaptureDevice.authorizationStatus"))
        #expect(!checks.contains("connectSSHTerminal("))
        #expect(!checks.contains("connectProfile("))
    }

    @Test("Connection Center сохраняет UX-фильтры и умеет скрывать колонки")
    func connectionCenterUXContractsExist() throws {
        let source = try source("Sources/SelectiveRemote/ConnectionCenter.swift")
        #expect(source.contains("ConnectionCenterStateFilter"))
        #expect(source.contains("SelectiveRemote.connectionCenter.typeFilter.v1"))
        #expect(source.contains("Menu(\"Столбцы\""))
        #expect(source.contains("TableColumnCustomization<ConnectionCenterItem>"))
        #expect(source.contains(".customizationID(\"port\")"))
        #expect(!source.contains(#"\\ConnectionCenterItem."#))
        #expect(source.contains("Копировать user@host"))
        #expect(source.contains("Показать журнал"))
    }
}
