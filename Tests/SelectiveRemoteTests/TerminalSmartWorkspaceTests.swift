import Foundation
import Testing
@testable import SelectiveRemote

@Test("New local Terminal command uses the production generated-tab creation path")
func newLocalTerminalCommandUsesGeneratedCreationPath() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    let afterActionName = try #require(
        source.components(separatedBy: "private func openNewLocalTerminalTab()").dropFirst().first
    )
    let action = try #require(
        afterActionName.components(separatedBy: "private func openConnectionCenterSource").first
    )
    #expect(action.contains("workspace.tabForNewLocalTerminalCommand("))
    #expect(!action.contains("workspace.selectedTabID = primary.id"))
}

@Test("New local Terminal action preserves unknown legacy title and creates locale-reactive tabs")
@MainActor
func newLocalTerminalProductionPathPreservesLegacyAndRerenders() throws {
    let suiteName = "LocalTerminalProductionPath.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)
    language.selection = .russian
    let profileID = UUID()
    let legacyTitle = "Терминал 1"
    let legacyStorage: [String: Any] = [
        "tabs": [["id": UUID().uuidString, "title": legacyTitle, "isPrimary": true]],
        "layout": "single"
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: legacyStorage),
                 forKey: "SelectiveRemote.terminal.workspace.v1.\(profileID.uuidString)")

    let workspace = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        primaryConnection: .local(workingDirectory: "/tmp"),
        defaults: defaults,
        language: language
    )
    let first = try #require(workspace.tabForNewLocalTerminalCommand(workingDirectory: "/tmp"))
    #expect(first.id != workspace.tabs[0].id)
    #expect(first.title == "Терминал 1")
    #expect(first.generatedTitleNumber == 1)
    let second = try #require(workspace.tabForNewLocalTerminalCommand(workingDirectory: "/tmp"))
    #expect(second.title == "Терминал 2")
    workspace.renameTab(second.id, to: "My terminal")

    language.selection = .english
    #expect(workspace.tabs.map(\.title) == [legacyTitle, "Terminal 1", "My terminal"])
    let restored = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        primaryConnection: .local(workingDirectory: "/tmp"),
        defaults: defaults,
        language: language
    )
    #expect(restored.tabs.map(\.title) == [legacyTitle, "Terminal 1", "My terminal"])
    language.selection = .russian
    #expect(restored.tabs.map(\.title) == [legacyTitle, "Терминал 1", "My terminal"])
}

@Test("Fresh primary and command-created local tabs retain numbered, locale-reactive provenance")
@MainActor
func freshLocalTerminalProductionPathHasDistinctGeneratedNumbers() throws {
    let suiteName = "FreshLocalTerminalProductionPath.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)
    language.selection = .russian
    let profileID = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        primaryConnection: .local(workingDirectory: "/tmp"),
        defaults: defaults,
        language: language
    )
    #expect(workspace.tabs.map(\.title) == ["Терминал 1"])
    #expect(workspace.tabs.map(\.generatedTitleNumber) == [1])
    let initialCommandTab = try #require(workspace.tabForNewLocalTerminalCommand(workingDirectory: "/tmp"))
    #expect(initialCommandTab.id == workspace.tabs[0].id)
    let additional = try #require(workspace.addTab(connection: .local(workingDirectory: "/tmp")))
    #expect(additional.generatedTitleNumber == 2)
    #expect(workspace.tabs.map(\.title) == ["Терминал 1", "Терминал 2"])

    language.selection = .english
    #expect(workspace.tabs.map(\.title) == ["Terminal 1", "Terminal 2"])
    let restored = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        primaryConnection: .local(workingDirectory: "/tmp"),
        defaults: defaults,
        language: language
    )
    #expect(restored.tabs.map(\.generatedTitleNumber) == [1, 2])
    #expect(restored.tabs.map(\.title) == ["Terminal 1", "Terminal 2"])
    language.selection = .russian
    #expect(restored.tabs.map(\.title) == ["Терминал 1", "Терминал 2"])
}

