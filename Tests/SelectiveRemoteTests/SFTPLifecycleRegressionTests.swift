import AppKit
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


@Test("SFTP Workspace keeps ItemProvider callbacks outside MainActor views")
func sftpWorkspaceUsesNonActorItemProviderBridge() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let workspace = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/SelectiveRemote/SFTPWorkspace.swift"
        ),
        encoding: .utf8
    )

    let models = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/SelectiveRemote/SFTPBrowserModels.swift"
        ),
        encoding: .utf8
    )

    // Foundation callbacks must never be created inside SwiftUI Views.
    #expect(!workspace.contains("loadDataRepresentation("))
    #expect(!workspace.contains("loadObject(ofClass: NSURL.self)"))

    #expect(models.contains("enum SFTPItemProviderBridge"))
    #expect(models.contains("SFTPMainActorValueHandler"))
    #expect(models.contains("Task { @MainActor in"))
}

@Test("SFTP ItemProvider bridge survives asynchronous delivery")
@MainActor
func sftpItemProviderBridgeSurvivesAsynchronousDelivery() async {
    let expected = "selective-remote-server-to-server-probe"

    let provider = NSItemProvider(
        item: Data(expected.utf8) as NSData,
        typeIdentifier: NSPasteboard.PasteboardType.string.rawValue
    )

    let received: String = await withCheckedContinuation { continuation in
        let handler = SFTPMainActorValueHandler<String> { value in
            continuation.resume(returning: value)
        }

        SFTPItemProviderBridge.loadString(
            from: provider,
            handler: handler
        )
    }

    #expect(received == expected)
}
