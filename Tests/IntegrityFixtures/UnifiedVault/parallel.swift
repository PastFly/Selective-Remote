import Foundation
import CoreFoundation

typealias OSStatus = Int32
let errSecSuccess: OSStatus = 0, errSecItemNotFound: OSStatus = -25300, errSecDecode: OSStatus = -26275
let errSecDuplicateItem: OSStatus = -25299
let kSecClass = "class", kSecClassGenericPassword = "generic", kSecAttrService = "service", kSecAttrAccount = "account"
let kSecReturnData = "returnData", kSecMatchLimit = "limit", kSecMatchLimitOne = "one", kSecMatchLimitAll = "all"
let kSecReturnAttributes = "attributes", kSecValueData = "value", kSecAttrAccessible = "accessible"
let kSecAttrAccessibleAfterFirstUnlock = "old", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "new"
struct KeychainCredentialReference { let service: String; let account: String }
enum KeychainError: Error { case invalidData, unifiedVaultDisappeared, concurrentVaultWrite, vaultLockUnavailable, unexpectedStatus(OSStatus) }
final class FakeDefaults {
 static let standard = FakeDefaults()
 var values: [String: Any] = [:]
 func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
 func set(_ value: Any?, forKey key: String) { values[key] = value }
}
let fixtureDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SR_FIXTURE_DIR"]!, isDirectory: true)
let itemURL = fixtureDirectory.appendingPathComponent("item.json")
let workerID = CommandLine.arguments[1]
var didWait = false
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
 let service = (query as NSDictionary)[kSecAttrService] as? String
 if service == "local.selectiveremote.credentials.unified.v2-migration" {
  result?.pointee = Data("committed".utf8) as CFData
  return errSecSuccess
 }
 if service == "local.selectiveremote.credentials.unified.v1" { return errSecItemNotFound }
 guard let data = try? Data(contentsOf: itemURL) else { return errSecItemNotFound }
 if !didWait {
  didWait = true
  let mine = fixtureDirectory.appendingPathComponent("read-" + workerID)
  let other = fixtureDirectory.appendingPathComponent("read-" + (workerID == "A" ? "B" : "A"))
  _ = FileManager.default.createFile(atPath: mine.path, contents: Data())
  let deadline = Date().addingTimeInterval(0.7)
  while !FileManager.default.fileExists(atPath: other.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
 }
 result?.pointee = data as CFData
 return errSecSuccess
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
 guard FileManager.default.fileExists(atPath: itemURL.path) else { return errSecItemNotFound }
 if let data = (attributes as NSDictionary)[kSecValueData] as? Data {
  do { try data.write(to: itemURL, options: .atomic) } catch { return errSecDecode }
 }
 return errSecSuccess
}
func SecItemAdd(_ item: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecDuplicateItem }
let vault = UnifiedCredentialVault(defaults: FakeDefaults())
let reference = KeychainCredentialReference(service: "TEST-ONLY", account: workerID)
var saved = false
for _ in 0..<200 {
 do { try vault.save(workerID, reference: reference); saved = true; break }
 catch KeychainError.concurrentVaultWrite { Thread.sleep(forTimeInterval: 0.01) }
}
if !saved { exit(2) }
