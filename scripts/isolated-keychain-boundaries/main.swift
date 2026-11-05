import Foundation
import Security
import CryptoKit
import Darwin
struct UpdateLocalization { static func text(ru:String,en:String)->String {en} }
struct SelectiveRemotePersonalVaultCredentialInput {let sourceID:UUID; let kind:KeychainCredentialKind; let secret:String}
let env=ProcessInfo.processInfo.environment,args=CommandLine.arguments
func fail(_ m:String)->Never {fputs("KEYCHAIN_API_MATRIX_ERROR: \(m)\n",stderr);exit(2)}
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner",let temp=env["RUNNER_TEMP"],let root=env["SR_KEYCHAIN_FAULT_ROOT"],root==temp+"/keychain-write-boundaries",args.count==2 else {fail("runner identity")}
let profile=UUID(uuidString:"11111111-1111-4111-8111-111111111111")!
let kinds:[KeychainCredentialKind]=[.rdp,.gateway,.ssh,.forwarding,.sshKeyAuthorization,.proxy]
let entries=Dictionary(uniqueKeysWithValues:kinds.map {kind in (UnifiedCredentialVault.entryKey(for:KeychainService.credentialReference(profileID:profile,kind:kind)),"TEST-ONLY-ORIGINAL-"+kind.rawValue)})
func legacyQuery()->[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.selectiveremote.credentials.unified.v1",kSecAttrAccount as String:"credential-vault"]}
func inspectLegacy() throws {
 var q=legacyQuery();q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
 var item:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&item)
 guard status==errSecSuccess,let data=item as? Data,try JSONDecoder().decode([String:String].self,from:data)==entries else {fail("legacy changed status=\(status)")}
}
let mode=args[1]
if mode=="seed" {
 var q=legacyQuery();q[kSecValueData as String]=try JSONEncoder().encode(entries);q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
 guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else {fail("seed")}
 print("SIX_TYPE_LEGACY_SEED=PASS")
} else if mode=="migrate" || mode=="restart" || mode=="verify-update" {
 let prefix=mode=="verify-update" ? "TEST-ONLY-UPDATED-" : "TEST-ONLY-ORIGINAL-"
 for kind in kinds {guard try KeychainService.readPassword(profileID:profile,kind:kind)==prefix+kind.rawValue else {fail("read \(kind.rawValue)")}}
 try inspectLegacy();print("SIX_TYPE_API_\(mode.uppercased())=PASS")
} else if mode=="update" {
 for kind in kinds {try KeychainService.savePassword("TEST-ONLY-UPDATED-"+kind.rawValue,profileID:profile,kind:kind)}
 try inspectLegacy();print("SIX_TYPE_API_UPDATE=PASS")
} else if mode=="delete" {
 for kind in kinds {try KeychainService.deletePassword(profileID:profile,kind:kind)}
 try inspectLegacy();print("SIX_TYPE_API_DELETE=PASS")
} else if mode=="verify-delete" {
 for kind in kinds {guard try KeychainService.readPassword(profileID:profile,kind:kind)==nil else {fail("deleted \(kind.rawValue)")}}
 try inspectLegacy();print("SIX_TYPE_API_DELETE_RESTART=PASS")
} else if mode=="presence-unavailable" {
 guard !KeychainService.touchIDAvailable else {print("TOUCH_ID_PRESENT=SKIPPED");exit(0)}
 var rejected=false
 do {try KeychainService.savePassword("TEST-ONLY-UNAUTHORIZED",profileID:profile,kind:.ssh,requiresUserPresence:true)} catch {rejected=true}
 guard rejected,try KeychainService.readPassword(profileID:profile,kind:.ssh)==nil else {fail("user-presence failure did not fail closed")}
 try inspectLegacy();print("UNAVAILABLE_TOUCH_ID_FAILS_CLOSED=PASS")
} else {fail("unknown mode")}
