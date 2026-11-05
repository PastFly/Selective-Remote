import Foundation
import CryptoKit
import Darwin
let env=ProcessInfo.processInfo.environment,args=CommandLine.arguments
func fail(_ m:String)->Never {fputs("HOST_CRASH_ERROR: \(m)\n",stderr);exit(2)}
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner",let temp=env["RUNNER_TEMP"],let run=env["GITHUB_RUN_ID"],let root=env["SR_HOST_FAULT_ROOT"],root==temp+"/host-write-boundaries",args.count==3,args[2].allSatisfy({$0.isLetter || $0.isNumber || $0=="_"}) else {fail("runner identity")}
let mode=args[1],point=args[2],marker=URL(fileURLWithPath:root).appendingPathComponent("stop-\(point)"),lockRoot=URL(fileURLWithPath:root).appendingPathComponent("lock-\(point)",isDirectory:true)
let suite="TEST-ONLY-CODEX-HOST-WRITES-\(run)-\(point)",oldKey="SelectiveRemote.connectionProfiles.v2",newKey=NativeStorageMigration.newKey(for:oldKey)!
struct Record:Codable,Equatable {let id:String;let name:String;let host:String}
let original=Record(id:"11111111-1111-4111-8111-111111111111",name:"TEST-ONLY-OLD",host:"192.0.2.11"),addition=Record(id:"22222222-2222-4222-8222-222222222222",name:"TEST-ONLY-NEW",host:"192.0.2.12")
func pause(_ target:String) {guard mode=="fault",point==target else{return};do{try Data(target.utf8).write(to:marker,options:.atomic)}catch{fail("marker")};fflush(nil);raise(SIGSTOP);fail("resumed")}
final class BoundaryDefaults:UserDefaults {
 var armed=false
 override func set(_ value:Any?,forKey key:String){
  if armed && key==newKey {pause("before_set")}
  super.set(value,forKey:key)
  if armed && key==newKey {pause("after_set");guard super.synchronize() else{fail("flush")};pause("after_flush")}
 }
}
guard let defaults=BoundaryDefaults(suiteName:suite) else{fail("suite")}
final class ActualHostSave {
 var profiles:[Record]=[]
 let profilesKey=NativeStorageMigration.newKey(for:"SelectiveRemote.connectionProfiles.v2")!
 let defaults:BoundaryDefaults
 init(defaults:BoundaryDefaults){self.defaults=defaults}
 // HOST_SAVE_BODY
}
func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
if mode=="seed" {
 defaults.removePersistentDomain(forName:suite);let data=try JSONEncoder().encode([original]);defaults.set(data,forKey:oldKey);defaults.set(data,forKey:newKey);guard defaults.synchronize() else{fail("seed flush")};print("HOST_SEED=PASS")
} else if mode=="fault" {
 let lease=try NativeStorageLease(directory:lockRoot);let app=ActualHostSave(defaults:defaults);app.profiles=[original,addition];defaults.armed=true;app.saveProfiles();withExtendedLifetime(lease){};fail("boundary not reached")
} else if mode=="recover" {
 let lease=try NativeStorageLease(directory:lockRoot)
 guard let old=defaults.data(forKey:oldKey),let current=defaults.data(forKey:newKey),try JSONDecoder().decode([Record].self,from:old)==[original] else{fail("legacy data lost")}
 let records=try JSONDecoder().decode([Record].self,from:current),valid=records==[original] || records==[original,addition]
 guard valid,point != "before_set" || records==[original],point != "after_flush" || records==[original,addition] else{fail("partial or wrong host data")}
 print("HOST_CRASH_RECOVERY=PASS boundary=\(point) state=\(records.count==1 ? "old":"new") legacy_sha256=\(hash(old)) current_sha256=\(hash(current)) ids=\(records.map{$0.id}.joined(separator:","))")
 withExtendedLifetime(lease){}
} else{fail("unknown mode")}
