import Foundation
import Testing
@testable import SelectiveRemote

struct ProfileOrganizationAndSecurityTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("Пользовательские теги сохраняются и старые профили мигрируют без потерь")
    func customTagsPersistAndLegacyProfilesMigrate() throws {
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.tags = ["Production", "Личный"]

        let encoded = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: encoded)
        #expect(restored.tags == ["Production", "Личный"])

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "tags")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let migrated = try JSONDecoder().decode(ConnectionProfile.self, from: legacyData)
        #expect(migrated.tags.isEmpty)
    }

    @Test("Путь вложенных папок нормализуется, а ручной порядок мигрирует совместимо")
    func nestedFolderPathAndManualOrderAreBackwardCompatible() throws {
        #expect(
            SelectiveRemoteHostFolderPath.normalize("  Infrastructure // Production / Linux  ")
                == "Infrastructure/Production/Linux"
        )
        #expect(SelectiveRemoteHostFolderPath.components("A/B/C") == ["A", "B", "C"])

        var profile = ConnectionProfile(connectionType: .ssh)
        profile.group = "Infrastructure/Production"
        profile.sortIndex = 7
        let encoded = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: encoded)
        #expect(restored.sortIndex == 7)

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "sortIndex")
        legacy.removeValue(forKey: "folderOrderPath")
        let migrated = try JSONDecoder().decode(
            ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(migrated.sortIndex == 0)
        #expect(migrated.folderOrderPath.isEmpty)
    }

    @Test("Дерево Personal Hosts строит папку внутри папки")
    func personalHostTreeBuildsNestedFolders() throws {
        var host = ConnectionProfile(connectionType: .ssh)
        host.group = "Infrastructure/Production/Linux"
        host.friendlyName = "Bastion"
        let roots = SelectiveRemoteProfileFolderNode.roots(from: [
            .init(name: host.group, profiles: [host])
        ])
        let infrastructure = try #require(roots.first)
        #expect(infrastructure.path == "Infrastructure")
        let production = try #require(infrastructure.children.first)
        #expect(production.path == "Infrastructure/Production")
        let linux = try #require(production.children.first)
        #expect(linux.path == "Infrastructure/Production/Linux")
        #expect(linux.profiles.map(\.id) == [host.id])
    }

    @Test("Nested folder reorder and move survive profile serialization")
    func nestedFolderDragPersists() throws {
        var alpha = ConnectionProfile(connectionType: .ssh)
        alpha.group = "Ops/Alpha"
        var beta = ConnectionProfile(connectionType: .ssh)
        beta.group = "Ops/Beta"
        var gamma = ConnectionProfile(connectionType: .ssh)
        gamma.group = "Archive/Gamma"
        let reordered = try SelectiveRemoteHostFolderOrganizer.move(
            profiles: [alpha, beta, gamma], folder: "Ops/Beta",
            toParent: "Ops", before: "Ops/Alpha"
        )
        let ops = try #require(SelectiveRemoteProfileFolderNode.roots(from: [
            .init(name: "Ops", profiles: reordered.filter { $0.group.hasPrefix("Ops/") })
        ]).first)
        #expect(ops.children.map(\.path) == ["Ops/Beta", "Ops/Alpha"])
        #expect(SelectiveRemoteHostFolderOrganizer.folderComesBefore(
            "Ops/Beta", "Ops/Alpha", profiles: reordered
        ))

        let moved = try SelectiveRemoteHostFolderOrganizer.move(
            profiles: reordered, folder: "Ops/Beta", toParent: "Archive/Gamma"
        )
        #expect(moved.first(where: { $0.id == beta.id })?.group == "Archive/Gamma/Beta")
        #expect(SelectiveRemoteHostFolderOrganizer.visibleFolderPaths(profiles: moved)
            .contains("Archive"))
        let restored = try JSONDecoder().decode(
            [ConnectionProfile].self, from: JSONEncoder().encode(moved)
        )
        #expect(restored == moved)
        #expect(throws: SelectiveRemoteHostFolderOrganizer.Error.self) {
            try SelectiveRemoteHostFolderOrganizer.move(
                profiles: moved, folder: "Archive/Gamma",
                toParent: "Archive/Gamma/Beta"
            )
        }
    }

    @Test("Host drag reorders and moves without crossing an unrelated target")
    func hostDragOrderPlanner() throws {
        var first = ConnectionProfile(connectionType: .ssh)
        first.group = "Ops"
        first.sortIndex = 0
        var second = ConnectionProfile(connectionType: .ssh)
        second.group = "Ops"
        second.sortIndex = 1
        var target = ConnectionProfile(connectionType: .ssh)
        target.group = "Dev"
        target.sortIndex = 0
        let input = [first, second, target]
        let reordered = try #require(SelectiveRemoteHostOrder.move(
            profiles: input, profileID: second.id, toFolder: "Ops", before: first.id
        ))
        #expect(reordered.first(where: { $0.id == second.id })?.sortIndex == 0)
        #expect(reordered.first(where: { $0.id == first.id })?.sortIndex == 1)
        #expect(SelectiveRemoteHostOrder.move(
            profiles: reordered, profileID: second.id, toFolder: "Ops", before: second.id
        ) == nil)
        #expect(SelectiveRemoteHostOrder.move(
            profiles: reordered, profileID: second.id, toFolder: "Ops", before: target.id
        ) == nil)
        let moved = try #require(SelectiveRemoteHostOrder.move(
            profiles: reordered, profileID: second.id, toFolder: "Dev", before: target.id
        ))
        #expect(moved.first(where: { $0.id == second.id })?.group == "Dev")
        #expect(moved.first(where: { $0.id == second.id })?.sortIndex == 0)
        #expect(moved.first(where: { $0.id == target.id })?.sortIndex == 1)
        #expect(try JSONDecoder().decode(
            [ConnectionProfile].self, from: JSONEncoder().encode(moved)
        ) == moved)
    }

    @Test("Названия пользовательских тегов нормализуются и ограничиваются")
    func customTagNamesAreNormalized() {
        #expect(AppModel.normalizedProfileTagName("  production   servers  ") == "production servers")
        #expect(AppModel.normalizedProfileTagName("\n\t") == "")
        #expect(AppModel.normalizedProfileTagName(String(repeating: "a", count: 40)).count == 32)
    }

    @MainActor
    @Test("Журнал хранит только очищенные метаданные и завершает активную запись")
    func activityStoreSanitizesAndFinishesRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectiveRemoteActivityTests-\(UUID().uuidString)")
        let storageURL = root.appendingPathComponent("activity.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConnectionActivityStore(storageURL: storageURL)
        let id = store.begin(
            kind: .ssh,
            profileID: UUID(),
            profileName: "Production",
            target: "server.example.test:22",
            route: "bastion.example.test"
        )
        store.finish(
            id,
            outcome: .failed,
            errorMessage: "token=super-secret password=hunter2"
        )

        let record = try #require(store.records.first)
        #expect(record.outcome == .failed)
        #expect(record.endedAt != nil)
        #expect(record.errorMessage?.contains("super-secret") == false)
        #expect(record.errorMessage?.contains("hunter2") == false)
        #expect(record.errorMessage?.contains("<redacted>") == true)

        let restored = ConnectionActivityStore(storageURL: storageURL)
        #expect(restored.records == store.records)
    }

    @Test("App Lock и каталог подключений встроены в приложение")
    func appLockAndProfileCollectionAreWired() throws {
        let app = try source("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        let lock = try source("Sources/SelectiveRemote/AppLock.swift")
        let content = try source("Sources/SelectiveRemote/ContentView.swift")

        #expect(app.components(separatedBy: "AppLockGate(store: appLock)").count == 3)
        #expect(app.contains("UpdateLocalization.key(\"menu.session.lock\")"))
        #expect(UpdateLocalization.key("menu.session.lock", english: false) == "Заблокировать Selective Remote")
        #expect(UpdateLocalization.key("menu.session.lock", english: true) == "Lock Selective Remote")
        #expect(app.contains("if appLock.isLocked"))
        #expect(lock.contains("deviceOwnerAuthenticationWithBiometrics"))
        #expect(lock.contains("try await context.evaluatePolicy"))
        #expect(lock.contains("disableWithSystemAuthentication"))
        #expect(lock.contains("if !value, enabled, isLocked"))
        #expect(lock.contains(".disabled(store.isLocked)"))
        #expect(!lock.contains(") { [weak self] success, error in"))
        #expect(lock.contains("NSWorkspace.didWakeNotification"))
        #expect(content.contains("ProfileCollectionDisplayMode"))
        #expect(content.contains("min: 260"))
        #expect(content.contains("ideal: 300"))
        #expect(content.contains("max: 380"))
        #expect(!content.contains("ideal: showsHostQuickAccess"))
        #expect(content.contains("GridItem(.adaptive(minimum: 100)"))
        #expect(content.contains("Создать свой тег"))
        #expect(content.contains("ConnectionActivityView"))
        #expect(content.contains(".draggable(\"personal-host:"))
        #expect(content.contains("movePersonalProfile"))
    }
}