@Test("New local terminal startup banner uses the application locale at session creation")
@MainActor
func localTerminalStartupBannerUsesApplicationLanguage() throws {
    let suiteName = "LocalTerminalBanner.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)
    for (selection, expected) in [
        (AppLanguage.russian, "Selective Remote · Локальный терминал"),
        (.english, "Selective Remote · Local Terminal")
    ] {
        language.selection = selection
        let session = TerminalSessionModel()
        // A nonexistent executable exercises banner generation without starting a shell.
        #expect(throws: (any Error).self) {
            try session.start(
                executable: "/nonexistent/selective-remote-test-shell",
                arguments: [],
                title: language.localized("terminal.local.accessibility")
            )
        }
        var output = Data()
        let observer = session.addOutputObserver { output.append($0) }
        defer { session.removeOutputObserver(observer) }
        #expect(String(decoding: output, as: UTF8.self).contains(expected))
    }

    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    let afterFunctionName = try #require(
        source.components(separatedBy: "func connectLocalTerminal(").dropFirst().first
    )
    let localConnection = try #require(
        afterFunctionName.components(separatedBy: "private func beginTerminalSessionLog(").first
    )
    #expect(localConnection.contains("title: AppLanguageStore.shared.localized(\"terminal.local.accessibility\")"))
    #expect(!localConnection.contains("title: \"Локальный терминал\""))
}

@Test("Выбранный язык приложения сохраняется между запусками")
@MainActor
func persistsApplicationLanguage() throws {
    let suiteName = "AppLanguageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let original = AppLanguageStore(defaults: defaults)
    #expect(original.selection == .system)
    original.selection = .english

    let restored = AppLanguageStore(defaults: defaults)
    #expect(restored.selection == .english)
    #expect(restored.locale.identifier == "en")
}

@Test("Generated terminal titles follow RU and EN, but explicit titles do not")
@MainActor
func generatedTerminalTitlesFollowLanguageWithoutRenamingCustomTabs() throws {
    let suiteName = "GeneratedTerminalTitles.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)

    language.selection = .russian
    let profileID = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults,
        language: language
    )
    #expect(workspace.tabs.map(\.title) == ["Терминал 1"])

    let second = try #require(workspace.addTab(select: false))
    #expect(workspace.tabs.map(\.title) == ["Терминал 1", "Терминал 2"])

    language.selection = .english
    #expect(workspace.tabs.map(\.title) == ["Terminal 1", "Terminal 2"])
    workspace.renameTab(second.id, to: "Terminal 2")

    language.selection = .russian
    #expect(workspace.tabs.map(\.title) == ["Терминал 1", "Terminal 2"])
    language.selection = .english
    #expect(workspace.tabs.map(\.title) == ["Terminal 1", "Terminal 2"])

    let restoredLanguage = AppLanguageStore(defaults: defaults)
    #expect(restoredLanguage.selection == .english)
    let restored = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults,
        language: restoredLanguage
    )
    #expect(restored.tabs.map(\.title) == ["Terminal 1", "Terminal 2"])
    restoredLanguage.selection = .russian
    #expect(restored.tabs.map(\.title) == ["Терминал 1", "Terminal 2"])
}

@Test("English-first default titles retain their generated origin through a workspace snapshot")
@MainActor
func englishGeneratedTerminalTitlesSurviveSnapshotRestore() throws {
    let suiteName = "EnglishTerminalTitles.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)
    language.selection = .english

    let workspace = TerminalWorkspaceModel(
        profileID: UUID(),
        primarySession: TerminalSessionModel(),
        defaults: defaults,
        language: language
    )
    #expect(workspace.tabs[0].title == "Terminal 1")
    let second = try #require(workspace.addTab(select: false))
    #expect(second.title == "Terminal 2")
    let primaryID = workspace.tabs[0].id
    #expect(workspace.updateConnection(
        tabID: primaryID,
        connection: .local(workingDirectory: "/tmp"),
        suggestedTitle: workspace.tabs[0].title
    ))
    let snapshot = workspace.workspaceSnapshot()

    language.selection = .russian
    #expect(workspace.restoreWorkspaceSnapshot(snapshot))
    #expect(workspace.tabs.map(\.title) == ["Терминал 1", "Терминал 2"])
}

