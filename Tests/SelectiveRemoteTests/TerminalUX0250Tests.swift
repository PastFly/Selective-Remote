import Foundation
import Testing
@testable import SelectiveRemote

// Final regression contracts for the v0.25.0 terminal UX candidate.
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

    @Test("Update check guards the Settings window from closing")
    func updateCheckCloseGuardExists() throws {
        let app = try source("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        let guardSource = try source("Sources/SelectiveRemote/SettingsWindowCloseGuard.swift")
        #expect(app.contains("preventsClosing: model.isCheckingForUpdates"))
        #expect(guardSource.contains("window.styleMask.remove(.closable)"))
        #expect(guardSource.contains("window.styleMask.insert(.closable)"))
    }

    @Test("Local toolbar uses SSH-sized icon controls")
    func localToolbarUsesTitle3Icons() throws {
        let local = try source("Sources/SelectiveRemote/LocalTerminalView.swift")
        #expect(local.contains("Image(systemName: \"clock.arrow.circlepath\")\n                    .font(.title3)"))
        #expect(local.contains("Image(systemName: \"text.badge.plus\")\n                    .font(.title3)"))
        #expect(local.contains("Image(systemName: \"paintpalette.fill\")\n                    .font(.title3)"))
    }

    @Test("Every terminal pane can override the global palette")
    func paneThemeOverrideIsAppliedToLocalAndSSH() throws {
        let theme = try source("Sources/SelectiveRemote/TerminalPaneTheme.swift")
        let local = try source("Sources/SelectiveRemote/LocalTerminalView.swift")
        let ssh = try source("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
        #expect(theme.contains("applyingPaneTheme(colorIndex:"))
        #expect(theme.contains("TerminalPaneThemeChoice"))
        #expect(local.contains("appearance: paneAppearance"))
        #expect(ssh.contains("appearance: paneAppearance"))
        #expect(local.contains("TerminalPaneThemePicker"))
        #expect(ssh.contains("TerminalPaneThemePicker"))
    }
}
