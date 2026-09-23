import Foundation
import Security
import Testing
@testable import SelectiveRemote

@Suite("Runtime error localization", .serialized)
struct RuntimeErrorLocalizationTests {
    @Test("Update, transfer, backup, camera, and Keychain errors follow app language")
    func errorDescriptionsFollowAppLanguage() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let defaults = UserDefaults.standard
        let key = "SelectiveRemote.applicationLanguage.v1"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.set("russian", forKey: key)
        #expect(UpdateServiceError.invalidResponse.errorDescription == "Сервер обновлений вернул некорректный ответ")
        #expect(ProfileTransferError.unsupportedFormat.errorDescription == "Неподдерживаемый формат профилей")
        #expect(SelectiveRemoteBackupError.unsupportedVersion(5).errorDescription == "Версия архива 5 пока не поддерживается.")
        #expect(CameraPreviewFailure.permissionDenied.errorDescription == "macOS не разрешила доступ к камере. Включите его в системных настройках.")
        #expect(KeychainError.unexpectedStatus(errSecMissingEntitlement).errorDescription == "Keychain не разрешил доступ к старой записи (-34018). Нажмите «Восстановить доступ» рядом с SSH-паролем и сохраните пароль заново.")

        defaults.set("english", forKey: key)
        #expect(UpdateServiceError.invalidResponse.errorDescription == "The update server returned an invalid response.")
        #expect(ProfileTransferError.unsupportedFormat.errorDescription == "Unsupported profile format")
        #expect(SelectiveRemoteBackupError.unsupportedVersion(5).errorDescription == "Archive version 5 is not supported yet.")
        #expect(CameraPreviewFailure.permissionDenied.errorDescription == "macOS denied camera access. Enable it in System Settings.")
        #expect(KeychainError.unexpectedStatus(errSecMissingEntitlement).errorDescription == "Keychain denied access to the old item (-34018). Select Restore Access next to the SSH password and save the password again.")
    }

    @Test("Dynamic backup path and camera detail remain exact user or system data")
    func dynamicDetailsRemainExact() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let defaults = UserDefaults.standard
        let key = "SelectiveRemote.applicationLanguage.v1"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set("english", forKey: key)

        #expect(SelectiveRemoteBackupError.missingFile("/tmp/example file").errorDescription == "Backup file is unavailable: /tmp/example file")
        #expect(CameraPreviewFailure.inputCreation("device reason").errorDescription == "Could not open camera: device reason")
    }
}
