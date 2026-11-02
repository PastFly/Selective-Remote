import Foundation
final class FakePreferences: NativePreferencesAccess {
    var values: [String: Any] = [:]
    var blockedKey: String?
    var flushFails = false
    var failFlushWhenBlockedWrite = false
    var changingKey: String?
    var changedValue: Any?
    var readCount = 0
    func object(forKey key: String) -> Any? {
        if key == changingKey {
            readCount += 1
            if readCount == 2 { values[key] = changedValue }
        }
        return values[key]
    }
    func set(_ value: Any?, forKey key: String) {
        if key == blockedKey { if failFlushWhenBlockedWrite { flushFails = true }; return }
        values[key] = value
    }
    func synchronize() -> Bool { !flushFails }
}
func json(_ values: [String]) throws -> Data { try JSONEncoder().encode(values) }
var failures = 0
func check(_ name: String, _ value: Bool) { print("\(name)=\(value ? "PASS" : "FAIL")"); if !value { failures += 1 } }
let oldHosts = "SelectiveRemote.connectionProfiles.v2"
let oldSnippets = "SelectiveRemote.terminal.commandTemplates.v1"
let oldFavorites = "SelectiveRemote.terminal.commandFavorites.v1"
let oldAuthorities = "SelectiveRemote.sshCertificateAuthorities.v1"
let newHosts = NativeStorageMigration.newKey(for: oldHosts)!
let newSnippets = NativeStorageMigration.newKey(for: oldSnippets)!
let oldData = try json(["original"])
let preferences = FakePreferences()
preferences.set(oldData, forKey: oldHosts)
preferences.set(oldData, forKey: oldSnippets)
preferences.set(oldData, forKey: oldFavorites)
preferences.set(oldData, forKey: oldAuthorities)
try NativeStorageMigration.prepare(preferences)
check("COPY_PRESERVES_SOURCE", preferences.object(forKey: oldHosts) as? Data == oldData && preferences.object(forKey: newHosts) as? Data == oldData && preferences.object(forKey: newSnippets) as? Data == oldData)
check("RELATED_DATA_IS_SEPARATELY_COPIED", preferences.object(forKey: NativeStorageMigration.newKey(for: oldFavorites)!) as? Data == oldData && preferences.object(forKey: NativeStorageMigration.newKey(for: oldAuthorities)!) as? Data == oldData)
let oldEdit = try json(["original", "old-edit"])
let newEdit = try json(["original", "new-edit"])
preferences.set(oldEdit, forKey: oldHosts)
preferences.set(newEdit, forKey: newHosts)
try NativeStorageMigration.prepare(preferences)
check("OLD_AND_NEW_EDITS_SURVIVE_RESTART", preferences.object(forKey: oldHosts) as? Data == oldEdit && preferences.object(forKey: newHosts) as? Data == newEdit)
preferences.values.removeValue(forKey: newSnippets)
try NativeStorageMigration.prepare(preferences)
check("DELETED_NEW_VALUE_IS_NOT_REIMPORTED", preferences.object(forKey: newSnippets) == nil && preferences.object(forKey: oldSnippets) as? Data == oldData)
let alteredSnapshot = try PropertyListSerialization.data(fromPropertyList: [oldHosts: try json(["altered"])], format: .binary, options: 0)
preferences.set(alteredSnapshot, forKey: "SelectiveRemote.native032.migration.snapshot.v1")
var alteredRejected = false
do { try NativeStorageMigration.prepare(preferences) } catch { alteredRejected = true }
check("ALTERED_SNAPSHOT_FAILS_CLOSED", alteredRejected && preferences.object(forKey: newHosts) as? Data == newEdit)
let interrupted = FakePreferences()
interrupted.set(oldData, forKey: oldHosts)
interrupted.blockedKey = newHosts
var rejected = false
do { try NativeStorageMigration.prepare(interrupted) } catch { rejected = true }
interrupted.blockedKey = nil
try NativeStorageMigration.prepare(interrupted)
check("INTERRUPTED_COPY_RETRIES", rejected && interrupted.object(forKey: oldHosts) as? Data == oldData && interrupted.object(forKey: newHosts) as? Data == oldData)
let changedAfterInterruption = FakePreferences()
changedAfterInterruption.set(oldData, forKey: oldHosts)
changedAfterInterruption.blockedKey = newHosts
do { try NativeStorageMigration.prepare(changedAfterInterruption) } catch {}
changedAfterInterruption.blockedKey = nil
changedAfterInterruption.set(oldEdit, forKey: oldHosts)
var retryRejected = false
do { try NativeStorageMigration.prepare(changedAfterInterruption) } catch { retryRejected = true }
check("CHANGED_SOURCE_AFTER_INTERRUPTION_FAILS_CLOSED", retryRejected && changedAfterInterruption.object(forKey: oldHosts) as? Data == oldEdit && changedAfterInterruption.object(forKey: newHosts) == nil)
let unavailable = FakePreferences()
unavailable.set(oldData, forKey: oldHosts)
unavailable.flushFails = true
var flushRejected = false
do { try NativeStorageMigration.prepare(unavailable) } catch { flushRejected = true }
check("FAILED_FLUSH_PRESERVES_SOURCE", flushRejected && unavailable.object(forKey: oldHosts) as? Data == oldData && unavailable.object(forKey: newHosts) == nil)
let corrupt = FakePreferences()
corrupt.set(Data("not-json".utf8), forKey: oldHosts)
var corruptRejected = false
do { try NativeStorageMigration.prepare(corrupt) } catch { corruptRejected = true }
check("CORRUPT_SOURCE_FAILS_CLOSED", corruptRejected && corrupt.object(forKey: newHosts) == nil)
let changing = FakePreferences()
changing.set(oldData, forKey: oldHosts)
changing.changingKey = oldHosts
changing.changedValue = oldEdit
var changingRejected = false
do { try NativeStorageMigration.prepare(changing) } catch { changingRejected = true }
check("SOURCE_CHANGE_DURING_COPY_FAILS_CLOSED", changingRejected && changing.object(forKey: oldHosts) as? Data == oldEdit && changing.object(forKey: newHosts) == nil)
let backup = [oldHosts: oldData, oldSnippets: oldData]
let safeRestore = try NativeStorageMigration.restoreValues(backup, existing: [oldHosts: oldEdit, newHosts: newEdit])
check("OLD_ARCHIVE_RESTORES_ONLY_VERSIONED_TARGET", safeRestore[newHosts] as? Data == oldData && safeRestore[newSnippets] as? Data == oldData && safeRestore[oldHosts] == nil)
let indexedBackup: [String: Any] = [oldHosts: oldData, "SelectiveRemote.keychain.unifiedVault.index.v1": ["legacy"]]
let indexed = try? NativeStorageMigration.restoreValues(indexedBackup, existing: ["SelectiveRemote.keychain.unifiedVault.index.v1": ["changed"]])
check("LEGACY_KEYCHAIN_INDEX_IS_NEVER_RESTORED", indexed?[newHosts] as? Data == oldData && indexed?["SelectiveRemote.keychain.unifiedVault.index.v1"] == nil)
var missingCollectionRejected = false
do { _ = try NativeStorageMigration.restoreValues([oldHosts: oldData], existing: [newSnippets: newEdit]) } catch { missingCollectionRejected = true }
check("RESTORE_MISSING_CURRENT_COLLECTION_FAILS_CLOSED", missingCollectionRejected)
let oldPresence = "SelectiveRemote.sshPasswordUserPresenceProfiles.v1"
let newPresence = NativeStorageMigration.newKey(for: oldPresence)!
var weakerPresenceRejected = false
do { _ = try NativeStorageMigration.restoreValues([oldPresence: [String]()], existing: [newPresence: ["test-identity"]]) } catch { weakerPresenceRejected = true }
check("RESTORE_CANNOT_SILENTLY_REMOVE_TOUCH_ID", weakerPresenceRejected)
var invalidArchivePresenceRejected = false
do { _ = try NativeStorageMigration.restoreValues([oldPresence: "corrupt"], existing: [:]) } catch { invalidArchivePresenceRejected = true }
check("CORRUPT_TOUCH_ID_BACKUP_FAILS_CLOSED", invalidArchivePresenceRejected)
let presencePrefs = FakePreferences()
presencePrefs.set(["test-identity"], forKey: oldPresence)
try NativeStorageMigration.prepare(presencePrefs)
presencePrefs.set("corrupt", forKey: newPresence)
var invalidPresenceRejected = false
do { try NativeStorageMigration.prepare(presencePrefs) } catch { invalidPresenceRejected = true }
check("CORRUPT_TOUCH_ID_SETTINGS_FAIL_CLOSED", invalidPresenceRejected && presencePrefs.object(forKey: oldPresence) as? [String] == ["test-identity"])
let legacyOnly = try JSONSerialization.data(withJSONObject: ["host": "old.example", "username": "test", "selectedDisplayIDs": []])
var oldFormatRejected = false
do { _ = try NativeStorageMigration.restoreValues(["SelectiveRemote.connectionProfile.v1": legacyOnly], existing: [:]) } catch { oldFormatRejected = true }
check("UNSUPPORTED_LEGACY_ONLY_RESTORE_FAILS_CLOSED", oldFormatRejected)
var sharedSettingsRejected = false
do { _ = try NativeStorageMigration.restoreValues(["SelectiveRemote.appearance.v1": "old"], existing: ["SelectiveRemote.appearance.v1": "new"]) } catch { sharedSettingsRejected = true }
check("SHARED_SETTINGS_RESTORE_FAILS_CLOSED", sharedSettingsRejected)
let interruptedRestore = FakePreferences()
interruptedRestore.set(oldData, forKey: oldHosts)
interruptedRestore.set(oldData, forKey: oldSnippets)
try NativeStorageMigration.prepare(interruptedRestore)
interruptedRestore.set(newEdit, forKey: newHosts)
interruptedRestore.set(newEdit, forKey: newSnippets)
interruptedRestore.blockedKey = newSnippets
interruptedRestore.failFlushWhenBlockedWrite = true
var restoreRejected = false
do { try NativeStorageMigration.applyRestore([newHosts: oldData, newSnippets: oldData], to: interruptedRestore) } catch { restoreRejected = true }
interruptedRestore.blockedKey = nil
interruptedRestore.flushFails = false
try NativeStorageMigration.prepare(interruptedRestore)
check("INTERRUPTED_RESTORE_RECOVERS_PREVIOUS_DATA", restoreRejected && interruptedRestore.object(forKey: newHosts) as? Data == newEdit && interruptedRestore.object(forKey: newSnippets) as? Data == newEdit && interruptedRestore.object(forKey: oldHosts) as? Data == oldData)
interruptedRestore.set(Data("corrupt".utf8), forKey: "SelectiveRemote.native032.restore.pending.v1")
var corruptJournalRejected = false
do { try NativeStorageMigration.prepare(interruptedRestore) } catch { corruptJournalRejected = true }
check("CORRUPT_RESTORE_JOURNAL_FAILS_CLOSED", corruptJournalRejected && interruptedRestore.object(forKey: newHosts) as? Data == newEdit && interruptedRestore.object(forKey: oldHosts) as? Data == oldData)
if failures > 0 { exit(1) }
