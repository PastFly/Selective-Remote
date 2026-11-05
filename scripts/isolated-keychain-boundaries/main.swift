import Foundation
import Security
import CryptoKit
import Darwin

struct KeychainCredentialReference { let service:String; let account:String }
enum KeychainError: Error {case invalidData, unifiedVaultDisappeared, concurrentVaultWrite, vaultLockUnavailable, unexpectedStatus(OSStatus)}
let env=ProcessInfo.processInfo.environment
let args=CommandLine.arguments
func fail(_ message:String)->Never {fputs("KEYCHAIN_FAULT_ERROR: \(message)\n",stderr);exit(2)}
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner",
      let temp=env["RUNNER_TEMP"],let run=env["GITHUB_RUN_ID"],let root=env["SR_KEYCHAIN_FAULT_ROOT"],
      root==temp+"/keychain-write-boundaries",args.count==3,
      args[2].allSatisfy({$0.isLetter || $0.isNumber || $0=="_"}) else {fail("runner identity")}
let mode=args[1],point=args[2],marker=URL(fileURLWithPath:root).appendingPathComponent("stopped-\(point)")
let service="local.selectiveremote.credentials.unified.v2",migrationService="local.selectiveremote.credentials.unified.v2-migration",legacyService="local.selectiveremote.credentials.unified.v1"
let reference=KeychainCredentialReference(service:"local.selectiveremote.credentials.v2",account:"11111111-1111-4111-8111-111111111111.ssh")
let second=KeychainCredentialReference(service:"local.selectiveremote.credentials",account:"22222222-2222-4222-8222-222222222222.gateway")
let old="TEST-ONLY-CODEX-OLD-SECRET",new="TEST-ONLY-CODEX-NEW-SECRET",other="TEST-ONLY-CODEX-OTHER-SECRET"
let lockRoot=URL(fileURLWithPath:root).appendingPathComponent("lock-\(point)",isDirectory:true)
let suite="TEST-ONLY-CODEX-KEYCHAIN-\(run)-\(point)"
guard let defaults=UserDefaults(suiteName:suite) else {fail("defaults")}
func pause(_ name:String) {
    guard mode=="fault",point==name else {return}
    do {try Data(name.utf8).write(to:marker,options:.atomic)} catch {fail("marker")}
    fflush(nil);raise(SIGSTOP);fail("resumed without kill")
}
func SecItemAdd(_ attributes:CFDictionary,_ result:UnsafeMutablePointer<CFTypeRef?>?)->OSStatus {
    let item=attributes as NSDictionary
    let name=item[kSecAttrService as String] as? String ?? ""
    if name==migrationService {pause("before_pending_marker")}
    if name==service {pause("before_current_add")}
    let status=Security.SecItemAdd(attributes,result)
    if status==errSecSuccess && name==migrationService {pause("after_pending_marker")}
    if status==errSecSuccess && name==service {pause("after_current_add")}
    return status
}
func SecItemUpdate(_ query:CFDictionary,_ attributes:CFDictionary)->OSStatus {
    let item=query as NSDictionary,updates=attributes as NSDictionary
    let name=item[kSecAttrService as String] as? String ?? ""
    let payload=updates[kSecValueData as String] as? Data
    let committing=name==migrationService && payload.flatMap {String(data:$0,encoding:.utf8)}=="committed"
    if committing {pause("before_marker_commit")}
    if name==service && payload != nil {pause("before_current_update")}
    let status=Security.SecItemUpdate(query,attributes)
    if status==errSecSuccess && committing {pause("after_marker_commit")}
    if status==errSecSuccess && name==service && payload != nil {pause("after_current_update")}
    return status
}
func legacyData() throws -> Data {try JSONEncoder().encode([UnifiedCredentialVault.entryKey(for:reference):old,UnifiedCredentialVault.entryKey(for:second):other])}
func legacyQuery()->[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:legacyService,kSecAttrAccount as String:"credential-vault"]}
func inspectLegacy() throws {
    var query=legacyQuery();query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
    var raw:CFTypeRef?;let status=Security.SecItemCopyMatching(query as CFDictionary,&raw)
    guard status==errSecSuccess,let data=raw as? Data,let values=try? JSONDecoder().decode([String:String].self,from:data),values[UnifiedCredentialVault.entryKey(for:reference)]==old,values[UnifiedCredentialVault.entryKey(for:second)]==other else {fail("legacy values/status=\(status)")}
}
if mode=="seed" {
    defaults.removePersistentDomain(forName:suite)
    var item=legacyQuery();item[kSecValueData as String]=try legacyData();item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status=Security.SecItemAdd(item as CFDictionary,nil);guard status==errSecSuccess else {fail("seed status=\(status)")}
    if point.contains("current_update") {let vault=UnifiedCredentialVault(defaults:defaults,lockDirectory:lockRoot);try vault.unlock();guard try vault.read(reference:reference)==old else {fail("seed old")}}
    print("SYNTHETIC_KEYCHAIN_SEED=PASS")
} else if mode=="fault" {
    let vault=UnifiedCredentialVault(defaults:defaults,lockDirectory:lockRoot)
    if point.contains("current_update") {try vault.save(new,reference:reference)} else {try vault.unlock()}
    fail("fault boundary not reached")
} else if mode=="busy" {
    let vault=UnifiedCredentialVault(defaults:defaults,lockDirectory:lockRoot)
    do {try vault.withExclusiveAccess {};fail("lock unexpectedly acquired")}
    catch KeychainError.concurrentVaultWrite {print("SYNTHETIC_KEYCHAIN_LOCK=BUSY")}
    catch {fail("unexpected lock error")}
} else if mode=="recover" {
    let vault=UnifiedCredentialVault(defaults:defaults,lockDirectory:lockRoot)
    let value=try vault.read(reference:reference)
    let expected=point=="after_current_update" ? new : old
    guard value==expected,try vault.read(reference:second)==other else {fail("recovered values")}
    try inspectLegacy()
    print("SYNTHETIC_KEYCHAIN_RECOVERY=PASS point=\(point) value=\(value==new ? "new" : "old") legacy_unchanged=YES")
} else {fail("unknown mode")}
