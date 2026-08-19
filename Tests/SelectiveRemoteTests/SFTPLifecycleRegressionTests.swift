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
    #expect(source.contains("case let .sftp(.pane(paneID)):"))
    #expect(source.contains("pane.session.connect(settings)"))
}


@Test("Legacy single-session SFTP runtime stays removed")
func legacySingleSessionSFTPRuntimeStaysRemoved() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appModel = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"), encoding: .utf8)
    let content = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"), encoding: .utf8)
    let app = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/SelectiveRemoteApp.swift"), encoding: .utf8)
    let center = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ConnectionCenter.swift"), encoding: .utf8)
    #expect(!appModel.contains("let sftpSession = SFTPBrowserSession()"))
    #expect(!appModel.contains("globalSFTPSession"))
    #expect(!appModel.contains("sftpObservers"))
    #expect(!content.contains("showsGlobalSFTPConnectionEditor"))
    #expect(!content.contains("connectGlobalSFTP"))
    #expect(!center.contains("sftp:profile:"))
    #expect(!center.contains("sftp:global"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/SelectiveRemote/SFTPBrowserView.swift").path))
    #expect(app.contains("SFTPMenuBarTransferControls(workspace: model.sftpWorkspace)"))
}


@Test("SFTP ItemProvider callbacks do not inherit MainActor")
func sftpItemProviderCallbacksDoNotInheritMainActor() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/SelectiveRemote/SFTPWorkspace.swift"
        ),
        encoding: .utf8
    )

    // NSItemProvider completion handlers may execute on Foundation's
    // callback queue. They must remain Sendable/nonisolated and perform
    // the actual SFTP/UI work only after an explicit MainActor hop.
    #expect(
        source.components(
            separatedBy: "{ @Sendable data, _ in"
        ).count >= 4
    )
    #expect(
        source.components(
            separatedBy: "{ @Sendable object, _ in"
        ).count >= 3
    )

    #expect(!source.contains(") { data, _ in"))
    #expect(!source.contains("NSURL.self) { object, _ in"))

    #expect(source.contains("Task { @MainActor in"))
}
