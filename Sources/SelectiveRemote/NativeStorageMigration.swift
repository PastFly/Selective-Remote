import Foundation
import CryptoKit

protocol NativePreferencesAccess {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func synchronize() -> Bool
    func dictionaryRepresentation() -> [String: Any]
}
extension UserDefaults: NativePreferencesAccess {}

/// Copy-on-write namespace for collections that 0.31 saves as whole snapshots.
/// Call before opening any collection, while holding the current-app lease.
enum NativeStorageMigration {
    enum MigrationError: Error { case invalidSource, incompleteWrite, inconsistentCheckpoint, unsafeRestore }
    private static let prefix = "SelectiveRemote."
    private static let versionPrefix = "SelectiveRemote.native032."
    private static let snapshotKey = versionPrefix + "migration.snapshot.v1"
    private static let markerKey = versionPrefix + "migration.complete.v1"
    private static let restoreJournalKey = versionPrefix + "restore.pending.v1"
    private static let snippetJournalKey = versionPrefix + "snippets.pending.v1"
    private static let snippetGroupsLegacyKey = "SelectiveRemote.terminal.snippetGroups.v1"
    private static let snippetTemplatesLegacyKey = "SelectiveRemote.terminal.commandTemplates.v1"
    private static let workspacePrefix = prefix + "terminal.workspace.v1."
    private static let versionedWorkspacePrefix = versionPrefix + "terminal.workspace.v1."
    private static let workspaceSnapshotKey = versionPrefix + "workspace-migration.snapshot.v1"
    private static let workspaceMarkerKey = versionPrefix + "workspace-migration.complete.v1"
    private static let ignoredBackupMetadata: Set<String> = [
        "SelectiveRemote.keychain.unifiedVault.index.v1", "SelectiveRemote.keychain.unifiedVault.index.v2",
        "SelectiveRemote.keychain.unifiedVault.suppressedLegacy.v1"
    ]
    private static let legacyKeys: [String] = [
        "SelectiveRemote.connectionProfiles.v2", "SelectiveRemote.connectionProfile.v1",
        "SelectiveRemote.selectedProfileID.v2", "SelectiveRemote.sshKeys.v1",
        "SelectiveRemote.independentPortForwards.v1", "SelectiveRemote.terminal.commandTemplates.v1",
        "SelectiveRemote.terminal.snippetGroups.v1", "SelectiveRemote.terminal.startupSnippetSequences.v1",
        "SelectiveRemote.terminal.commandHistory.v1", "SelectiveRemote.terminal.commandHistory.enabled.v1",
        "SelectiveRemote.terminal.commandFavorites.v1", "SelectiveRemote.terminal.namedWorkspaces.v1",
        "SelectiveRemote.sshCertificateAuthorities.v1",
        "SelectiveRemote.storedPasswordProfiles.v1", "SelectiveRemote.storedGatewayPasswordProfiles.v1",
        "SelectiveRemote.storedSSHPasswordProfiles.v1", "SelectiveRemote.sshPasswordUserPresenceProfiles.v1",
        "SelectiveRemote.sshKeyUserPresenceProfiles.v1", "SelectiveRemote.storedForwardingPasswordIDs.v1",
        "SelectiveRemote.forwardingPasswordUserPresenceIDs.v1", "SelectiveRemote.storedSSHKeyPassphrases.v1"
    ]
    private static let arrayDataKeys: Set<String> = [
        "SelectiveRemote.connectionProfiles.v2", "SelectiveRemote.sshKeys.v1",
        "SelectiveRemote.independentPortForwards.v1", "SelectiveRemote.terminal.commandTemplates.v1",
        "SelectiveRemote.terminal.snippetGroups.v1", "SelectiveRemote.terminal.startupSnippetSequences.v1",
        "SelectiveRemote.terminal.commandHistory.v1", "SelectiveRemote.terminal.commandFavorites.v1",
        "SelectiveRemote.terminal.namedWorkspaces.v1", "SelectiveRemote.sshCertificateAuthorities.v1"
    ]
    private static let stringArrayKeys: Set<String> = [
        "SelectiveRemote.storedPasswordProfiles.v1", "SelectiveRemote.storedGatewayPasswordProfiles.v1",
        "SelectiveRemote.storedSSHPasswordProfiles.v1", "SelectiveRemote.sshPasswordUserPresenceProfiles.v1",
        "SelectiveRemote.sshKeyUserPresenceProfiles.v1", "SelectiveRemote.storedForwardingPasswordIDs.v1",
        "SelectiveRemote.forwardingPasswordUserPresenceIDs.v1", "SelectiveRemote.storedSSHKeyPassphrases.v1"
    ]
    private static let userPresenceKeys: [String] = [
        "SelectiveRemote.sshPasswordUserPresenceProfiles.v1", "SelectiveRemote.sshKeyUserPresenceProfiles.v1",
        "SelectiveRemote.forwardingPasswordUserPresenceIDs.v1"
    ]