@Test("Historical terminal titles without origin metadata remain unclassified and unchanged")
@MainActor
func historicalTerminalTitleWithoutProvenanceIsNotGuessedFromItsText() throws {
    let suiteName = "LegacyTerminalTitles.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)
    language.selection = .english
    let profileID = UUID()
    let historicalTabID = UUID()
    let legacyTitle = "  Терминал 1 — ручное  "
    let legacyStorage: [String: Any] = [
        "tabs": [["id": historicalTabID.uuidString, "title": legacyTitle, "isPrimary": true]],
        "layout": "single"
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: legacyStorage),
        forKey: "SelectiveRemote.terminal.workspace.v1.\(profileID.uuidString)"
    )

    let workspace = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults,
        language: language
    )
    #expect(workspace.tabs[0].title == legacyTitle)
    #expect(workspace.tabs[0].generatedTitleNumber == nil)
    language.selection = .russian
    language.selection = .english
    #expect(workspace.tabs[0].title == legacyTitle)
    let restored = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults,
        language: language
    )
    #expect(restored.tabs[0].title == legacyTitle)
}

@Test("Рабочая область терминала восстанавливает вкладки без автоподключения")
@MainActor
func restoresTerminalWorkspaceWithoutStartingSessions() throws {
    let suiteName = "TerminalSmartWorkspaceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let language = AppLanguageStore(defaults: defaults)
    language.selection = .russian
    let profileID = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults,
        language: language
    )

    let second = try #require(workspace.addTab(
        connection: .custom(host: "logs.example.test", username: "operator", port: 2222)
    ))
    workspace.renameTab(second.id, to: "Журналы")
    workspace.setLayout(.splitHorizontal)

    let restored = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults,
        language: language
    )
    #expect(restored.tabs.map(\.title) == ["Терминал 1", "Журналы"])
    #expect(restored.layout == .splitHorizontal)
    #expect(!restored.tabs.contains(where: { $0.session.isRunning }))
    #expect(restored.tabs[1].connection.kind == .custom)
    #expect(restored.tabs[1].connection.host == "logs.example.test")
    #expect(restored.tabs[1].connection.username == "operator")
    #expect(restored.tabs[1].connection.port == 2222)
}

@Test("Временное подключение SSH проверяет host, login и port")
func validatesCustomTerminalConnection() {
    #expect(TerminalTabConnection.custom(
        host: "server.example.test",
        username: "admin",
        port: 22
    ).isValidCustomConnection)
    #expect(!TerminalTabConnection.custom(
        host: "",
        username: "admin",
        port: 22
    ).isValidCustomConnection)
    #expect(!TerminalTabConnection.custom(
        host: "server.example.test",
        username: "bad user",
        port: 22
    ).isValidCustomConnection)
    #expect(!TerminalTabConnection.custom(
        host: "server.example.test",
        username: "admin",
        port: 70_000
    ).isValidCustomConnection)
}

