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
 static var failAddService: String?
 static var failUpdateService: String?
 static func key(_ query: CFDictionary) -> String { let q = query as NSDictionary; return "\(q[kSecAttrService] ?? "")|\(q[kSecAttrAccount] ?? "")" }
 static func reset() { records = [:]; failWrite = false; failRead = false; failAddService = nil; failUpdateService = nil }
 static func hash() -> String { records.sorted { $0.key < $1.key }.map { "\($0.key)=\(SHA256.hash(data: $0.value).map { String(format:"%02x", $0) }.joined())" }.joined(separator: ";") }
}
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 if FakeKeychain.failRead { return injectedFailure }
 guard let data = FakeKeychain.records[FakeKeychain.key(query)] else { return errSecItemNotFound }
 result?.pointee = data as CFData; return errSecSuccess
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
 if FakeKeychain.failWrite { return injectedFailure }
 if (query as NSDictionary)[kSecAttrService] as? String == FakeKeychain.failUpdateService { return injectedFailure }
 let key = FakeKeychain.key(query); guard FakeKeychain.records[key] != nil else { return errSecItemNotFound }
 if let data = (attributes as NSDictionary)[kSecValueData] as? Data { FakeKeychain.records[key] = data }; return errSecSuccess
}
func SecItemAdd(_ item: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 if FakeKeychain.failWrite { return injectedFailure }
 if (item as NSDictionary)[kSecAttrService] as? String == FakeKeychain.failAddService { return injectedFailure }
 let key = FakeKeychain.key(item); guard FakeKeychain.records[key] == nil else { return errSecDuplicateItem }
 guard let data = (item as NSDictionary)[kSecValueData] as? Data else { return errSecDecode }
 FakeKeychain.records[key] = data; return errSecSuccess
}
let a = KeychainCredentialReference(service: "synthetic", account: "a")
let b = KeychainCredentialReference(service: "synthetic", account: "b")
let c = KeychainCredentialReference(service: "synthetic", account: "c")
var failures = 0
func check(_ name: String, _ condition: Bool) { print("\(name)=\(condition ? "PASS" : "FAIL")"); if !condition { failures += 1 } }
FakeKeychain.reset()
let old1 = OldUnifiedCredentialVault(defaults: FakeDefaults()), new1 = UnifiedCredentialVault(defaults: FakeDefaults())
try old1.save("a", reference: a); try new1.unlock(); try old1.save("b", reference: b)
let before = FakeKeychain.hash()
try new1.saveProtectedData(Data("cloud".utf8), namespace: "synthetic", key: "endpoint")
let old1Reopen = OldUnifiedCredentialVault(defaults: FakeDefaults())
check("OLD_SECRET_PRESERVED_AFTER_NEW_CLOUD_WRITE", try old1Reopen.read(reference: b) == "b")
print("SYNTHETIC_HASH_BEFORE_NEW_WRITE=\(before)")
print("SYNTHETIC_HASH_AFTER_NEW_WRITE=\(FakeKeychain.hash())")
FakeKeychain.reset()
let old2 = OldUnifiedCredentialVault(defaults: FakeDefaults()), new2 = UnifiedCredentialVault(defaults: FakeDefaults())
try old2.save("a", reference: a); try old2.unlock(); try new2.saveProtectedData(Data("cloud".utf8), namespace: "synthetic", key: "endpoint"); try old2.save("b", reference: b)
check("NEW_CLOUD_PRESERVED_AFTER_OLD_WRITE", try UnifiedCredentialVault(defaults: FakeDefaults()).readProtectedData(namespace: "synthetic", key: "endpoint") == Data("cloud".utf8))
FakeKeychain.reset()
let old3 = OldUnifiedCredentialVault(defaults: FakeDefaults()), new3 = UnifiedCredentialVault(defaults: FakeDefaults())
try old3.save("a", reference: a); try new3.unlock(); try old3.save("b", reference: b); try new3.save("c", reference: c)
let old3Reopen = OldUnifiedCredentialVault(defaults: FakeDefaults()), new3Reopen = UnifiedCredentialVault(defaults: FakeDefaults())
let old3Preserved = try old3Reopen.read(reference: b) == "b", new3Preserved = try new3Reopen.read(reference: c) == "c"
check("MIXED_VERSION_CREDENTIALS_PRESERVED", old3Preserved && new3Preserved)
FakeKeychain.reset()
let new4a = UnifiedCredentialVault(defaults: FakeDefaults()), new4b = UnifiedCredentialVault(defaults: FakeDefaults())
try new4a.save("a", reference: a); try new4b.unlock(); try new4a.save("b", reference: b); try new4b.save("c", reference: c)
let reread = UnifiedCredentialVault(defaults: FakeDefaults())
let new4bPreserved = try reread.read(reference: b) == "b", new4cPreserved = try reread.read(reference: c) == "c"
check("SAME_VERSION_CREDENTIALS_PRESERVED", new4bPreserved && new4cPreserved)
FakeKeychain.reset()
let old5 = OldUnifiedCredentialVault(defaults: FakeDefaults()), new5 = UnifiedCredentialVault(defaults: FakeDefaults())
try old5.save("a", reference: a); try new5.unlock(); try old5.save("b", reference: b); try new5.delete(reference: a)
check("OLD_SECRET_PRESERVED_AFTER_NEW_DELETE", try OldUnifiedCredentialVault(defaults: FakeDefaults()).read(reference: b) == "b")
FakeKeychain.reset()
let old6 = OldUnifiedCredentialVault(defaults: FakeDefaults()), new6 = UnifiedCredentialVault(defaults: FakeDefaults())
try old6.save("a", reference: a); try old6.unlock(); try new6.saveProtectedData(Data("cloud".utf8), namespace: "synthetic", key: "endpoint"); try old6.delete(reference: a)
check("NEW_CLOUD_PRESERVED_AFTER_OLD_DELETE", try UnifiedCredentialVault(defaults: FakeDefaults()).readProtectedData(namespace: "synthetic", key: "endpoint") == Data("cloud".utf8))
FakeKeychain.reset()
let new7a = UnifiedCredentialVault(defaults: FakeDefaults()), new7b = UnifiedCredentialVault(defaults: FakeDefaults())
try new7a.save("a", reference: a); try new7b.unlock(); try new7a.save("b", reference: b)
check("SECOND_INSTANCE_SEES_NEW_CREDENTIAL", try new7b.contains(reference: b))
FakeKeychain.reset()
let writer = UnifiedCredentialVault(defaults: FakeDefaults()); try writer.save("a", reference: a); let snapshot = FakeKeychain.hash(); FakeKeychain.failWrite = true
var threw = false; do { try writer.save("b", reference: b) } catch { threw = true }
FakeKeychain.failWrite = false
check("WRITE_FAILURE_PRESERVES_ITEM", threw && FakeKeychain.hash() == snapshot)
let beforeUnavailable = FakeKeychain.hash(); FakeKeychain.failRead = true
var readRejected = false
do { _ = try UnifiedCredentialVault(defaults: FakeDefaults()).read(reference: a) } catch { readRejected = true }
FakeKeychain.failRead = false
check("UNAVAILABLE_KEYCHAIN_PRESERVES_ITEM", readRejected && FakeKeychain.hash() == beforeUnavailable)
FakeKeychain.reset()
let migrationOld = OldUnifiedCredentialVault(defaults: FakeDefaults())
try migrationOld.save("a", reference: a)
let beforeMigration = FakeKeychain.hash()
FakeKeychain.failWrite = true
var migrationRejected = false
do { try UnifiedCredentialVault(defaults: FakeDefaults()).saveProtectedData(Data("cloud".utf8), namespace: "synthetic", key: "endpoint") } catch { migrationRejected = true }
FakeKeychain.failWrite = false
check("FAILED_WRITE_PRESERVES_EXISTING_SOURCE", migrationRejected && FakeKeychain.hash() == beforeMigration)
FakeKeychain.reset()
let legacyItem = "\(OldUnifiedCredentialVault.service)|\(OldUnifiedCredentialVault.account)"
let legacyProtectedKey = "\u{1E}protected-data\u{1F}synthetic\u{1F}endpoint"
let legacySnapshot = try JSONEncoder().encode([
 OldUnifiedCredentialVault.entryKey(for: a): "a",
 legacyProtectedKey: Data("old-test-token".utf8).base64EncodedString()
])
FakeKeychain.records[legacyItem] = legacySnapshot
let migrationTarget = UnifiedCredentialVault(defaults: FakeDefaults())
let migratedToken = try migrationTarget.readProtectedData(namespace: "synthetic", key: "endpoint")
let legacyPreserved = FakeKeychain.records[legacyItem] == legacySnapshot
check("COPIED_LEGACY_SOURCE_PRESERVED", migratedToken == Data("old-test-token".utf8) && legacyPreserved && UnifiedCredentialVault.service != OldUnifiedCredentialVault.service)
try migrationTarget.deleteProtectedData(namespace: "synthetic", key: "endpoint")
FakeKeychain.records.removeValue(forKey: "\(UnifiedCredentialVault.service)|\(UnifiedCredentialVault.account)")
var missingAfterMigrationRejected = false
do { _ = try UnifiedCredentialVault(defaults: FakeDefaults()).readProtectedData(namespace: "synthetic", key: "endpoint") } catch { missingAfterMigrationRejected = true }
check("MISSING_MIGRATED_ITEM_CANNOT_RESTORE_OLD_TOKEN", missingAfterMigrationRejected && FakeKeychain.records[legacyItem] == legacySnapshot)
FakeKeychain.reset()
FakeKeychain.records[legacyItem] = legacySnapshot
FakeKeychain.failAddService = UnifiedCredentialVault.service
var interruptedBeforeCopy = false
do { try UnifiedCredentialVault(defaults: FakeDefaults()).unlock() } catch { interruptedBeforeCopy = true }
FakeKeychain.failAddService = nil
let resumedCopy = try UnifiedCredentialVault(defaults: FakeDefaults()).readProtectedData(namespace: "synthetic", key: "endpoint")
check("INTERRUPTED_COPY_RETRIES_WITH_SOURCE_PRESERVED", interruptedBeforeCopy && resumedCopy == Data("old-test-token".utf8) && FakeKeychain.records[legacyItem] == legacySnapshot)
FakeKeychain.reset()
FakeKeychain.records[legacyItem] = legacySnapshot
FakeKeychain.failUpdateService = "local.selectiveremote.credentials.unified.v2-migration"
var interruptedAfterCopy = false
do { try UnifiedCredentialVault(defaults: FakeDefaults()).unlock() } catch { interruptedAfterCopy = true }
FakeKeychain.failUpdateService = nil
let resumedCommit = try UnifiedCredentialVault(defaults: FakeDefaults()).readProtectedData(namespace: "synthetic", key: "endpoint")
check("INTERRUPTED_CHECKPOINT_RETRIES_WITH_SOURCE_PRESERVED", interruptedAfterCopy && resumedCommit == Data("old-test-token".utf8) && FakeKeychain.records[legacyItem] == legacySnapshot)
FakeKeychain.reset()
FakeKeychain.records[legacyItem] = legacySnapshot
FakeKeychain.failAddService = UnifiedCredentialVault.service
do { try UnifiedCredentialVault(defaults: FakeDefaults()).unlock() } catch {}
FakeKeychain.failAddService = nil
let changedLegacy = try JSONEncoder().encode([OldUnifiedCredentialVault.entryKey(for: a): "changed"])
FakeKeychain.records[legacyItem] = changedLegacy
var changedSourceRejected = false
do { try UnifiedCredentialVault(defaults: FakeDefaults()).unlock() } catch { changedSourceRejected = true }
check("CHANGED_SOURCE_DURING_INTERRUPTED_COPY_FAILS_CLOSED", changedSourceRejected && FakeKeychain.records[legacyItem] == changedLegacy && FakeKeychain.records["\(UnifiedCredentialVault.service)|\(UnifiedCredentialVault.account)"] == nil)
print("OLD_ITEM=\(OldUnifiedCredentialVault.service)/\(OldUnifiedCredentialVault.account)")
print("NEW_ITEM=\(UnifiedCredentialVault.service)/\(UnifiedCredentialVault.account)")
if failures > 0 { exit(1) }