    static func newKey(for old: String) -> String? {
        guard legacyKeys.contains(old), old.hasPrefix(prefix) else { return nil }
        return versionPrefix + old.dropFirst(prefix.count)
    }

    static var versionedKeys: [String] { legacyKeys.compactMap { newKey(for: $0) } }

    /// Return the legacy Host data at migration and now, without mutating it.
    static func legacyProfileData(_ defaults: any NativePreferencesAccess) throws -> [(Data?, Data?)] {
        guard defaults.synchronize(), let bytes = defaults.object(forKey: snapshotKey) as? Data,
              defaults.object(forKey: markerKey) as? String == "complete:" + digest(bytes)
        else { throw MigrationError.inconsistentCheckpoint }
        let snapshot = try decodeSnapshot(bytes)
        return try ["SelectiveRemote.connectionProfiles.v2", "SelectiveRemote.connectionProfile.v1"].map { key in
            let original = snapshot[key], current = defaults.object(forKey: key)
            guard original == nil || original is Data, current == nil || current is Data else {
                throw MigrationError.invalidSource
            }
            return (original as? Data, current as? Data)
        }
    }

    static func workspaceKey(for profileID: UUID) -> String {
        versionedWorkspacePrefix + profileID.uuidString
    }

    /// Dynamic workspace keys need their own durable checkpoint: copying them
    /// lazily would resurrect a workspace deleted by the new version.
    static func prepareWorkspaces(_ defaults: any NativePreferencesAccess) throws {
        func source() throws -> [String: Any] {
            let values = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(workspacePrefix) }
            for (key, value) in values {
                guard let id = UUID(uuidString: String(key.dropFirst(workspacePrefix.count))),
                      key == workspacePrefix + id.uuidString, let data = value as? Data,
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
                else { throw MigrationError.invalidSource }
            }
            return values
        }
        if let marker = defaults.object(forKey: workspaceMarkerKey) {
            guard let bytes = defaults.object(forKey: workspaceSnapshotKey) as? Data,
                  marker as? String == "complete:" + digest(bytes),
                  (try? decodeEnvelope(bytes)) != nil else { throw MigrationError.inconsistentCheckpoint }
            return
        }
        let snapshot: [String: Any]
        if let entry = defaults.object(forKey: workspaceSnapshotKey) {
            guard let bytes = entry as? Data else { throw MigrationError.inconsistentCheckpoint }
            snapshot = try decodeEnvelope(bytes)
        } else {
            guard defaults.synchronize() else { throw MigrationError.incompleteWrite }
            snapshot = try source()
            guard defaults.synchronize(), NSDictionary(dictionary: snapshot).isEqual(to: try source())
            else { throw MigrationError.inconsistentCheckpoint }
            let bytes = try encodeEnvelope(snapshot)
            defaults.set(bytes, forKey: workspaceSnapshotKey)
            guard defaults.synchronize(), defaults.object(forKey: workspaceSnapshotKey) as? Data == bytes
            else { throw MigrationError.incompleteWrite }
        }
        guard NSDictionary(dictionary: snapshot).isEqual(to: try source()) else { throw MigrationError.inconsistentCheckpoint }
        for (key, value) in snapshot {
            guard key.hasPrefix(workspacePrefix), let id = UUID(uuidString: String(key.dropFirst(workspacePrefix.count))),
                  key == workspacePrefix + id.uuidString else { throw MigrationError.inconsistentCheckpoint }
            let target = workspaceKey(for: id)
            if let existing = defaults.object(forKey: target) {
                guard equal(existing, value) else { throw MigrationError.inconsistentCheckpoint }
            } else { defaults.set(value, forKey: target) }
        }
        guard defaults.synchronize() else { throw MigrationError.incompleteWrite }
        for (key, value) in snapshot {
            guard let id = UUID(uuidString: String(key.dropFirst(workspacePrefix.count))),
                  let actual = defaults.object(forKey: workspaceKey(for: id)), equal(actual, value)
            else { throw MigrationError.incompleteWrite }
        }
        guard let bytes = defaults.object(forKey: workspaceSnapshotKey) as? Data else { throw MigrationError.incompleteWrite }
        let marker = "complete:" + digest(bytes)
        defaults.set(marker, forKey: workspaceMarkerKey)
        guard defaults.synchronize(), defaults.object(forKey: workspaceMarkerKey) as? String == marker
        else { throw MigrationError.incompleteWrite }
    }

    /// Never apply legacy storage names or overwrite the migration checkpoint.
    /// Unisolated preferences must already match, otherwise restoring them could
    /// mutate the 0.31 installation and must be refused before any changes.
    static func restoreValues(_ values: [String: Any], existing: [String: Any]) throws -> [String: Any] {
        let targets = Set(versionedKeys)
        var restored: [String: Any] = [:]
        for old in legacyKeys {
            let target = newKey(for: old)!
            if let current = values[target] {
                try validate(current, for: old)
                restored[target] = current
            } else if let legacy = values[old] {
                try validate(legacy, for: old)
                restored[target] = legacy
            }
        }
        // An archive that lacks a currently used collection cannot prove that
        // deleting it is safe (in particular, Touch ID preference lists).
        for target in targets where existing[target] != nil && restored[target] == nil {
            throw MigrationError.unsafeRestore
        }
        let legacyProfile = newKey(for: "SelectiveRemote.connectionProfile.v1")!
        let profiles = newKey(for: "SelectiveRemote.connectionProfiles.v2")!
        if restored[legacyProfile] != nil && restored[profiles] == nil { throw MigrationError.unsafeRestore }
        for old in userPresenceKeys {
            let target = newKey(for: old)!
            guard let before = existing[target] else { continue }
            guard let current = before as? [String], let after = restored[target] as? [String],
                  Set(current).isSubset(of: Set(after)) else { throw MigrationError.unsafeRestore }
        }
        for (key, value) in values where key.hasPrefix(prefix) {
            if legacyKeys.contains(key) || targets.contains(key) || ignoredBackupMetadata.contains(key) || key == snapshotKey || key == markerKey || key == restoreJournalKey || key == snippetJournalKey { continue }
            guard let current = existing[key], equal(current, value) else { throw MigrationError.unsafeRestore }
        }
        return restored
    }

    static func prepare(_ defaults: any NativePreferencesAccess) throws {
        guard defaults.object(forKey: restoreJournalKey) == nil || defaults.object(forKey: snippetJournalKey) == nil else {
            throw MigrationError.inconsistentCheckpoint
        }
        try recoverPendingRestore(defaults)
        try recoverPendingSnippets(defaults)
        let marker = defaults.object(forKey: markerKey)
        let existingSnapshot = defaults.object(forKey: snapshotKey)
        if marker != nil {
            guard let data = existingSnapshot as? Data,
                  marker as? String == "complete:" + digest(data),
                  (try? decodeSnapshot(data)) != nil else { throw MigrationError.inconsistentCheckpoint }
            for old in legacyKeys {
                if let value = defaults.object(forKey: newKey(for: old)!) { try validate(value, for: old) }
            }
            return
        }
        let snapshot: [String: Any]
        if let existingSnapshot {
            guard let data = existingSnapshot as? Data else { throw MigrationError.inconsistentCheckpoint }
            snapshot = try decodeSnapshot(data)
            guard defaults.synchronize() else { throw MigrationError.incompleteWrite }
            for old in legacyKeys {
                let original = snapshot[old], current = defaults.object(forKey: old)
                guard original == nil ? current == nil : (current != nil && equal(original!, current!))
                else { throw MigrationError.inconsistentCheckpoint }
            }
        } else {
            guard defaults.synchronize() else { throw MigrationError.incompleteWrite }
            var source: [String: Any] = [:]
            for old in legacyKeys {
                guard let value = defaults.object(forKey: old) else { continue }
                try validate(value, for: old)
                source[old] = value
            }
            guard defaults.synchronize() else { throw MigrationError.incompleteWrite }
            for old in legacyKeys {
                let initial = source[old], latest = defaults.object(forKey: old)
                guard initial == nil ? latest == nil : (latest != nil && equal(initial!, latest!))
                else { throw MigrationError.inconsistentCheckpoint }
            }
            let bytes: Data
            do {
                bytes = try encodeEnvelope(source)
            }
            catch { throw MigrationError.invalidSource }
            defaults.set(bytes, forKey: snapshotKey)
            guard defaults.synchronize(), defaults.object(forKey: snapshotKey) as? Data == bytes else { throw MigrationError.incompleteWrite }
            snapshot = source
        }
        for old in legacyKeys {
            let target = newKey(for: old)!
            let existing = defaults.object(forKey: target)
            let value = snapshot[old]
            if let existing {
                guard let value, equal(existing, value) else { throw MigrationError.inconsistentCheckpoint }
            } else if let value {
                defaults.set(value, forKey: target)
            }
        }
        guard defaults.synchronize() else { throw MigrationError.incompleteWrite }
        for old in legacyKeys {
            let value = snapshot[old], written = defaults.object(forKey: newKey(for: old)!)
            guard value == nil ? written == nil : (written != nil && equal(value!, written!)) else { throw MigrationError.incompleteWrite }
        }
        guard let snapshotData = defaults.object(forKey: snapshotKey) as? Data,
              (try? decodeSnapshot(snapshotData)) != nil else { throw MigrationError.inconsistentCheckpoint }
        let complete = "complete:" + digest(snapshotData)
        defaults.set(complete, forKey: markerKey)
        guard defaults.synchronize(), defaults.object(forKey: markerKey) as? String == complete else { throw MigrationError.incompleteWrite }
    }

    private static func decodeSnapshot(_ data: Data) throws -> [String: Any] {
        let values = try decodeEnvelope(data)
        guard values.keys.allSatisfy({ legacyKeys.contains($0) }) else { throw MigrationError.inconsistentCheckpoint }
        return values
    }

    static func applyRestore(_ restored: [String: Any], to defaults: any NativePreferencesAccess) throws {
        let allowed = Set(versionedKeys)
        guard defaults.object(forKey: restoreJournalKey) == nil,
              restored.keys.allSatisfy({ allowed.contains($0) }) else { throw MigrationError.inconsistentCheckpoint }
        var before: [String: Any] = [:]
        for key in versionedKeys { if let value = defaults.object(forKey: key) { before[key] = value } }
        let journal = try encodeEnvelope(before)
        defaults.set(journal, forKey: restoreJournalKey)
        guard defaults.synchronize(), defaults.object(forKey: restoreJournalKey) as? Data == journal else { throw MigrationError.incompleteWrite }
        do {
            try writeVersioned(restored, to: defaults)
            defaults.set(nil, forKey: restoreJournalKey)
            guard defaults.synchronize(), defaults.object(forKey: restoreJournalKey) == nil else { throw MigrationError.incompleteWrite }
        } catch {
            // If immediate recovery also fails, keep the journal: startup must
            // retry recovery before exposing the stores.
            try? recoverPendingRestore(defaults)
            throw error
        }
    }

    /// The journal is committed before either collection is changed. A restart
    /// replays the complete pair while the application's exclusive lease is held.
    static func commitSnippets(groups: Data, templates: Data, to defaults: any NativePreferencesAccess) throws {
        try validate(groups, for: snippetGroupsLegacyKey)
        try validate(templates, for: snippetTemplatesLegacyKey)
        guard defaults.object(forKey: snippetJournalKey) == nil,
              defaults.object(forKey: restoreJournalKey) == nil else { throw MigrationError.inconsistentCheckpoint }
        let values: [String: Any] = [newKey(for: snippetGroupsLegacyKey)!: groups,
                                     newKey(for: snippetTemplatesLegacyKey)!: templates]
        let journal = try encodeEnvelope(values)
        defaults.set(journal, forKey: snippetJournalKey)
        guard defaults.synchronize(), defaults.object(forKey: snippetJournalKey) as? Data == journal else {
            throw MigrationError.incompleteWrite
        }
        try recoverPendingSnippets(defaults)
    }

    static func recoverPendingSnippets(_ defaults: any NativePreferencesAccess) throws {
        guard let entry = defaults.object(forKey: snippetJournalKey) else { return }
        guard defaults.object(forKey: restoreJournalKey) == nil, let data = entry as? Data else {
            throw MigrationError.inconsistentCheckpoint
        }
        let values = try decodeEnvelope(data)
        let groupKey = newKey(for: snippetGroupsLegacyKey)!
        let templateKey = newKey(for: snippetTemplatesLegacyKey)!
        guard values.count == 2, let groups = values[groupKey] as? Data,
              let templates = values[templateKey] as? Data else { throw MigrationError.inconsistentCheckpoint }
        try validate(groups, for: snippetGroupsLegacyKey)
        try validate(templates, for: snippetTemplatesLegacyKey)
        defaults.set(groups, forKey: groupKey)
        defaults.set(templates, forKey: templateKey)
        guard defaults.synchronize(), defaults.object(forKey: groupKey) as? Data == groups,
              defaults.object(forKey: templateKey) as? Data == templates else { throw MigrationError.incompleteWrite }
        defaults.set(nil, forKey: snippetJournalKey)
        guard defaults.synchronize(), defaults.object(forKey: snippetJournalKey) == nil else { throw MigrationError.incompleteWrite }
    }

    private static func recoverPendingRestore(_ defaults: any NativePreferencesAccess) throws {
        guard let entry = defaults.object(forKey: restoreJournalKey) else { return }
        guard let data = entry as? Data else { throw MigrationError.inconsistentCheckpoint }
        let before = try decodeEnvelope(data)
        let allowed = Set(versionedKeys)
        guard before.keys.allSatisfy({ allowed.contains($0) }) else { throw MigrationError.inconsistentCheckpoint }
        try writeVersioned(before, to: defaults)
        defaults.set(nil, forKey: restoreJournalKey)
        guard defaults.synchronize(), defaults.object(forKey: restoreJournalKey) == nil else { throw MigrationError.incompleteWrite }
    }

    private static func writeVersioned(_ values: [String: Any], to defaults: any NativePreferencesAccess) throws {
        for key in versionedKeys { defaults.set(values[key], forKey: key) }
        guard defaults.synchronize() else { throw MigrationError.incompleteWrite }
        for key in versionedKeys {
            let expected = values[key], actual = defaults.object(forKey: key)
            guard expected == nil ? actual == nil : (actual != nil && equal(expected!, actual!)) else { throw MigrationError.incompleteWrite }
        }
    }

    private static func encodeEnvelope(_ values: [String: Any]) throws -> Data {
        let payload = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        return try PropertyListSerialization.data(fromPropertyList: ["payload": payload, "sha256": digest(payload)], format: .binary, options: 0)
    }

    private static func decodeEnvelope(_ data: Data) throws -> [String: Any] {
        guard let envelope = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              envelope.count == 2, let payload = envelope["payload"] as? Data,
              envelope["sha256"] as? String == digest(payload),
              let values = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any]
        else { throw MigrationError.inconsistentCheckpoint }
        return values
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ value: Any, for old: String) throws {
        if arrayDataKeys.contains(old) {
            guard let data = value as? Data,
                  let parsed = try? JSONSerialization.jsonObject(with: data), parsed is [Any]
            else { throw MigrationError.invalidSource }
        }
        if stringArrayKeys.contains(old), !(value is [String]) { throw MigrationError.invalidSource }
        if old == "SelectiveRemote.terminal.commandHistory.enabled.v1", !(value is Bool) { throw MigrationError.invalidSource }
        if old == "SelectiveRemote.selectedProfileID.v2", !(value is String) { throw MigrationError.invalidSource }
        if old == "SelectiveRemote.connectionProfile.v1" {
            guard let data = value as? Data,
                  let parsed = try? JSONSerialization.jsonObject(with: data), parsed is [String: Any]
            else { throw MigrationError.invalidSource }
        }
    }

    private static func equal(_ first: Any, _ second: Any) -> Bool {
        NSDictionary(dictionary: ["value": first]).isEqual(to: ["value": second])
    }
}
