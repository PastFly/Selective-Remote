import Foundation

/// Refuse to open stores whose copied records cannot be decoded by this build.
enum NativeStorageValidation {
    private static let legacyProfileConsumedKey = "SelectiveRemote.native032.legacy-profile-consumed.v1"

    static func finishLegacyProfileMigration(_ defaults: UserDefaults) throws {
        if let marker = defaults.object(forKey: legacyProfileConsumedKey) {
            guard marker as? Bool == true else { throw NativeStorageMigration.MigrationError.inconsistentCheckpoint }
            return
        }
        let profilesKey = NativeStorageMigration.newKey(for: "SelectiveRemote.connectionProfiles.v2")!
        let legacyKey = NativeStorageMigration.newKey(for: "SelectiveRemote.connectionProfile.v1")!
        if defaults.object(forKey: profilesKey) == nil, let data = defaults.data(forKey: legacyKey) {
            let legacy = try JSONDecoder().decode(LegacyConnectionProfile.self, from: data)
            var migrated = ConnectionProfile()
            migrated.friendlyName = legacy.host.isEmpty
                ? UpdateLocalization.text(ru: "Первое подключение", en: "First Connection") : legacy.host
            migrated.host = legacy.host
            migrated.username = legacy.username
            migrated.selectedDisplayIDs = legacy.selectedDisplayIDs
            migrated.primaryDisplayID = legacy.primaryDisplayID
            let encoded = try JSONEncoder().encode([migrated])
            defaults.set(encoded, forKey: profilesKey)
            guard defaults.synchronize(), defaults.data(forKey: profilesKey) == encoded else {
                throw NativeStorageMigration.MigrationError.incompleteWrite
            }
        }
        defaults.set(true, forKey: legacyProfileConsumedKey)
        guard defaults.synchronize(), defaults.object(forKey: legacyProfileConsumedKey) as? Bool == true else {
            throw NativeStorageMigration.MigrationError.incompleteWrite
        }
    }

    static func validate(_ defaults: UserDefaults) throws {
        try validate(defaults.dictionaryRepresentation())
    }

    static func validate(_ values: [String: Any]) throws {
        try decode([ConnectionProfile].self, "SelectiveRemote.connectionProfiles.v2", values)
        try decode(LegacyConnectionProfile.self, "SelectiveRemote.connectionProfile.v1", values)
        try decode([SSHKeyRecord].self, "SelectiveRemote.sshKeys.v1", values)
        try decode([IndependentPortForward].self, "SelectiveRemote.independentPortForwards.v1", values)
        try decode([TerminalCommandTemplate].self, "SelectiveRemote.terminal.commandTemplates.v1", values)
        try decode([TerminalSnippetGroup].self, "SelectiveRemote.terminal.snippetGroups.v1", values)
        try decode([TerminalStartupSnippetSequenceRecord].self, "SelectiveRemote.terminal.startupSnippetSequences.v1", values)
        try decode([TerminalHistoryEntry].self, "SelectiveRemote.terminal.commandHistory.v1", values)
        try decode([TerminalCommandFavorite].self, "SelectiveRemote.terminal.commandFavorites.v1", values)
        try decode([NamedTerminalWorkspace].self, "SelectiveRemote.terminal.namedWorkspaces.v1", values)
        try decode([SSHCertificateAuthorityRecord].self, "SelectiveRemote.sshCertificateAuthorities.v1", values)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ oldKey: String, _ values: [String: Any]) throws {
        let key = NativeStorageMigration.newKey(for: oldKey)!
        guard let value = values[key] else { return }
        guard let data = value as? Data else { throw NativeStorageMigration.MigrationError.invalidSource }
        do { _ = try JSONDecoder().decode(type, from: data) }
        catch { throw NativeStorageMigration.MigrationError.invalidSource }
    }
}
