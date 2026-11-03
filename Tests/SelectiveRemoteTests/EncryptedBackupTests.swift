import Foundation
import Testing
@testable import SelectiveRemote

@Test("Encrypted backup round-trips its binary manifest")
func encryptedBackupManifestRoundTrip() throws {
    let suiteName = "SelectiveRemote.BackupTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var profile = ConnectionProfile()
    profile.friendlyName = "Backup profile"
    defaults.set(
        try JSONEncoder().encode([profile]),
        forKey: "SelectiveRemote.connectionProfiles.v2"
    )
    defaults.set("ignored", forKey: "Unrelated.application.value")

    let service = SelectiveRemoteBackupService(defaults: defaults)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemote-BackupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("test.srbackup")
    let options = SelectiveRemoteBackupOptions(
        includeCredentials: false,
        includePrivateKeys: false,
        includeSessionLogs: false,
        includeConnectionActivity: false
    )

    let exported = try service.exportArchive(
        to: archive,
        password: "correct horse battery staple",
        options: options
    )
    let inspected = try service.inspectArchive(
        at: archive,
        password: "correct horse battery staple"
    )

    #expect(exported.profileCount == 1)
    #expect(inspected.summary == exported)
    let bytes = try Data(contentsOf: archive)
    #expect(bytes.starts(with: Data("SRBACKUP".utf8)))
    #expect((try? JSONSerialization.jsonObject(with: bytes)) == nil)
}

@Test("Restoring an older backup preserves the legacy profiles and restores only the new namespace")
func backupRestorePreservesLegacyProfileStore() throws {
    let suite = "SelectiveRemote.BackupIsolation.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SR-Backup-Isolation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldKey = "SelectiveRemote.connectionProfiles.v2"
    let newKey = try #require(NativeStorageMigration.newKey(for: oldKey))
    var initial = ConnectionProfile()
    initial.friendlyName = "TEST-ONLY-BEFORE"
    let initialData = try JSONEncoder().encode([initial])
    defaults.set(initialData, forKey: oldKey)
    let service = SelectiveRemoteBackupService(defaults: defaults, exportCredentials: { [:] },
        replaceCredentials: { _ in }, supportOverride: directory, requireRestoreQuiescence: {}, migrateCredentials: {})
    let archive = directory.appendingPathComponent("fixture.srbackup")
    let options = SelectiveRemoteBackupOptions(includeCredentials: false, includePrivateKeys: false,
        includeSessionLogs: false, includeConnectionActivity: false)
    _ = try service.exportArchive(to: archive, password: "test-only-password", options: options)
    try NativeStorageMigration.prepare(defaults)
    var legacyEdit = initial
    legacyEdit.friendlyName = "TEST-ONLY-LEGACY-EDIT"
    let legacyData = try JSONEncoder().encode([legacyEdit])
    defaults.set(legacyData, forKey: oldKey)
    var newEdit = initial
    newEdit.friendlyName = "TEST-ONLY-NEW-EDIT"
    defaults.set(try JSONEncoder().encode([newEdit]), forKey: newKey)
    let result = try service.restoreArchive(at: archive, password: "test-only-password")
    #expect(defaults.data(forKey: oldKey) == legacyData)
    #expect(defaults.data(forKey: newKey) == initialData)
    #expect(FileManager.default.fileExists(atPath: result.rollbackURL.path))
    try NativeStorageMigration.prepare(defaults)
    #expect(defaults.data(forKey: newKey) == initialData)
}

@Test("A backup with incompatible shared settings fails before changing any data")
func backupRestoreRejectsSharedSettingsBeforeMutation() throws {
    let suite = "SelectiveRemote.BackupPreflight.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SR-Backup-Preflight-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldKey = "SelectiveRemote.connectionProfiles.v2"
    var profile = ConnectionProfile()
    profile.friendlyName = "TEST-ONLY-RETAIN"
    let oldData = try JSONEncoder().encode([profile])
    defaults.set(oldData, forKey: oldKey)
    defaults.set("old", forKey: "SelectiveRemote.fixture.shared")
    let service = SelectiveRemoteBackupService(defaults: defaults, exportCredentials: { [:] },
        replaceCredentials: { _ in Issue.record("Preflight must not replace credentials") },
        supportOverride: directory, requireRestoreQuiescence: {}, migrateCredentials: {})
    let archive = directory.appendingPathComponent("fixture.srbackup")
    let options = SelectiveRemoteBackupOptions(includeCredentials: false, includePrivateKeys: false,
        includeSessionLogs: false, includeConnectionActivity: false)
    _ = try service.exportArchive(to: archive, password: "test-only-password", options: options)
    try NativeStorageMigration.prepare(defaults)
    defaults.set("new", forKey: "SelectiveRemote.fixture.shared")
    let newKey = try #require(NativeStorageMigration.newKey(for: oldKey))
    let before = defaults.data(forKey: newKey)
    #expect(throws: SelectiveRemoteBackupError.unsafeSharedRestore) {
        try service.restoreArchive(at: archive, password: "test-only-password")
    }
    #expect(defaults.string(forKey: "SelectiveRemote.fixture.shared") == "new")
    #expect(defaults.data(forKey: oldKey) == oldData)
    #expect(defaults.data(forKey: newKey) == before)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path))
}

