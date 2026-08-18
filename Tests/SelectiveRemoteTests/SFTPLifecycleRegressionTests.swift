import Foundation
import Testing
@testable import SelectiveRemote

@Test("SFTP cancel has deterministic SIGKILL escalation")
func sftpCancelEscalatesToSIGKILL() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/SFTPTransferQueue.swift"),
        encoding: .utf8
    )
    #expect(source.contains("asyncAfter"))
    #expect(source.contains("forceKillIfNeeded"))
    #expect(source.contains("Darwin.kill(pid, SIGKILL)"))
}

@Test("Profile cleanup includes proxy credential")
func profileCleanupIncludesProxyCredential() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/KeychainService.swift"),
        encoding: .utf8
    )
    #expect(source.contains("try deletePassword(profileID: profileID, kind: .proxy)"))
}

@Test("SFTP disconnect cancels transfers and releases its master lease")
func sftpDisconnectOwnsLifecycleBoundary() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/SFTPBrowserModels.swift"),
        encoding: .utf8
    )
    #expect(source.contains("transfers.cancelAll()"))
    #expect(source.contains("SFTPService.releaseMasterConnection"))
}

@Test("Connection Center reads AppModel-owned SFTP Workspace panes")
func connectionCenterUsesWorkspaceRuntime() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appModel = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    let content = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    #expect(appModel.contains("let sftpWorkspace = SFTPWorkspaceModel()"))
    #expect(appModel.contains("appendConnectionCenterSFTP(pane: tab.left"))
    #expect(appModel.contains("appendConnectionCenterSFTP(pane: tab.right"))
    #expect(content.contains("SFTPWorkspaceView(workspace: model.sftpWorkspace)"))
}

@Test("Connection Center reconnects a managed SFTP Workspace pane")
func connectionCenterReconnectsManagedSFTPPane() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    #expect(source.contains("case let .sftp(scope):"))
    #expect(source.contains("pane.session.connect(settings)"))
}
