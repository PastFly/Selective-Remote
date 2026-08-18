import Foundation
import Testing
@testable import SelectiveRemote

@Test("Connection Center различает runtime-источники с одинаковыми UUID")
func connectionCenterSourceIDsStayNamespaced() {
    let profileID = UUID()
    let runtimeID = UUID()

    let terminal = ConnectionCenterSource.terminal(
        scope: .profile(profileID),
        tabID: runtimeID
    )
    let profileTunnel = ConnectionCenterSource.profileTunnel(
        profileID: profileID,
        ruleID: runtimeID
    )
    let independentTunnel = ConnectionCenterSource.independentTunnel(
        tunnelID: runtimeID
    )

    #expect(terminal.stableID != profileTunnel.stableID)
    #expect(profileTunnel.stableID != independentTunnel.stableID)
    #expect(terminal.stableID.contains(profileID.uuidString))
}

@Test("Connection Center считает uptime от фактического времени запуска")
func connectionCenterUptimeUsesRuntimeStartDate() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let item = ConnectionCenterItem(
        source: .rdp(profileID: UUID()),
        kind: .rdp,
        profileName: "office-rdp",
        userHost: "administrator@10.0.0.10",
        port: 3389,
        route: nil,
        authentication: "Password",
        state: .connected,
        startedAt: startedAt,
        errorMessage: nil,
        detailSections: []
    )

    #expect(item.uptimeText(now: startedAt.addingTimeInterval(45)) == "45s")
    #expect(item.uptimeText(now: startedAt.addingTimeInterval(3_660)) == "1h 1m")
}

@Test("Диагностика Connection Center содержит runtime-метаданные без секретных полей")
func connectionCenterDiagnosticUsesSafeMetadata() {
    let item = ConnectionCenterItem(
        source: .terminal(scope: .global, tabID: UUID()),
        kind: .terminal,
        profileName: "prod",
        userHost: "root@example.internal",
        port: 22,
        route: "bastion.internal",
        authentication: "Touch ID Key",
        state: .connected,
        startedAt: nil,
        errorMessage: nil,
        detailSections: [
            ConnectionCenterDetailSection(
                title: "Аутентификация",
                rows: [ConnectionCenterDetailRow(label: "SSH ID", value: "work-key")]
            )
        ]
    )

    let diagnostic = item.diagnosticText
    #expect(diagnostic.contains("root@example.internal"))
    #expect(diagnostic.contains("Touch ID Key"))
    #expect(diagnostic.contains("bastion.internal"))
    #expect(!diagnostic.localizedCaseInsensitiveContains("passphrase:"))
    #expect(!diagnostic.localizedCaseInsensitiveContains("password:"))
}

@Test("Connection Center агрегирует существующие runtime-хранилища вместо второго session manager")
func connectionCenterUsesExistingRuntimeSources() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appModelURL = projectRoot.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift")
    let contentURL = projectRoot.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift")
    let appModel = try String(contentsOf: appModelURL, encoding: .utf8)
    let content = try String(contentsOf: contentURL, encoding: .utf8)

    #expect(appModel.contains("for session in runningSessions"))
    #expect(appModel.contains("for (workspaceID, workspace) in terminalWorkspaces"))
    #expect(appModel.contains("for tab in sftpWorkspace.tabs"))
    #expect(appModel.contains("appendConnectionCenterSFTP(pane: tab.left"))
    #expect(appModel.contains("for tunnel in sshTunnels.values"))
    #expect(appModel.contains("processIdentifier: connection.process.processIdentifier"))
    #expect(!appModel.contains("ConnectionCenterSessionManager"))
    #expect(content.contains("case connectionCenter = \"Connection Center\""))
    #expect(content.contains("ConnectionCenterView("))
}
