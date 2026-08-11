import Foundation
import Testing
@testable import SelectiveRemote

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
