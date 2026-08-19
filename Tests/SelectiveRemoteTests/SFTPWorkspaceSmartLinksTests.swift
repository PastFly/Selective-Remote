import Foundation
import Testing
@testable import SelectiveRemote

@Test("SFTP Workspace поддерживает независимые панели и несколько вкладок")
@MainActor
func sftpWorkspaceSupportsIndependentPanes() {
    let workspace = SFTPWorkspaceModel()
    #expect(workspace.tabs.count == 1)
    #expect(workspace.selectedTab.left.kind == .local)
    #expect(workspace.selectedTab.right.kind == .empty)

    let leftConnection = TerminalTabConnection.custom(
        host: "server-a.example",
        username: "root"
    )
    let rightConnection = TerminalTabConnection.custom(
        host: "server-b.example",
        username: "root"
    )
    workspace.selectedTab.left.beginRemote(
        connection: leftConnection,
        title: "Server A"
    )
    workspace.selectedTab.right.beginRemote(
        connection: rightConnection,
        title: "Server B"
    )

    #expect(workspace.selectedTab.left.connection == leftConnection)
    #expect(workspace.selectedTab.right.connection == rightConnection)
    #expect(workspace.addTab() != nil)
    #expect(workspace.tabs.count == 2)
}

@Test("Server-to-server SFTP использует локальную временную staging-копию")
func sftpServerToServerCopyIsStagedSafely() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPBrowserModels.swift"),
        encoding: .utf8
    )
    let queue = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPTransferQueue.swift"),
        encoding: .utf8
    )

    #expect(source.contains("func copyRemote("))
    #expect(source.contains("SelectiveRemote-SFTP-Bridge-"))
    #expect(source.contains("SFTPService.download("))
    #expect(source.contains("SFTPService.upload("))
    #expect(source.contains("defer {"))
    #expect(queue.contains("case serverToServer"))
}

@Test("Terminal Smart Links используют публичный xterm LinkProvider и Swift bridge")
func terminalSmartLinksUseXtermProvider() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resources = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalResources")
    let script = try String(
        contentsOf: resources.appendingPathComponent("terminal-host.js"),
        encoding: .utf8
    )
    let bridge = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift"),
        encoding: .utf8
    )

    #expect(script.contains("registerLinkProvider"))
    #expect(script.contains("terminalSmartLink"))
    #expect(script.contains(#"appendMatches("url", /https?:"#))
    #expect(script.contains("appendMatches(\n            \"path\","))
    #expect(script.contains("appendMatches(\n            \"host\","))
    #expect(script.contains("allowProposedApi: false"))
    #expect(bridge.contains("TerminalSmartLinkKind"))
    #expect(bridge.contains("smartLinkMessageName"))
    #expect(bridge.contains("onSmartLink"))
}

@Test("SSH Agent Forwarding выключен по умолчанию и добавляет -A только в интерактивный SSH")
func sshAgentForwardingIsOptIn() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example"
    profile.username = "root"

    let defaultSettings = try SSHConnectionSettings(
        profile: profile,
        identity: nil
    )
    #expect(defaultSettings.agentForwarding == false)
    #expect(!SSHService.interactiveSSHArguments(settings: defaultSettings).contains("-A"))

    profile.sshAgentForwarding = true
    let forwardedSettings = try SSHConnectionSettings(
        profile: profile,
        identity: nil
    )
    #expect(forwardedSettings.agentForwarding)
    #expect(SSHService.interactiveSSHArguments(settings: forwardedSettings).contains("-A"))

    let common = SSHService.commonSSHArguments(
        settings: forwardedSettings,
        batchMode: false
    )
    #expect(!common.contains("-A"))
}
@Test("SFTP Workspace восстанавливает selection, drag/drop и старые контекстные действия")
func sftpWorkspaceRestoresMatureBrowserUX() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPWorkspace.swift"),
        encoding: .utf8
    )

    #expect(source.contains("sftpWorkspaceRowSelection("))
    #expect(source.contains(".listRowBackground("))
    #expect(source.contains(".onDrag {"))
    #expect(source.contains("SFTPDragType.remoteEntry.identifier"))
    #expect(source.contains("Свойства и доступ…"))
    #expect(source.contains("Открыть временную копию с помощью…"))
    #expect(!source.contains(".help(\"Новая SFTP-вкладка\")"))
}

