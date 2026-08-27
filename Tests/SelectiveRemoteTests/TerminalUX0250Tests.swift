import Foundation
import Testing
@testable import SelectiveRemote

// Final regression gate for the manually testable v0.25.0 candidate.
struct TerminalUX0250Tests {
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

    @Test("Update check from Settings stays inline and keeps close guard")
    func settingsUpdateCheckDoesNotPublishMainWindowAlert() throws {
        let app = try source("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        let model = try source("Sources/SelectiveRemote/AppModel.swift")
        let view = try source("Sources/SelectiveRemote/UpdateExperienceView.swift")
        let guardSource = try source("Sources/SelectiveRemote/SettingsWindowCloseGuard.swift")

        #expect(app.contains("preventsClosing: model.isUpdateOperationInProgress"))
        #expect(model.contains("func checkForUpdatesFromSettings()"))
        #expect(model.contains("checkForUpdates(announcesUpToDate: false)"))
        #expect(view.contains("model.checkForUpdatesFromSettings()"))
        #expect(guardSource.contains("window.styleMask.remove(.closable)"))
        #expect(guardSource.contains("window.styleMask.insert(.closable)"))
    }

    @Test("Local toolbar uses SSH-sized icon controls")
    func localToolbarUsesTitle3Icons() throws {
        let local = try source("Sources/SelectiveRemote/LocalTerminalView.swift")
        let content = try source("Sources/SelectiveRemote/ContentView.swift")
        #expect(local.contains("Image(systemName: \"clock.arrow.circlepath\")\n                    .font(.title3)"))
        #expect(local.contains("Image(systemName: \"curlybraces\")\n                    .font(.title3)"))
        #expect(local.contains("Image(systemName: \"paintpalette.fill\")\n                    .font(.title3)"))

        let localDetailStart = try #require(content.range(of: "private var localTerminalDetail"))
        let nextDetailStart = try #require(content.range(
            of: "private var globalSFTPDetail",
            range: localDetailStart.upperBound..<content.endIndex
        ))
        let localDetail = content[localDetailStart.lowerBound..<nextDetailStart.lowerBound]
        #expect(localDetail.contains(".controlSize(.large)"))
    }

    @Test("Individual terminal appearance persists every setting independently")
    @MainActor
    func scopedTerminalAppearancePersistsIndependently() {
        let suite = "SelectiveRemote.TerminalUX0250Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let global = TerminalAppearanceStore(defaults: defaults)
        global.applyPreset(.dracula)
        global.font = .menlo
        global.fontSize = 18
        global.lineHeight = 1.30
        global.cursorStyle = .bar
        global.cursorBlink = false
        global.syntaxHighlighting = false
        global.syntaxScope = .currentLine
        global.syntaxFollowTheme = false
        global.syntaxHistoryOpacity = 0.65
        global.syntaxBoldCommands = false
        global.padding = 22

        let pane = TerminalAppearanceStore(
            defaults: defaults,
            storageNamespace: "pane.test",
            cloneGlobalIfMissing: true
        )
        #expect(pane.selectedPreset == .dracula)
        #expect(pane.font == .menlo)
        #expect(pane.fontSize == 18)
        #expect(pane.cursorStyle == .bar)
        #expect(pane.syntaxHighlighting == false)
        #expect(pane.padding == 22)

        pane.applyPreset(.hackerGreen)
        pane.font = .monaco
        pane.fontSize = 20
        pane.syntaxHighlighting = true
        pane.padding = 7

        #expect(global.selectedPreset == .dracula)
        #expect(global.font == .menlo)
        #expect(global.fontSize == 18)
        #expect(global.syntaxHighlighting == false)
        #expect(global.padding == 22)

        let restored = TerminalAppearanceStore(
            defaults: defaults,
            storageNamespace: "pane.test",
            cloneGlobalIfMissing: true
        )
        #expect(restored.selectedPreset == .hackerGreen)
        #expect(restored.font == .monaco)
        #expect(restored.fontSize == 20)
        #expect(restored.syntaxHighlighting == true)
        #expect(restored.padding == 7)
    }

    @Test("Single-monitor fullscreen keeps macOS controls and reserves top safe area")
    func singleMonitorFullscreenUsesSafeProbeWithoutHidingControls() throws {
        let service = try source("Sources/SelectiveRemote/FreeRDPService.swift")
        let interposer = try source("Native/MonitorTopologyInterposer.cpp")

        #expect(service.contains(#"environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "1""#))
        #expect(service.contains("SELECTIVE_RDP_FULLSCREEN_SAFE_SINGLE"))
        #expect(interposer.contains("singleDisplaySafeTopRequested"))
        #expect(interposer.contains("SDL_GetDisplays(&count)"))
        #expect(interposer.contains("SDL_GetDisplayUsableBounds"))
        #expect(interposer.contains("bounds.h -= topInset"))
    }

    @Test("Local and SSH terminals reuse the complete appearance editor")
    func paneAppearanceUsesFullEditor() throws {
        let appearance = try source("Sources/SelectiveRemote/TerminalAppearance.swift")
        let local = try source("Sources/SelectiveRemote/LocalTerminalView.swift")
        let ssh = try source("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
        let workspace = try source("Sources/SelectiveRemote/TerminalWorkspace.swift")

        #expect(appearance.contains("TerminalThemeSelector(store: store)"))
        #expect(appearance.contains("DisclosureGroup(\"Шрифт и курсор\")"))
        #expect(appearance.contains("DisclosureGroup(\"Подсветка синтаксиса\")"))
        #expect(appearance.contains("DisclosureGroup(\"Своя тема\")"))
        #expect(appearance.contains("Скопировать общее оформление"))
        #expect(local.contains("store: selectedTab.appearance"))
        #expect(ssh.contains("store: tab.appearance"))
        #expect(local.contains("let paneAppearance = tab.appearance.snapshot"))
        #expect(ssh.contains("let paneAppearance = tab.appearance.snapshot"))
        #expect(workspace.contains("storageNamespace: \"pane.\\(id.uuidString)\""))
    }
}
