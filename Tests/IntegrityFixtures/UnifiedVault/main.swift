import Foundation
import CoreFoundation
import CryptoKit

typealias OSStatus = Int32
let errSecSuccess: OSStatus = 0, errSecItemNotFound: OSStatus = -25300, errSecDecode: OSStatus = -26275
let errSecDuplicateItem: OSStatus = -25299, injectedFailure: OSStatus = -9999
let kSecClass = "class", kSecClassGenericPassword = "generic", kSecAttrService = "service", kSecAttrAccount = "account"
let kSecReturnData = "returnData", kSecMatchLimit = "limit", kSecMatchLimitOne = "one", kSecMatchLimitAll = "all"
let kSecReturnAttributes = "attributes", kSecValueData = "value", kSecAttrAccessible = "accessible"
let kSecAttrAccessibleAfterFirstUnlock = "old-accessible", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "new-accessible"
struct KeychainCredentialReference { let service: String; let account: String }
enum KeychainError: Error { case invalidData, unifiedVaultDisappeared, concurrentVaultWrite, vaultLockUnavailable, unexpectedStatus(OSStatus) }
final class FakeDefaults {
 static let standard = FakeDefaults()
 var values: [String: Any] = [:]
 func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
 func set(_ value: Any?, forKey key: String) { values[key] = value }
}
enum FakeKeychain {
 static var records: [String: Data] = [:]
 static var failWrite = false
 static var failRead = false
 static var disappearOnUpdate = false
 static func key(_ query: CFDictionary) -> String { let q = query as NSDictionary; return "\(q[kSecAttrService] ?? "")|\(q[kSecAttrAccount] ?? "")" }
 static func reset() { records = [:]; failWrite = false; failRead = false; disappearOnUpdate = false }
 static func hash() -> String { records.sorted { $0.key < $1.key }.map { "\($0.key)=\(SHA256.hash(data: $0.value).map { String(format:"%02x", $0) }.joined())" }.joined(separator: ";") }
}
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 if FakeKeychain.failRead { return injectedFailure }
 guard let data = FakeKeychain.records[FakeKeychain.key(query)] else { return errSecItemNotFound }
 result?.pointee = data as CFData; return errSecSuccess
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
 if FakeKeychain.failWrite { return injectedFailure }
 let key = FakeKeychain.key(query); guard FakeKeychain.records[key] != nil else { return errSecItemNotFound }
 if FakeKeychain.disappearOnUpdate { FakeKeychain.records.removeValue(forKey: key); return errSecItemNotFound }
 if let data = (attributes as NSDictionary)[kSecValueData] as? Data { FakeKeychain.records[key] = data }; return errSecSuccess
}
func SecItemAdd(_ item: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 if FakeKeychain.failWrite { return injectedFailure }
 let key = FakeKeychain.key(item); guard FakeKeychain.records[key] == nil else { return errSecDuplicateItem }
 guard let data = (item as NSDictionary)[kSecValueData] as? Data else { return errSecDecode }
 FakeKeychain.records[key] = data; return errSecSuccess
}