@Test("Сетка терминала показывает до четырёх независимых вкладок")
@MainActor
func exposesFourPaneTerminalGrid() throws {
    let suiteName = "TerminalGridTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = TerminalWorkspaceModel(
        profileID: UUID(),
        primarySession: TerminalSessionModel(),
        primaryConnection: .custom(host: "first.example.test", username: "root"),
        defaults: defaults
    )
    for index in 2...5 {
        _ = workspace.addTab(
            connection: .custom(
                host: "server-\(index).example.test",
                username: "operator"
            ),
            select: false
        )
    }
    workspace.setLayout(.grid)

    #expect(workspace.layout == .grid)
    #expect(workspace.visibleTabs().count == 4)
    #expect(Set(workspace.visibleTabs().map(\.connection.normalizedHost)).count == 4)

    let originalOrder = workspace.visibleTabs().map(\.id)
    workspace.selectedTabID = originalOrder[2]
    #expect(workspace.visibleTabs().map(\.id) == originalOrder)

    workspace.moveTab(originalOrder[2], to: originalOrder[0])
    #expect(workspace.visibleTabs().first?.id == originalOrder[2])

    let restored = TerminalWorkspaceModel(
        profileID: workspace.profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults
    )
    #expect(restored.tabs.first?.id == originalOrder[2])
}

@Test("Пустой независимый терминал сохраняет выбранную сетку")
@MainActor
func emptyTerminalWorkspaceKeepsGridLayout() throws {
    let suiteName = "EmptyTerminalGridTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileID = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        primaryConnection: .custom(host: "", username: ""),
        defaults: defaults
    )

    #expect(workspace.isEmptyState)
    workspace.setLayout(.grid)
    #expect(workspace.layout == .grid)
    #expect(workspace.isEmptyState)

    let restored = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        primaryConnection: .custom(host: "", username: ""),
        defaults: defaults
    )
    #expect(restored.layout == .grid)
    #expect(restored.isEmptyState)
}

@Test("Focus mode показывает отдельную кнопку возврата интерфейса")
func focusModeExposesVisibleRestoreInterfaceButton() throws {
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

    #expect(source.contains("if isFocusMode {\n                Button(\"Вернуть интерфейс\""))
    #expect(source.contains("} else {\n                Button(\"Развернуть терминал\""))
    #expect(!source.contains("Button(isFocusMode ? \"Вернуть интерфейс\""))
    let expandButton = try #require(source.range(of: "Button(\"Развернуть терминал\""))
    let actionsMenu = try #require(source.range(of: "Menu {", range: expandButton.upperBound..<source.endIndex))
    #expect(expandButton.lowerBound < actionsMenu.lowerBound)
    #expect(source.contains("private var gridEmptyPane: some View"))
}

@Test("Первую вкладку независимого терминала можно закрыть")
@MainActor
func closesAndPromotesPrimaryTerminalTab() throws {
    let suiteName = "TerminalPrimaryCloseTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = TerminalWorkspaceModel(
        profileID: UUID(),
        primarySession: TerminalSessionModel(),
        primaryConnection: .custom(host: "first.example.test", username: "root"),
        defaults: defaults
    )
    let firstID = workspace.tabs[0].id
    let second = try #require(workspace.addTab(
        connection: .custom(host: "second.example.test", username: "admin")
    ))

    workspace.closeTab(firstID)

    #expect(workspace.tabs.count == 1)
    #expect(workspace.tabs[0].id == second.id)
    #expect(workspace.tabs[0].isPrimary)
    workspace.closeTab(second.id)
    #expect(workspace.tabs.count == 1)
    #expect(workspace.isEmptyState)
    #expect(workspace.displayedTabs.isEmpty)

    let replacement = try #require(workspace.addTab(
        connection: .custom(host: "third.example.test", username: "root")
    ))
    #expect(!workspace.isEmptyState)
    #expect(workspace.tabs.count == 1)
    #expect(replacement.id == workspace.tabs[0].id)
}

@Test("Независимый туннель сохраняет собственную SSH-цель")
func persistsIndependentForwardingTarget() throws {
    let original = IndependentPortForward(
        connection: .custom(
            host: "gateway.example.test",
            username: "admin",
            port: 2222
        ),
        kind: .dynamic
    )
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(IndependentPortForward.self, from: data)

    #expect(restored.id == original.id)
    #expect(restored.rule.kind == .dynamic)
    #expect(restored.connection.normalizedHost == "gateway.example.test")
    #expect(restored.connection.port == 2222)
}