@Test("Credential backup restore fails closed before changing either Keychain or defaults")
func backupRestoreRejectsCredentialMutationUntilAtomicRecovery() throws {
    let suite = "SelectiveRemote.BackupCredentialPreflight.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SR-Backup-Credential-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var replaced = false
    let service = SelectiveRemoteBackupService(defaults: defaults,
        exportCredentials: { ["test-only": "synthetic"] }, replaceCredentials: { _ in replaced = true },
        supportOverride: directory, requireRestoreQuiescence: {}, migrateCredentials: {})
    let archive = directory.appendingPathComponent("credential.srbackup")
    let options = SelectiveRemoteBackupOptions(includeCredentials: true, includePrivateKeys: false,
        includeSessionLogs: false, includeConnectionActivity: false)
    _ = try service.exportArchive(to: archive, password: "test-only-password", options: options)
    #expect(throws: SelectiveRemoteBackupError.unsafeSharedRestore) {
        try service.restoreArchive(at: archive, password: "test-only-password")
    }
    #expect(!replaced)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path))
}

@Test("Production restore is disabled until application writes are quiesced")
func backupRestoreRequiresProductionQuiescence() throws {
    let suite = "SelectiveRemote.BackupQuiescence.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SR-Backup-Quiescence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = SelectiveRemoteBackupService(defaults: defaults, exportCredentials: { [:] },
        replaceCredentials: { _ in Issue.record("Disabled restore must not write credentials") },
        supportOverride: directory, migrateCredentials: {})
    let archive = directory.appendingPathComponent("fixture.srbackup")
    let options = SelectiveRemoteBackupOptions(includeCredentials: false, includePrivateKeys: false,
        includeSessionLogs: false, includeConnectionActivity: false)
    _ = try service.exportArchive(to: archive, password: "test-only-password", options: options)
    #expect(throws: SelectiveRemoteBackupError.restoreTemporarilyUnavailable) {
        try service.restoreArchive(at: archive, password: "test-only-password")
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path))
}

@Test("Encrypted backup rejects a wrong password and short passwords")
func encryptedBackupRejectsInvalidPasswords() throws {
    let suiteName = "SelectiveRemote.BackupTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let service = SelectiveRemoteBackupService(defaults: defaults)
    let archive = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemote-\(UUID().uuidString).srbackup")
    defer { try? FileManager.default.removeItem(at: archive) }
    let options = SelectiveRemoteBackupOptions(
        includeCredentials: false,
        includePrivateKeys: false,
        includeSessionLogs: false,
        includeConnectionActivity: false
    )

    #expect(throws: SelectiveRemoteBackupError.self) {
        try service.exportArchive(to: archive, password: "too short", options: options)
    }
    _ = try service.exportArchive(
        to: archive,
        password: "correct horse battery staple",
        options: options
    )
    #expect(throws: SelectiveRemoteBackupError.self) {
        try service.inspectArchive(at: archive, password: "incorrect password value")
    }
}

@Test("Backup settings expose full secret archive and guarded restore")
func backupSettingsExposeFullArchive() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let settings = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/BackupSettingsView.swift"),
        encoding: .utf8
    )
    let crypto = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/EncryptedBackup.swift"),
        encoding: .utf8
    )

    #expect(settings.contains("Пароли и другие записи Keychain"))
    #expect(settings.contains("Приватные SSH-ключи и SSH CA"))
    #expect(settings.contains("Session Logs"))
    #expect(settings.contains("KeychainService.authenticateDeviceOwner"))
    #expect(crypto.contains("PBKDF2"))
    #expect(crypto.contains("AES.GCM"))
}