let first = KeychainCredentialReference(service: "TEST-ONLY", account: "first")
let second = KeychainCredentialReference(service: "TEST-ONLY", account: "second")
let third = KeychainCredentialReference(service: "TEST-ONLY", account: "third")
var failures = 0
func check(_ name: String, _ condition: Bool) {
 print("\(name)=\(condition ? "PASS" : "FAIL")")
 if !condition { failures += 1 }
}
FakeKeychain.reset()
let a = UnifiedCredentialVault(defaults: FakeDefaults())
let b = UnifiedCredentialVault(defaults: FakeDefaults())
try a.save("first", reference: first)
try b.unlock()
try a.save("second", reference: second)
try b.save("third", reference: third)
let verify = UnifiedCredentialVault(defaults: FakeDefaults())
let preservedSecond = try verify.read(reference: second) == "second"
let preservedThird = try verify.read(reference: third) == "third"
check("SEQUENTIAL_INSTANCE_EDITS_PRESERVED", preservedSecond && preservedThird)
FakeKeychain.reset()
let writer = UnifiedCredentialVault(defaults: FakeDefaults())
try writer.save("first", reference: first)
let before = FakeKeychain.hash()
FakeKeychain.failRead = true
var rejected = false
do { try writer.save("second", reference: second) } catch { rejected = true }
FakeKeychain.failRead = false
check("FAILED_READ_PREVENTS_WRITE_AND_PRESERVES_DATA", rejected && FakeKeychain.hash() == before)
FakeKeychain.failWrite = true
var writeRejected = false
do { try writer.save("second", reference: second) } catch { writeRejected = true }
FakeKeychain.failWrite = false
check("FAILED_WRITE_PRESERVES_EXISTING_DATA", writeRejected && FakeKeychain.hash() == before)
let fixtureRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SR_FIXTURE_DIR"]!)
let notDirectory = fixtureRoot.appendingPathComponent("not-a-directory")
try Data("file".utf8).write(to: notDirectory)
let blocked = UnifiedCredentialVault(defaults: FakeDefaults(), lockDirectory: notDirectory)
var lockRejected = false
do { try blocked.save("second", reference: second) } catch { lockRejected = true }
check("LOCK_FAILURE_PRESERVES_EXISTING_DATA", lockRejected && FakeKeychain.hash() == before)
FakeKeychain.reset()
let observing = UnifiedCredentialVault(defaults: FakeDefaults())
let updating = UnifiedCredentialVault(defaults: FakeDefaults())
try observing.unlock()
try updating.save("second", reference: second)
check("SECOND_INSTANCE_SEES_ADDED_SECRET", try observing.contains(reference: second))
// Recreate a stale observer independently of the existence lookup above.
let staleReader = UnifiedCredentialVault(defaults: FakeDefaults())
try staleReader.unlock()
try updating.save("third", reference: third)
check("SECOND_INSTANCE_READS_ADDED_SECRET", try staleReader.read(reference: third) == "third")
let protectedReader = UnifiedCredentialVault(defaults: FakeDefaults())
try protectedReader.unlock()
try updating.saveProtectedData(Data("TEST-ONLY".utf8), namespace: "fixture", key: "item")
check("SECOND_INSTANCE_READS_PROTECTED_DATA", try protectedReader.readProtectedData(namespace: "fixture", key: "item") == Data("TEST-ONLY".utf8))
FakeKeychain.failRead = true
var existenceRejected = false
do { _ = try observing.contains(reference: second) } catch { existenceRejected = true }
FakeKeychain.failRead = false
check("FAILED_EXISTENCE_READ_IS_NOT_ABSENCE", existenceRejected)
FakeKeychain.reset()
let deleted = UnifiedCredentialVault(defaults: FakeDefaults())
try deleted.save("first", reference: first)
FakeKeychain.records.removeAll()
var missingRejected = false
do { try deleted.save("second", reference: second) } catch { missingRejected = true }
check("DELETED_ITEM_IS_NOT_RECREATED_FROM_STALE_PROCESS", missingRejected && FakeKeychain.records.isEmpty)
FakeKeychain.reset()
let racingDeletion = UnifiedCredentialVault(defaults: FakeDefaults())
try racingDeletion.save("first", reference: first)
FakeKeychain.disappearOnUpdate = true
var raceRejected = false
do { try racingDeletion.save("second", reference: second) } catch { raceRejected = true }
let currentItem = "\(UnifiedCredentialVault.service)|\(UnifiedCredentialVault.account)"
check("ITEM_REMOVED_DURING_WRITE_IS_NOT_RECREATED", raceRejected && FakeKeychain.records[currentItem] == nil)
FakeKeychain.reset()
let deleter = UnifiedCredentialVault(defaults: FakeDefaults())
try deleter.save("first", reference: first)
try deleter.delete(reference: first)
let restarted = UnifiedCredentialVault(defaults: FakeDefaults())
check("DELETION_TOMBSTONE_SURVIVES_STALE_DEFAULTS", try restarted.isLegacySuppressed(reference: first))
try restarted.save("replacement", reference: first)
check("NEW_SECRET_CLEARS_DELETION_TOMBSTONE", try !restarted.isLegacySuppressed(reference: first))
FakeKeychain.reset()
let oldDefaults = FakeDefaults()
oldDefaults.set([UnifiedCredentialVault.entryKey(for: first)], forKey: "SelectiveRemote.keychain.unifiedVault.suppressedLegacy.v1")
let withLegacyTombstone = UnifiedCredentialVault(defaults: oldDefaults)
check("LEGACY_DELETION_TOMBSTONE_MIGRATED", try withLegacyTombstone.isLegacySuppressed(reference: first))
let noOldDefaults = UnifiedCredentialVault(defaults: FakeDefaults())
check("MIGRATED_TOMBSTONE_INDEPENDENT_OF_DEFAULTS", try noOldDefaults.isLegacySuppressed(reference: first))
FakeKeychain.records["local.selectiveremote.credentials.unified.v2-migration|credential-vault"] = Data("invalid".utf8)
let corruptSnapshot = FakeKeychain.hash()
var corruptRejected = false
do { try UnifiedCredentialVault(defaults: FakeDefaults()).unlock() } catch { corruptRejected = true }
check("CORRUPT_MIGRATION_CHECKPOINT_FAILS_CLOSED", corruptRejected && FakeKeychain.hash() == corruptSnapshot)
FakeKeychain.reset()
let conflictingLegacy = try JSONEncoder().encode([UnifiedCredentialVault.entryKey(for: first): "legacy"])
FakeKeychain.records["local.selectiveremote.credentials.unified.v1|credential-vault"] = conflictingLegacy
var conflictRejected = false
do { try UnifiedCredentialVault(defaults: oldDefaults).unlock() } catch { conflictRejected = true }
check("LEGACY_TOMBSTONE_CONFLICT_FAILS_CLOSED", conflictRejected && FakeKeychain.records["local.selectiveremote.credentials.unified.v1|credential-vault"] == conflictingLegacy && FakeKeychain.records.count == 1)
FakeKeychain.reset()
let restoredVault = UnifiedCredentialVault(defaults: FakeDefaults())
try restoredVault.save("original", reference: first)
try restoredVault.saveProtectedData(Data("protected".utf8), namespace: "fixture", key: "state")
try restoredVault.replaceSecrets([UnifiedCredentialVault.entryKey(for: second): "replacement"])
let restoredSecret = try restoredVault.read(reference: second)
let restoredProtected = try restoredVault.readProtectedData(namespace: "fixture", key: "state")
let previousSuppressed = try restoredVault.isLegacySuppressed(reference: first)
check("RESTORE_SUPPRESSES_REPLACED_LEGACY_SECRET", restoredSecret == "replacement" && restoredProtected == Data("protected".utf8) && previousSuppressed)
if failures > 0 { exit(1) }