@Test("Избранное остаётся profile-scoped, а Snippets образуют общую библиотеку Targets")
@MainActor
func exposesGlobalSnippetsWithMultipleTargets() throws {
    let suiteName = "TerminalCommandLibraryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let first = UUID()
    let second = UUID()

    #expect(store.toggleFavorite(command: "systemctl status ssh", profileID: first))
    #expect(store.saveTemplate(
        id: nil,
        title: "Перезапустить службу",
        command: "sudo systemctl restart ${service}",
        category: "Службы",
        profileID: first,
        targetProfileIDs: [first, second]
    ))

    #expect(store.favorites(for: first).map(\.command) == ["systemctl status ssh"])
    #expect(store.templates(for: first).count == 1)
    #expect(store.favorites(for: second).isEmpty)
    #expect(store.templates(for: second).count == 1)
    #expect(store.templates().first?.targetProfileIDs == [first, second])
    #expect(!store.saveTemplate(
        id: nil,
        title: "Секрет",
        command: "export token=abc",
        category: "Тест",
        profileID: first
    ))
}

@Test("Многострочный Snippet создаётся, изменяется и сохраняется без потери строк")
@MainActor
func persistsAndUpdatesMultilineSnippet() throws {
    let suiteName = "TerminalMultilineSnippetTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileID = UUID()
    var store = TerminalCommandHistoryStore(defaults: defaults)
    let original = "cd /var/www\ngit pull"

    #expect(store.saveTemplate(
        id: nil,
        title: "Deploy",
        command: original,
        category: "Release",
        profileID: profileID,
        targetProfileIDs: [profileID]
    ))
    let snippet = try #require(store.templates().first)
    #expect(snippet.command == original)

    let updated = original + "\nsudo systemctl restart nginx"
    #expect(store.saveTemplate(
        id: snippet.id,
        title: snippet.title,
        command: updated,
        category: snippet.category,
        groupID: snippet.groupID,
        profileID: profileID,
        targetProfileIDs: [profileID]
    ))
    #expect(store.template(id: snippet.id)?.command == updated)

    store = TerminalCommandHistoryStore(defaults: defaults)
    #expect(store.template(id: snippet.id)?.command == updated)
}

@Test("Группы сниппетов и команды переживают перезапуск хранилища")
@MainActor
func persistsSnippetGroupsAndCRUD() throws {
    let suiteName = "TerminalSnippetPersistenceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileID = UUID()

    var store = TerminalCommandHistoryStore(defaults: defaults)
    let docker = try #require(store.createSnippetGroup(
        name: "Docker",
        profileID: profileID,
        now: Date(timeIntervalSince1970: 1)
    ))
    let system = try #require(store.createSnippetGroup(
        name: "System",
        profileID: profileID,
        now: Date(timeIntervalSince1970: 2)
    ))
    #expect(store.saveTemplate(
        id: nil,
        title: "Show containers",
        command: "docker ps",
        category: docker.name,
        profileID: profileID
    ))
    let snippet = try #require(store.templates().first)
    #expect(store.moveTemplate(id: snippet.id, toGroupID: system.id, profileID: profileID))
    #expect(store.renameSnippetGroup(id: system.id, name: "Host", profileID: profileID))
    #expect(store.templates().first?.category == "Host")
    #expect(store.duplicateTemplate(id: snippet.id, profileID: profileID))
    #expect(store.templates().count == 2)

    store = TerminalCommandHistoryStore(defaults: defaults)
    #expect(store.snippetGroups().map(\.name).contains("Docker"))
    #expect(store.snippetGroups().map(\.name).contains("Host"))
    #expect(store.templates().count == 2)

    #expect(store.removeSnippetGroup(id: system.id, profileID: profileID))
    #expect(store.templates().allSatisfy {
        $0.category == TerminalCommandHistoryStore.defaultSnippetGroupName
    })
    for item in store.templates() {
        #expect(store.removeTemplate(id: item.id))
    }
    #expect(store.templates().isEmpty)
    store = TerminalCommandHistoryStore(defaults: defaults)
    #expect(store.templates().isEmpty)
}

