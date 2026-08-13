import Foundation
import Testing
@testable import SelectiveRemote

@Test("Connection Center поддерживает сортировку колонок и контекстные действия")
func connectionCenterTableKeepsSortingAndContextMenu() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ConnectionCenter.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("sortOrder: $sortOrder"))
    #expect(source.contains("TableColumn(\"Профиль\", value: \\.profileName)"))
    #expect(source.contains("items.sorted(using: sortOrder)"))
    #expect(source.contains("connectionContextMenu(item)"))
    #expect(source.contains("Button(\"Copy Diagnostic\""))
}

@Test("Forwarding Manager сохраняет double-click start и контекстное меню")
func forwardingManagerKeepsDoubleClickAndContextMenu() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ForwardingManager.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("TapGesture(count: 2).onEnded"))
    #expect(source.contains("if item.state.canStart"))
    #expect(source.contains("start(item)"))
    #expect(source.contains("forwardingContextMenu(item)"))
    #expect(source.contains("model.stopSSHTunnel(item.source.tunnelID)"))
}

@Test("Ручное отключение Terminal не маркируется ошибкой exit 255")
func manualTerminalStopIsPresentedAsDisconnect() throws {
    #expect(
        TerminalWorkspaceSessionState.resolve(
            phase: .finished(255),
            terminationRequested: true
        ) == .disconnected
    )

    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let pty = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/PTYSession.swift"
        ),
        encoding: .utf8
    )
    let appModel = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/AppModel.swift"
        ),
        encoding: .utf8
    )

    #expect(pty.contains("Сессия отключена пользователем"))
    #expect(appModel.contains("terminationRequested || exitCode == 0"))
}
