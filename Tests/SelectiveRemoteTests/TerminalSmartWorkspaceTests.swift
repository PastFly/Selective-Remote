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

@Test("Избранное и шаблоны команд изолированы по SSH-профилям")
@MainActor
func scopesFavoritesAndTemplatesToProfile() throws {
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
        profileID: first
    ))

    #expect(store.favorites(for: first).map(\.command) == ["systemctl status ssh"])
    #expect(store.templates(for: first).count == 1)
    #expect(store.favorites(for: second).isEmpty)
    #expect(store.templates(for: second).isEmpty)
    #expect(!store.saveTemplate(
        id: nil,
        title: "Секрет",
        command: "export token=abc",
        category: "Тест",
        profileID: first
    ))
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
    #expect(snapshot.suggestions.contains {
        $0.command == "sudo systemctl restart sshd.service"
    })
    #expect(snapshot.suggestions.contains {
        $0.command == "docker logs --tail 100 -f web-api"
    })
}