@Test("Переименование родительской группы сохраняет вложенное дерево Snippets")
@MainActor
func renamesNestedSnippetGroupTree() throws {
    let suiteName = "TerminalNestedSnippetGroupTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let profileID = UUID()
    let parent = try #require(store.createSnippetGroup(name: "Production", profileID: profileID))
    let child = try #require(store.createSnippetGroup(name: "Production/Deploy", profileID: profileID))
    #expect(store.saveTemplate(
        id: nil,
        title: "Deploy",
        command: "systemctl restart app",
        category: child.name,
        groupID: child.id,
        profileID: profileID,
        targets: [.sshProfile(profileID)]
    ))

    #expect(store.renameSnippetGroup(
        id: parent.id,
        name: "Infrastructure",
        profileID: profileID
    ))
    #expect(store.snippetGroup(id: child.id)?.name == "Infrastructure/Deploy")
    #expect(store.templates(in: child.id).first?.category == "Infrastructure/Deploy")
    #expect(!store.removeSnippetGroup(id: parent.id, profileID: profileID))
}

@Test("Legacy Templates становятся глобальными Snippets с исходным профилем как Target")
@MainActor
func migratesLegacyTemplatesToSnippetGroups() throws {
    let suiteName = "TerminalSnippetMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstProfile = UUID()
    let secondProfile = UUID()
    let firstID = UUID()
    let secondID = UUID()
    let legacy = [
        TerminalCommandTemplate(
            id: firstID,
            profileID: firstProfile,
            title: "Disk usage",
            command: "df -h",
            category: "",
            updatedAt: Date(timeIntervalSince1970: 10)
        ),
        TerminalCommandTemplate(
            id: secondID,
            profileID: secondProfile,
            title: "nginx errors",
            command: "tail -n 100 /var/log/nginx/error.log",
            category: "Logs",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    ]
    defaults.set(
        try JSONEncoder().encode(legacy),
        forKey: "SelectiveRemote.terminal.commandTemplates.v1"
    )

    var store = TerminalCommandHistoryStore(defaults: defaults)
    let migrated = try #require(store.template(id: firstID, profileID: firstProfile))
    #expect(migrated.title == "Disk usage")
    #expect(migrated.command == "df -h")
    #expect(migrated.profileID == firstProfile)
    #expect(migrated.targetProfileIDs == [firstProfile])
    #expect(migrated.category == TerminalCommandHistoryStore.defaultSnippetGroupName)
    #expect(migrated.groupID != TerminalCommandTemplate.legacyUnassignedGroupID)
    #expect(Set(store.snippetGroups().map(\.name)) == Set([
        TerminalCommandHistoryStore.defaultSnippetGroupName, "Logs"
    ]))
    #expect(store.templates(for: firstProfile).count == 2)
    #expect(store.templates(for: secondProfile).count == 2)
    #expect(store.template(id: secondID)?.targetProfileIDs == [secondProfile])
    let logsGroup = try #require(store.snippetGroups().first(where: { $0.name == "Logs" }))
    #expect(store.template(id: secondID)?.groupID == logsGroup.id)
    #expect(store.templates(in: logsGroup.id).map(\.id) == [secondID])

    // Migration is idempotent and persists the normalized legacy value.
    store = TerminalCommandHistoryStore(defaults: defaults)
    #expect(store.snippetGroups().count == 2)
    #expect(store.template(id: firstID, profileID: firstProfile)?.category
        == TerminalCommandHistoryStore.defaultSnippetGroupName)
}