@Test("Server-to-server очередь показывает двухэтапный прогресс и ETA")
func sftpServerBridgeReportsTwoStageProgress() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let browser = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPBrowserModels.swift"),
        encoding: .utf8
    )
    let queue = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPTransferQueue.swift"),
        encoding: .utf8
    )

    #expect(browser.contains("SFTPServerBridgeProgressState"))
    #expect(browser.contains("snapshot.downloadedBytes + uploaded"))
    #expect(browser.contains("sourceTotalBytes.flatMap"))
    #expect(queue.contains("var etaText: String?"))
    #expect(queue.contains("передано"))
}
@Test("SFTP Workspace typed drag path has no legacy registry dependency")
func sftpWorkspaceTypedDragHasNoLegacyRegistryDependency() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPWorkspace.swift"),
        encoding: .utf8
    )

    #expect(!source.contains("SFTPWorkspaceDragRegistry"))
    #expect(!source.contains("acceptRemoteDropsInternal("))
    #expect(source.contains("sftpWorkspaceInternalDragToken("))
    #expect(source.contains(".dropDestination(for: String.self)"))
}

@Test("SFTP Workspace starts remote drag through an AppKit dragging session")
func sftpWorkspaceUsesAppKitDraggingSession() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPWorkspace.swift"),
        encoding: .utf8
    )

    #expect(source.contains("SFTPWorkspaceAppKitDragMonitor("))
    #expect(source.contains("beginDraggingSession("))
    #expect(source.contains("NSEvent.addLocalMonitorForEvents("))
    #expect(!source.contains(".draggable("))
    #expect(source.contains(".dropDestination(for: String.self)"))
}

@Test("SFTP AppKit drag monitor does not send NSEvent across actor isolation")
func sftpWorkspaceAppKitDragAvoidsNSEventSendableCrossing() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPWorkspace.swift"),
        encoding: .utf8
    )

    #expect(source.contains("Unmanaged.passUnretained(event).toOpaque()"))
    #expect(source.contains("let shouldConsume = MainActor.assumeIsolated"))
    #expect(source.contains("return shouldConsume ? nil : event"))
    #expect(!source.contains("self.handleMouseEvent(event)"))
}

@Test("Profile SFTP uses the shared multi-server Workspace")
func profileSFTPUsesSharedMultiServerWorkspace() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(source.contains(
        "case .sftp:\n            SFTPWorkspaceView(workspace: model.sftpWorkspace)"
    ))
    #expect(source.contains("if model.sftpWorkspace.pendingOpenRequest == nil"))
    #expect(source.contains("connection: .savedProfile(profile.id)"))
    #expect(source.contains("selectedProfileSFTPWorkspaceConnected"))
    #expect(!source.contains("SFTPBrowserView(profile: profile, session: sftpSession)"))
    #expect(!source.contains("private var sftpSession: SFTPBrowserSession"))
}

@Test("Profile Terminal opens Smart Link paths inside profile SFTP Workspace")
func profileTerminalSmartLinkUsesProfileSFTPWorkspace() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(source.contains("openSFTPPath: { tab, path in"))
    #expect(source.contains("model.sftpWorkspace.requestOpen("))
    #expect(source.contains("connection: tab.connection"))
    #expect(source.contains("path: path"))
    #expect(source.contains("selectedTab = .sftp"))
}


@Test("SFTP focus mode keeps its exit control outside the workspace toolbar")
func sftpFocusExitDoesNotOverlayWorkspaceToolbar() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(source.contains("else if selectedTab != .terminal {\n                focusExitBar"))
    #expect(source.contains("private var focusExitBar: some View"))
    #expect(!source.contains(".overlay(alignment: .topTrailing) {\n            if terminalFocusMode && selectedTab != .terminal"))
}

@Test("SFTP remote drag does not mutate selection on mouse down")
func sftpRemoteDragDoesNotInvalidateItsMonitorOnMouseDown() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/SFTPWorkspace.swift"),
        encoding: .utf8
    )

    #expect(source.contains("SFTPWorkspaceAppKitDragMonitor("))
    #expect(source.contains("beginSFTPDraggingSession(event: event, point: point)"))
    #expect(!source.contains("let prepareDrag: () -> Void"))
    #expect(!source.contains("var prepareDrag: (() -> Void)?"))
    #expect(!source.contains("prepareDrag?()"))
}


@Test("SFTP local drag keeps the workspace stable until drop")
func sftpLocalDragDoesNotMutateSelectionDuringDragStart() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot
  .appendingPathComponent("Sources/SelectiveRemote/SFTPWorkspace.swift"),
        encoding: .utf8
    )

    #expect(source.contains(".onDrag {\n                        NSItemProvider(object: entry.url as NSURL)\n                    }"))
    #expect(!source.contains(".onDrag {\n                        if !model.selectedEntryIDs.contains(entry.id)"))
}

@Test("SFTP workspace changes do not invalidate the application root during drag")
func sftpWorkspaceIsObservedDirectlyByConnectionCenter() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appModel = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    let center = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/ConnectionCenter.swift"),
        encoding: .utf8
    )
    let content = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )

    #expect(!appModel.contains("sftpWorkspace.objectWillChange.sink"))
    #expect(center.contains("@ObservedObject var sftpWorkspace: SFTPWorkspaceModel"))
    #expect(content.contains("sftpWorkspace: model.sftpWorkspace"))
}
