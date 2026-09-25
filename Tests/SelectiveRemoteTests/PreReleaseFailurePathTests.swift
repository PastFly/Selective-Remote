import Foundation
import Testing
@testable import SelectiveRemote

private enum InjectedKeychainFailure: Error {
    case denied
}

@Suite(.serialized)
@MainActor
struct PreReleaseProfileDeletionTests {
    @Test("Keychain deletion failure preserves profile references and does not report success")
    func failedKeychainDeletion() {
        let model = AppModel()
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.friendlyName = "Retained host"
        let another = ConnectionProfile(connectionType: .ssh)
        model.profiles = [profile, another]
        model.selectedProfileID = profile.id
        model.statusMessage = "Before deletion"
        var onePasswordWasRemoved = false
        model.deleteProfilePasswords = { id in
            #expect(id == profile.id)
            onePasswordWasRemoved = true
            throw InjectedKeychainFailure.denied
        }

        model.deleteSelectedProfile()

        #expect(onePasswordWasRemoved)
        #expect(model.profiles.map(\.id) == [profile.id, another.id])
        #expect(model.selectedProfileID == profile.id)
        #expect(model.statusMessage == "Before deletion")
        #expect(model.errorMessage != nil)
    }

    @Test("Successful Keychain cleanup still removes the selected profile")
    func successfulKeychainDeletion() {
        let model = AppModel()
        let profile = ConnectionProfile(connectionType: .ssh)
        let another = ConnectionProfile(connectionType: .ssh)
        model.profiles = [profile, another]
        model.selectedProfileID = profile.id
        model.deleteProfilePasswords = { id in #expect(id == profile.id) }

        model.deleteSelectedProfile()

        #expect(model.profiles.map(\.id) == [another.id])
        #expect(model.selectedProfileID == another.id)
        #expect(model.errorMessage == nil)
    }
}

@Test("Credential-inclusive backup aborts when legacy migration fails")
func failedCredentialMigrationAbortsBackup() throws {
    let suiteName = "SelectiveRemote.BackupFailureTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.friendlyName = "Retained host"
    let profileData = try JSONEncoder().encode([profile])
    defaults.set(profileData, forKey: "SelectiveRemote.connectionProfiles.v2")

    let archive = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemote-BackupFailure-\(UUID().uuidString).srbackup")
    defer { try? FileManager.default.removeItem(at: archive) }
    let previousArchive = Data("previous verified archive".utf8)
    try previousArchive.write(to: archive)
    let service = SelectiveRemoteBackupService(defaults: defaults) {
        throw InjectedKeychainFailure.denied
    }
    let options = SelectiveRemoteBackupOptions(
        includeCredentials: true,
        includePrivateKeys: false,
        includeSessionLogs: false,
        includeConnectionActivity: false
    )

    #expect(throws: InjectedKeychainFailure.self) {
        try service.exportArchive(
            to: archive,
            password: "correct horse battery staple",
            options: options
        )
    }
    #expect(try Data(contentsOf: archive) == previousArchive)
    #expect(defaults.data(forKey: "SelectiveRemote.connectionProfiles.v2") == profileData)
}
