import Foundation
import Security
import CryptoKit
struct KeychainCredentialReference {let service:String; let account:String}
enum KeychainError:Error {case invalidData, unifiedVaultDisappeared, concurrentVaultWrite, vaultLockUnavailable, unexpectedStatus(OSStatus)}
let env=ProcessInfo.processInfo.environment,args=CommandLine.arguments
func fail(_ m:String)->Never {fputs("KEYCHAIN_MATRIX_ERROR: \(m)\n",stderr);exit(2)}
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner",let temp=env["RUNNER_TEMP"],let run=env["GITHUB_RUN_ID"],let root=env["SR_KEYCHAIN_FAULT_ROOT"],root==temp+"/keychain-write-boundaries",args.count==2 else {fail("runner identity")}
let oldService="local.selectiveremote.credentials",newService="local.selectiveremote.credentials.v2",base="11111111-1111-4111-8111-111111111111"
let references=[KeychainCredentialReference(service:oldService,account:base),KeychainCredentialReference(service:oldService,account:base+".gateway"),KeychainCredentialReference(service:newService,account:base+".ssh"),KeychainCredentialReference(service:newService,account:base+".forwarding"),KeychainCredentialReference(service:newService,account:base+".ssh-key-authorization"),KeychainCredentialReference(service:newService,account:base+".proxy")]
let kinds=["rdp","gateway","ssh","forwarding","ssh-key-authorization","proxy"]
let legacyService="local.selectiveremote.credentials.unified.v1"
let legacyEntries=Dictionary(uniqueKeysWithValues:zip(references,kinds).map{(UnifiedCredentialVault.entryKey(for:$0.0),"TEST-ONLY-SECRET-"+$0.1)})
func legacyQuery()->[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:legacyService,kSecAttrAccount as String:"credential-vault"]}
func inspectLegacy() throws {
 var q=legacyQuery();q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
 var item:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&item)
 guard status==errSecSuccess,let data=item as? Data,try JSONDecoder().decode([String:String].self,from:data)==legacyEntries else {fail("legacy vault changed status=\(status)")}
}
guard let defaults=UserDefaults(suiteName:"TEST-ONLY-CODEX-MATRIX-\(run)") else {fail("suite")}
let lockRoot=URL(fileURLWithPath:root).appendingPathComponent("matrix-lock",isDirectory:true)
let mode=args[1]
if mode=="seed" {
 var q=legacyQuery();q[kSecValueData as String]=try JSONEncoder().encode(legacyEntries);q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
 let status=SecItemAdd(q as CFDictionary,nil);guard status==errSecSuccess else {fail("seed \(status)")}
 print("SIX_TYPE_LEGACY_SEED=PASS")
} else if mode=="migrate" || mode=="restart" {
 let vault=UnifiedCredentialVault(defaults:defaults,lockDirectory:lockRoot)
 for (ref,kind) in zip(references,kinds) {guard try vault.read(reference:ref)=="TEST-ONLY-SECRET-"+kind else {fail("read \(kind)")}}
 try inspectLegacy();print("SIX_TYPE_\(mode.uppercased())=PASS legacy_unchanged=YES")
} else if mode=="delete" {
 let vault=UnifiedCredentialVault(defaults:defaults,lockDirectory:lockRoot)
 for ref in references {try vault.delete(reference:ref)}
 try inspectLegacy();print("SIX_TYPE_DELETE=PASS legacy_unchanged=YES")
} else if mode=="verify-delete" {
 let vault=UnifiedCredentialVault(defaults:defaults,lockDirectory:lockRoot)
 for (ref,kind) in zip(references,kinds) {guard try vault.read(reference:ref)==nil,try vault.isLegacySuppressed(reference:ref) else {fail("deleted \(kind)")}}
 try inspectLegacy();print("SIX_TYPE_DELETE_RESTART=PASS legacy_unchanged=YES")
} else {fail("unknown mode")}
