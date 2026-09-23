import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Cloud runtime localization", .serialized)
struct CloudRuntimeLocalizationTests {
    @Test("Personal Vault sync persists a language-neutral known error")
    func persistsKnownErrorCode() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let defaults = UserDefaults.standard
        let languageKey = "SelectiveRemote.applicationLanguage.v1"
        let previousLanguage = defaults.object(forKey: languageKey)
        let previousError = defaults.object(forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey)
        defer {
            if let previousLanguage { defaults.set(previousLanguage, forKey: languageKey) }
            else { defaults.removeObject(forKey: languageKey) }
            if let previousError { defaults.set(previousError, forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey) }
            else { defaults.removeObject(forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey) }
        }

        defaults.set("russian", forKey: languageKey)
        SelectiveRemotePersonalVaultSyncStatus.recordError(SelectiveRemotePersonalVaultError.emptyLocalVault)
        #expect(defaults.string(forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey) == "personalVault.emptyLocalVault")
        #expect(SelectiveRemotePersonalVaultSyncStatus.message(for: defaults.string(forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey) ?? "") == "На этом Mac нет заполненных Hosts, Snippets или Forwarding для отправки.")

        defaults.set("english", forKey: languageKey)
        #expect(SelectiveRemotePersonalVaultSyncStatus.message(for: defaults.string(forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey) ?? "") == "This Mac has no populated Hosts, Snippets or Forwarding records to upload.")

        SelectiveRemotePersonalVaultSyncStatus.recordError(SelectiveRemotePersonalVaultError.uploadConflict(7))
        #expect(defaults.string(forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey) == "personalVault.uploadConflict:7")
        defaults.set("russian", forKey: languageKey)
        #expect(SelectiveRemotePersonalVaultSyncStatus.message(for: defaults.string(forKey: SelectiveRemotePersonalVaultSyncStatus.errorKey) ?? "") == "Cloud Vault изменился до ревизии 7. Локальные данные не перезаписаны.")
    }

    @Test("Team status re-renders after RU to EN switch")
    func teamStatusRendersCurrentLanguage() {
        #expect(SelectiveRemoteCloudTeamStatus.teamCreated.message(english: false) == "Team создана.")
        #expect(SelectiveRemoteCloudTeamStatus.teamCreated.message(english: true) == "Team created.")
        #expect(SelectiveRemoteCloudTeamStatus.synchronized(received: 2, uploaded: 1, granted: 3).message(english: false) == "Team Vaults синхронизированы: получено 2, отправлено 1, предоставлено доступов 3.")
        #expect(SelectiveRemoteCloudTeamStatus.synchronized(received: 2, uploaded: 1, granted: 3).message(english: true) == "Team Vaults synchronized: 2 received, 1 uploaded, 3 access grants.")
    }
}