@Test("Группы Snippets глобальны, а Targets дедуплицируются и ограничены восемью")
@MainActor
func validatesGlobalSnippetGroupsAndTargets() throws {
    let suiteName = "TerminalSnippetGroupScopeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let first = UUID()
    let second = UUID()

    #expect(store.createSnippetGroup(name: "", profileID: first) == nil)
    #expect(store.createSnippetGroup(name: String(repeating: "x", count: 121), profileID: first) == nil)
    #expect(store.createSnippetGroup(name: "Docker/Production", profileID: first) != nil)
    #expect(store.createSnippetGroup(name: "Docker//Broken", profileID: first) == nil)
    #expect(store.createSnippetGroup(name: "Docker", profileID: first) != nil)
    #expect(store.createSnippetGroup(name: "docker", profileID: first) == nil)
    #expect(store.createSnippetGroup(name: "Docker", profileID: second) == nil)
    #expect(store.snippetGroups(for: first).count == 2)
    #expect(store.snippetGroups(for: second).count == 2)
    let extraTargets = (0..<10).map { _ in UUID() }
    #expect(store.saveTemplate(
        id: nil,
        title: "Targets",
        command: "hostname",
        category: "Docker",
        profileID: first,
        targetProfileIDs: [first, second, first] + extraTargets
    ))
    #expect(store.templates().first?.targetProfileIDs.count == 8)
    let docker = try #require(store.snippetGroups().first(where: { $0.name == "Docker" }))
    #expect(store.templates().first?.groupID == docker.id)
    #expect(Array(store.templates().first?.targetProfileIDs.prefix(2) ?? []) == [first, second])
    #expect(!store.saveTemplate(
        id: nil,
        title: "",
        command: "whoami",
        category: "Docker",
        profileID: first
    ))
    #expect(!store.saveTemplate(
        id: nil,
        title: "Secret",
        command: "export token=abc",
        category: "Docker",
        profileID: first
    ))
}

@Test("Web payload содержит Snippets и стабильные идентификаторы групп")
@MainActor
func serializesSnippetGroupsForTerminalBridge() throws {
    let suiteName = "TerminalSnippetPayloadTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let profileID = UUID()
    let group = try #require(store.createSnippetGroup(name: "Docker", profileID: profileID))
    #expect(store.saveTemplate(
        id: nil,
        title: "Containers",
        command: "docker ps",
        category: group.name,
        profileID: profileID,
        targetProfileIDs: [profileID, UUID()]
    ))

    let target = TerminalSnippetTargetOption(
        id: profileID,
        title: "Production",
        subtitle: "server.example.com"
    )
    let json = try #require(store.webPayload(
        for: profileID,
        snippetTargets: [target]
    ))
    let data = try #require(json.data(using: .utf8))
    let payload = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let groups = try #require(payload["snippetGroups"] as? [[String: Any]])
    let templates = try #require(payload["templates"] as? [[String: Any]])
    let targets = try #require(payload["snippetTargets"] as? [[String: Any]])
    #expect(groups.first?["id"] as? String == group.id.uuidString)
    #expect(groups.first?["name"] as? String == "Docker")
    #expect(templates.first?["title"] as? String == "Containers")
    #expect(templates.first?["command"] as? String == "docker ps")
    #expect(templates.first?["category"] as? String == "Docker")
    #expect((templates.first?["targetProfileIDs"] as? [String])?.count == 2)
    #expect(payload["defaultSnippetTargetID"] as? String == profileID.uuidString)
    #expect(targets.first?["id"] as? String == profileID.uuidString)
    #expect(targets.first?["title"] as? String == "Production")
    #expect(targets.first?["subtitle"] as? String == "server.example.com")
}

@Test("Multi-line Snippet сохраняет строки и получает ровно один завершающий Enter")
func preparesMultilineSnippetPTYInput() throws {
    let script = "cd /var/www\ngit pull\nsystemctl restart nginx\n\n"
    let data = try #require(TerminalSnippetExecution.inputData(for: script))
    let value = try #require(String(data: data, encoding: .utf8))

    #expect(value == "cd /var/www\ngit pull\nsystemctl restart nginx\n")
    let windowsData = try #require(
        TerminalSnippetExecution.inputData(for: "cd C:\\work\r\ndir\r\n")
    )
    #expect(String(data: windowsData, encoding: .utf8) == "cd C:\\work\ndir\n")
    #expect(TerminalSnippetExecution.inputData(for: "\n\n") == nil)
    #expect(TerminalSnippetExecution.inputData(for: "echo ok\0") == nil)
    #expect(TerminalSnippetExecution.inputData(for: "echo ok\u{001B}") == nil)
}

