import Foundation
import Testing
@testable import SelectiveRemote

struct UXReliability02110Tests {
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

    @Test("RDP privacy evidence reads granted camera and microphone states")
    func rdpPrivacyEvidenceReadsGrantedStates() {
        let evidence = RDPCapturePermissionEvidence.parse(logs: [
            """
            [SelectiveRemote Privacy] requesting camera
            [SelectiveRemote Privacy] granted camera
            [SelectiveRemote Privacy] authorized microphone
            [SelectiveRemote Privacy] ready capture
            """
        ])

        #expect(evidence.camera == .granted)
        #expect(evidence.microphone == .granted)
    }

    @Test("Newest RDP privacy log wins over older permission evidence")
    func newestRDPPrivacyLogWins() {
        let evidence = RDPCapturePermissionEvidence.parse(logs: [
            "[SelectiveRemote Privacy] denied camera",
            "[SelectiveRemote Privacy] granted camera"
        ])

        #expect(evidence.camera == .denied)
    }

    @Test("Within one RDP privacy log the latest permission marker wins")
    func latestMarkerWithinLogWins() {
        let evidence = RDPCapturePermissionEvidence.parse(logs: [
            """
            [SelectiveRemote Privacy] requesting microphone
            [SelectiveRemote Privacy] denied microphone
            [SelectiveRemote Privacy] disabled microphone
            """
        ])

        #expect(evidence.microphone == .denied)
    }

    @Test("System Check never requests capture permissions or starts connections")
    func systemCheckRemainsPreflightOnly() throws {
        let checks = try source("Sources/SelectiveRemote/SystemDiagnosticsCheck.swift")
        #expect(checks.contains("RDP Session использует отдельный контекст разрешений"))
        #expect(checks.contains("RDPCapturePermissionEvidence"))
        #expect(!checks.contains("AVCaptureDevice.requestAccess"))
        #expect(!checks.contains("connectSSHTerminal("))
        #expect(!checks.contains("connectProfile("))
    }

    @Test("Post-update health check is quiet and local-runtime safe")
    func postUpgradeHealthCheckContractsExist() throws {
        let model = try source("Sources/SelectiveRemote/AppModel.swift")
        let checks = try source("Sources/SelectiveRemote/SystemDiagnosticsCheck.swift")
        let content = try source("Sources/SelectiveRemote/ContentView.swift")

        #expect(model.contains("lastPostUpgradeHealthCheckVersionKey"))
        #expect(model.contains("runPostUpgradeHealthCheckIfNeeded"))
        #expect(model.contains("SelectiveRemote/Logs"))
        #expect(checks.contains("runPostUpgradeCriticalChecks"))
        #expect(content.contains("postUpgradeHealthWarning"))
        #expect(content.contains("Открыть диагностику"))
    }

    @Test("Deprecated activation flag is absent")
    func deprecatedActivationFlagIsRemoved() throws {
        let model = try source("Sources/SelectiveRemote/AppModel.swift")
        #expect(!model.contains("activate(options: [.activateIgnoringOtherApps])"))
        #expect(model.contains("_ = application.activate()"))
    }

    @Test("Diagnostics readiness and problems-only UX exist")
    func diagnosticsReadinessUXExists() throws {
        let checks = try source("Sources/SelectiveRemote/SystemDiagnosticsCheck.swift")
        let center = try source("Sources/SelectiveRemote/DiagnosticsCenter.swift")

        #expect(checks.contains("Selective Remote готов к работе"))
        #expect(checks.contains("Только проблемы"))
        #expect(checks.contains("Канал обновлений"))
        #expect(checks.contains("История изменений — RU"))
        #expect(center.contains("DiagnosticsSystemCheckView(model: model)"))
        #expect(center.contains("model.openInstalledReleaseNotes()"))
    }

    @Test("Connection Center can reset all persisted view state")
    func connectionCenterResetExists() throws {
        let center = try source("Sources/SelectiveRemote/ConnectionCenter.swift")
        #expect(center.contains("hasNonDefaultViewState"))
        #expect(center.contains("private func resetView()"))
        #expect(center.contains("columnCustomization = TableColumnCustomization<ConnectionCenterItem>()"))
        #expect(center.contains("ConnectionCenterPreferences.persistSortOrder([], defaults: defaults)"))
    }

    @Test("What's New shows build number without changing release parsing")
    func whatsNewShowsBuildNumber() throws {
        let notes = try source("Sources/SelectiveRemote/UpdateReleaseNotes.swift")
        #expect(notes.contains("versionWithCurrentBuild"))
        #expect(notes.contains("CFBundleVersion"))
        #expect(notes.contains("versionWithBuild("))
        #expect(notes.contains("static func parseInstalledHistory("))
    }

    @Test("Sidebar update and runtime status cannot squeeze the application name")
    func sidebarUpdateStatusUsesASeparateNonWrappingRow() throws {
        let content = try source("Sources/SelectiveRemote/ContentView.swift")

        #expect(content.contains("Text(AppBrand.name)"))
        #expect(content.contains("ru: \"Обновление \\(manifest.version)\""))
        #expect(content.contains("en: \"Update \\(manifest.version)\""))
        #expect(content.contains(".minimumScaleFactor(0.85)"))
        #expect(content.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(content.contains("if model.availableUpdateManifest != nil ||\n"
            + "                    model.runningSessionCount > 0 ||\n"
            + "                    model.runningSSHTunnelCount > 0"))
    }
}
