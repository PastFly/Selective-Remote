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
