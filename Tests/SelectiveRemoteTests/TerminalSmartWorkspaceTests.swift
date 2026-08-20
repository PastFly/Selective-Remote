import Foundation
import Testing
@testable import SelectiveRemote

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

@Test("Рабочая область терминала восстанавливает вкладки без автоподключения")
@MainActor
func restoresTerminalWorkspaceWithoutStartingSessions() throws {
    let suiteName = "TerminalSmartWorkspaceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileID = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults
    )

    let second = try #require(workspace.addTab(
        connection: .custom(host: "logs.example.test", username: "operator", port: 2222)
    ))
    workspace.renameTab(second.id, to: "Журналы")
    workspace.setLayout(.splitHorizontal)

    let restored = TerminalWorkspaceModel(
        profileID: profileID,
        primarySession: TerminalSessionModel(),
        defaults: defaults
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
    #expect(source.contains("if !isFocusMode {\n                    Button(\"Развернуть терминал\""))
    #expect(!source.contains("Button(isFocusMode ? \"Вернуть интерфейс\""))
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
    #expect(Set(store.snippetGroups().map(\.name)) == Set([
        TerminalCommandHistoryStore.defaultSnippetGroupName, "Logs"
    ]))
    #expect(store.templates(for: firstProfile).count == 2)
    #expect(store.templates(for: secondProfile).count == 2)
    #expect(store.template(id: secondID)?.targetProfileIDs == [secondProfile])

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
    #expect(store.createSnippetGroup(name: String(repeating: "x", count: 61), profileID: first) == nil)
    #expect(store.createSnippetGroup(name: "Docker", profileID: first) != nil)
    #expect(store.createSnippetGroup(name: "docker", profileID: first) == nil)
    #expect(store.createSnippetGroup(name: "Docker", profileID: second) == nil)
    #expect(store.snippetGroups(for: first).count == 1)
    #expect(store.snippetGroups(for: second).count == 1)
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

    let json = try #require(store.webPayload(for: profileID))
    let data = try #require(json.data(using: .utf8))
    let payload = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let groups = try #require(payload["snippetGroups"] as? [[String: Any]])
    let templates = try #require(payload["templates"] as? [[String: Any]])
    #expect(groups.first?["id"] as? String == group.id.uuidString)
    #expect(groups.first?["name"] as? String == "Docker")
    #expect(templates.first?["title"] as? String == "Containers")
    #expect(templates.first?["command"] as? String == "docker ps")
    #expect(templates.first?["category"] as? String == "Docker")
    #expect((templates.first?["targetProfileIDs"] as? [String])?.count == 2)
}

@Test("Multi-line Snippet сохраняет строки и получает ровно один завершающий Enter")
func preparesMultilineSnippetPTYInput() throws {
    let script = "cd /var/www\ngit pull\nsystemctl restart nginx\n\n"
    let data = try #require(TerminalSnippetExecution.inputData(for: script))
    let value = try #require(String(data: data, encoding: .utf8))

    #expect(value == "cd /var/www\ngit pull\nsystemctl restart nginx\n")
    #expect(TerminalSnippetExecution.inputData(for: "\n\n") == nil)
    #expect(TerminalSnippetExecution.inputData(for: "echo ok\0") == nil)
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
    #expect(arguments.contains("-J"))
    #expect(arguments.contains("jump@jump.example.test:2222"))
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
