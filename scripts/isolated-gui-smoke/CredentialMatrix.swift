import CryptoKit
import Darwin
import Foundation
import Security
func fail(_ m:String)->Never {fputs("CREDENTIAL_MATRIX_BLOCKED: \(m)\n",stderr);exit(2)}
let env=ProcessInfo.processInfo.environment
var console=stat();let args=CommandLine.arguments
let temp=env["RUNNER_TEMP"] ?? ""
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner",getuid()>0,stat("/dev/console",&console)==0,console.st_uid==getuid(),args.count==4,["seed","verify"].contains(args[1]),["031","032"].contains(args[2]),args[3]==temp+"/evidence/baseline-persistence.json",(args[1] != "seed" || args[2]=="031") else {fail("identity")}
guard let data=try? Data(contentsOf:URL(fileURLWithPath:args[3])),let obj=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let host=obj["baselineHost"] as? [String:Any],host["friendlyName"] as? String == "TEST-ONLY-CODEX-UPGRADE-HOST",let id=host["id"] as? String,let uuid=UUID(uuidString:id)?.uuidString else {fail("synthetic identity")}
let old="local.selectiveremote.credentials", modern="local.selectiveremote.credentials.v2", sep="\u{1F}"
let expected:[String:String]=[
 old+sep+uuid:"TEST-ONLY-CODEX-MATRIX-RDP",old+sep+uuid+".gateway":"TEST-ONLY-CODEX-MATRIX-GATEWAY",
 modern+sep+uuid+".ssh":"TEST-ONLY-CODEX-UPGRADE-SECRET",modern+sep+uuid+".forwarding":"TEST-ONLY-CODEX-MATRIX-FORWARDING",modern+sep+uuid+".proxy":"TEST-ONLY-CODEX-MATRIX-PROXY"]
let service="local.selectiveremote.credentials.unified."+(args[2]=="031" ? "v1":"v2")
let key:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"credential-vault"]
var query=key;query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne;query[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result)
guard status==errSecSuccess,let raw=result as? Data,var values=(try? JSONSerialization.jsonObject(with:raw)) as? [String:String] else {fail("read status=\(status)")}
if args[1]=="seed" {
 guard values[modern+sep+uuid+".ssh"]==expected[modern+sep+uuid+".ssh"] else {fail("initial ssh secret")}
 for (k,v) in expected { values[k]=v }
 guard let payload=try? JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]) else {fail("encoding")}
 let update=SecItemUpdate(key as CFDictionary,[kSecValueData as String:payload] as CFDictionary)
 guard update==errSecSuccess else {fail("write status=\(update)")}
} else { for (k,v) in expected {guard values[k]==v else {fail("expected entry missing")}} }
print("CREDENTIAL_MATRIX_\(args[1].uppercased())_\(args[2])_FIVE_KINDS=PASS")