@Test("Контекст сервера создаёт подсказки для служб и контейнеров")
func buildsRemoteServiceAndContainerSuggestions() throws {
    var profile = ConnectionProfile()
    profile.connectionType = .ssh
    profile.host = "example.test"
    profile.username = "operator"
    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let snapshot = TerminalRemoteContextService.parse(
        output: """
        SYSTEM\tDebian GNU/Linux 13
        COMMAND\tsystemctl
        COMMAND\tjournalctl
        COMMAND\tdocker
        SERVICE\tsshd.service
        CONTAINER\tweb-api
        """,
        settings: settings
    )

    #expect(snapshot.systemLabel == "Debian GNU/Linux 13")
    #expect(!snapshot.canRetry)
    #expect(snapshot.suggestions.contains {
        $0.command == "sudo systemctl restart sshd.service"
    })
    #expect(snapshot.suggestions.contains {
        $0.command == "docker logs --tail 100 -f web-api"
    })
}

@Test("Контекст сервера использует отдельный SSH probe с полной аутентификацией")
func remoteContextProbePreservesSSHAuthenticationAndJumpHost() throws {
    var jump = ConnectionProfile(connectionType: .ssh)
    jump.friendlyName = "Jump"
    jump.host = "jump.example.test"
    jump.username = "jump"
    jump.sshPort = 2222

    var target = ConnectionProfile(connectionType: .ssh)
    target.friendlyName = "Target"
    target.host = "target.example.test"
    target.username = "root"
    target.sshPort = 2200
    target.sshAuthenticationMode = .password

    let settings = try SSHConnectionSettings(
        profile: target,
        identity: nil,
        jumpHost: jump
    )
    let arguments = TerminalRemoteContextService.probeArguments(settings: settings)

    #expect(arguments.contains("-S"))
    #expect(arguments.contains("none"))
    #expect(arguments.contains("ControlMaster=no"))
    #expect(!arguments.contains("BatchMode=yes"))
    #expect(arguments.contains("NumberOfPasswordPrompts=1"))
    #expect(arguments.contains("User=root"))
    #expect(arguments.contains("PreferredAuthentications=keyboard-interactive,password"))
    #expect(arguments.contains("PubkeyAuthentication=no"))
    #expect(arguments.contains("2200"))
    #expect(!arguments.contains("-J"))
    #expect(arguments.contains(where: { $0.hasPrefix("ProxyCommand=") && $0.contains("jump.example.test") }))
    #expect(arguments.contains("target.example.test"))
    #expect(arguments.contains("-T"))
}

@Test("Смена подключения вкладки полностью заменяет profileID")
@MainActor
func terminalTabConnectionDoesNotKeepStaleProfileID() throws {
    let suiteName = "TerminalProfileSwitchTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstProfileID = UUID()
    let secondProfileID = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: firstProfileID,
        primarySession: TerminalSessionModel(),
        primaryConnection: .savedProfile(firstProfileID),
        defaults: defaults
    )
    let tabID = workspace.selectedTabID

    #expect(workspace.updateConnection(
        tabID: tabID,
        connection: .savedProfile(secondProfileID),
        suggestedTitle: "Второй сервер"
    ))
    #expect(workspace.selectedTab.connection.profileID == secondProfileID)

    #expect(workspace.updateConnection(
        tabID: tabID,
        connection: .custom(host: "custom.example.test", username: "operator"),
        suggestedTitle: "Custom"
    ))
    #expect(workspace.selectedTab.connection.profileID == nil)
    #expect(workspace.selectedTab.connection.host == "custom.example.test")
}
