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
    let normalized = normalizedSwiftSource(source)

    // The WebView quick panels stay hidden; only the selected pane may request
    // a visibility change for the shared native Inspector.
    #expect(normalized.contains("get: { false }"))
    #expect(normalized.contains("guard tab.id == workspace.selectedTabID else { return }"))
    #expect(!source.contains("if visible { workspace.selectedTabID = tab.id }"))
}

@Test("Grid Terminal Workspace использует единый полноразмерный инспектор")
func terminalGridUsesSharedWorkspaceInspector() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let workspaceSource = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
        ),
        encoding: .utf8
    )
    let inspectorSource = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/TerminalWorkspaceInspector.swift"
        ),
        encoding: .utf8
    )
    let normalizedWorkspace = normalizedSwiftSource(workspaceSource)

    // v0.27 deliberately uses the same Inspector in single/split/grid. Verify
    // the architecture without depending on indentation or line wrapping.
    #expect(normalizedWorkspace.contains("private var workspaceInspectorVisible: Bool { showsHistory || showsSnippets }"))
    #expect(normalizedWorkspace.contains("private var terminalWorkspaceWithInspector: some View"))
    #expect(workspaceSource.contains("TerminalWorkspaceInspector("))
    #expect(!workspaceSource.contains("workspace.layout == .grid && (showsHistory || showsSnippets)"))
    #expect(inspectorSource.contains("Один клик вставляет · двойной выполняет"))
    #expect(inspectorSource.contains("TapGesture(count: 2)"))
    #expect(inspectorSource.contains("Button(\"Выполнить на Targets\""))
    #expect(inspectorSource.contains("Button(\"Скопировать\""))
    #expect(inspectorSource.contains("case catalog = \"Общие\""))
    #expect(inspectorSource.contains("case server = \"Сервер\""))
    #expect(inspectorSource.contains("case favorites = \"Избранное\""))
    #expect(inspectorSource.contains("Color(nsColor: .controlBackgroundColor)"))
}

@Test("Нативный инспектор читает полный каталог общих команд")
func nativeInspectorLoadsBuiltInCommandCatalog() {
    let entries = TerminalBuiltInCommandCatalog.entries

    #expect(entries.count >= 300)
    #expect(entries.contains(where: { $0.command == "pwd" }))
    #expect(entries.contains(where: { $0.command == "sudo certbot renew --dry-run" }))
}

@Test("Редактор сниппета объясняет назначение поля команды")
func snippetEditorShowsCommandPlaceholder() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/TerminalSnippetsLibraryView.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("Section(\"Команда или скрипт\")"))
    #expect(source.contains("Введите команду или скрипт, например: docker ps"))
    #expect(source.contains("if command.isEmpty"))
}

@Test("Локальный терминал сочетает основные действия с дополнительным меню")
func localTerminalUsesVisibleHeaderActionsAndMenu() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/LocalTerminalView.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("Image(systemName: \"folder\")"))
    #expect(source.contains("Image(systemName: \"eraser\")"))
    #expect(source.contains("Image(systemName: \"paintpalette\")"))
    #expect(source.contains("Image(systemName: \"ellipsis.circle\")"))
    #expect(source.contains("Button(\"Развернуть терминал\""))
    #expect(source.contains("Button(\"Вернуть интерфейс\""))
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

@Test("Переключение grid pane с открытой историей не возвращает фокус старой панели")
func terminalHistoryProgrammaticHideDoesNotRefocusOldPane() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let swiftSource = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
        ),
        encoding: .utf8
    )
    let hostScript = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/TerminalResources/terminal-host.js"
        ),
        encoding: .utf8
    )

    #expect(
        swiftSource.contains(
            "selectiveTerminalSetPanelMode?.('\\(mode)', false, false)"
        )
    )
    #expect(hostScript.contains("restoreTerminalFocus = true"))
    #expect(hostScript.contains("else if (restoreTerminalFocus)"))
}

@Test("Глобальные Snippets расположены перед диагностикой и поддерживают быстрый запуск")
func globalSnippetsHaveExpectedNavigationAndActions() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let contentSource = try String(
        contentsOf: projectRoot.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    let snippetsSource = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/TerminalSnippetsLibraryView.swift"
        ),
        encoding: .utf8
    )

    let snippetsRange = try #require(contentSource.range(of: "case snippets = \"Сниппеты\""))
    let diagnosticsRange = try #require(contentSource.range(of: "case diagnostics = \"Диагностика\""))
    #expect(snippetsRange.lowerBound < diagnosticsRange.lowerBound)
    #expect(snippetsSource.contains("TapGesture(count: 2)"))
    #expect(snippetsSource.contains("Button(\"Запустить\", systemImage: \"play.fill\")"))
    #expect(snippetsSource.contains("Последний запуск"))
    #expect(snippetsSource.contains("sheet(item: $editorRequest)"))
}

private func normalizedSwiftSource(_ source: String) -> String {
    source
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}
