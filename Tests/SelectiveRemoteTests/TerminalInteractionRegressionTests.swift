import Foundation
import Testing
@testable import SelectiveRemote

@Test("История активной Terminal pane не принимает stale visibility callbacks соседней панели")
func terminalHistoryVisibilityIsOwnedBySelectedPane() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("guard tab.id == workspace.selectedTabID else { return }"))
    #expect(!source.contains("if visible { workspace.selectedTabID = tab.id }"))
}

@Test("Отключённая Terminal pane повторно использует свой сервер без открытия редактора")
func terminalConnectReusesExistingPaneConnection() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("if canReuseConnection(tab.connection)"))
    #expect(source.contains("connect(tab, nil)"))
    #expect(source.contains("connection.isValidCustomConnection"))
}

@Test("Grid Terminal Workspace показывает отдельную кнопку добавления в свободной ячейке")
func terminalGridHasInlineAddPane() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("let canAddPane = tabs.count < 4"))
    #expect(source.contains("gridAddPane"))
    #expect(source.contains("Добавить SSH-панель"))
}
