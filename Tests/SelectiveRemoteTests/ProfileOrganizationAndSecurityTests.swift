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

        #expect(app.contains("AppLockGate(store: appLock)"))
        #expect(app.contains("Заблокировать Selective Remote"))
        #expect(lock.contains("deviceOwnerAuthenticationWithBiometrics"))
        #expect(lock.contains("NSWorkspace.didWakeNotification"))
        #expect(content.contains("ProfileCollectionDisplayMode"))
        #expect(content.contains("Создать свой тег"))
        #expect(content.contains("ConnectionActivityView"))
    }
}
