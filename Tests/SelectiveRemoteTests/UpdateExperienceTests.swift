import Foundation
import Testing
@testable import SelectiveRemote

struct UpdateExperienceTests {
    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func notificationPolicyNotifiesForANewVersion() {
        #expect(UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: nil,
            lastVersion: "0.21.4",
            lastDate: Date(),
            now: Date()
        ))
    }

    @Test func notificationPolicySuppressesRepeatedNotificationWithinADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: nil,
            lastVersion: "0.21.5",
            lastDate: now.addingTimeInterval(-60 * 60),
            now: now
        ))
    }

    @Test func notificationPolicyAllowsSameVersionAfterADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: nil,
            lastVersion: "0.21.5",
            lastDate: now.addingTimeInterval(-(25 * 60 * 60)),
            now: now
        ))
    }

    @Test func notificationPolicySuppressesVersionAlreadySeenInUpdateUI() {
        #expect(!UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: "0.21.5",
            lastVersion: "0.21.4",
            lastDate: nil,
            now: Date()
        ))
    }

    @Test("Manual update download uses a native save panel and keeps Settings open")
    func manualUpdateDestinationAndProgressRegression() throws {
        let model = try repositorySource("Sources/SelectiveRemote/AppModel.swift")
        let installer = try repositorySource("Sources/SelectiveRemote/UpdateInstaller.swift")
        let view = try repositorySource("Sources/SelectiveRemote/UpdateExperienceView.swift")
        let app = try repositorySource("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        let strings = try repositorySource("Resources/en.lproj/Localizable.strings")

        #expect(model.contains("func downloadAvailableUpdateChoosingDestination()"))
        #expect(model.contains("let panel = NSSavePanel()"))
        #expect(model.contains("panel.allowedContentTypes = [.diskImage]"))
        #expect(model.contains("downloadedUpdateUsesCustomDestination = userSelectedDestination"))
        #expect(model.contains("func chooseAutomaticUpdateDownloadDirectory()"))
        #expect(model.contains("SelectiveRemote.update.autoDownloadDirectory.v1"))
        #expect(model.contains("destinationURL != nil"))
        #expect(installer.contains("destinationURL requestedDestinationURL: URL? = nil"))
        #expect(installer.contains("requestedDestinationURL.standardizedFileURL"))
        #expect(view.contains("Button(\"Сохранить DMG…\")"))
        #expect(view.contains("Пользовательский каталог · DMG сохраняется после установки"))
        #expect(view.contains("Место автоматической загрузки"))
        #expect(view.contains("Использовать системный каталог"))
        #expect(model.contains("retention: downloadedUpdateUsesCustomDestination"))
        #expect(installer.contains("if [ \"$CLEANUP_DMG\" = \"1\" ]; then"))
        #expect(app.contains("preventsClosing: model.isUpdateOperationInProgress"))
        for key in [
            "Автоматически загружать найденные обновления",
            "Место автоматической загрузки",
            "Выбрать пользовательский каталог…",
            "Использовать системный каталог"
        ] {
            #expect(strings.contains("\"\(key)\" ="))
        }
    }

    @Test("Only updater-managed DMGs are removed after installation")
    func updateDMGRetentionPolicy() {
        #expect(UpdateDMGRetention.removeAfterInstallation.removesDMG)
        #expect(!UpdateDMGRetention.keepAfterInstallation.removesDMG)
    }
}
