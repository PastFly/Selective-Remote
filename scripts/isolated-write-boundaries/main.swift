import Foundation
import CryptoKit
import Darwin

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
func fail(_ text: String) -> Never { fputs("FAULT_FIXTURE_ERROR: \(text)\n", stderr); exit(2) }
guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted", env["USER"] == "runner",
      let temp = env["RUNNER_TEMP"], let run = env["GITHUB_RUN_ID"], args.count == 4,
      let root = env["SR_FAULT_ROOT"], root == temp + "/native-write-boundaries",
      args[2].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { fail("runner identity") }
let mode=args[1], point=args[2], suite="TEST-ONLY-CODEX-\(run)-\(point)"
guard let defaults=UserDefaults(suiteName:suite) else { fail("suite") }
let lockRoot=URL(fileURLWithPath:root).appendingPathComponent("lock-\(point)",isDirectory:true)
let marker=URL(fileURLWithPath:root).appendingPathComponent("stopped-\(point)")
let host="SelectiveRemote.connectionProfiles.v2"
let snippets="SelectiveRemote.terminal.commandTemplates.v1"
let groups="SelectiveRemote.terminal.snippetGroups.v1"
let snapshot="SelectiveRemote.native032.migration.snapshot.v1"
let complete="SelectiveRemote.native032.migration.complete.v1"
let newHost=NativeStorageMigration.newKey(for:host)!
let newSnippets=NativeStorageMigration.newKey(for:snippets)!
let newGroups=NativeStorageMigration.newKey(for:groups)!
let oldHost=Data("[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"friendlyName\":\"TEST-ONLY-CODEX-HOST-OLD\"}]".utf8)
let newHostData=Data("[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"friendlyName\":\"TEST-ONLY-CODEX-HOST-NEW\"}]".utf8)
let oldSnippets=Data("[{\"id\":\"22222222-2222-4222-8222-222222222222\",\"name\":\"TEST-ONLY-CODEX-SNIPPET-OLD\"}]".utf8)
let newSnippetsData=Data("[{\"id\":\"22222222-2222-4222-8222-222222222222\",\"name\":\"TEST-ONLY-CODEX-SNIPPET-NEW\"}]".utf8)
let oldGroups=Data("[{\"id\":\"33333333-3333-4333-8333-333333333333\",\"name\":\"TEST-ONLY-CODEX-GROUP-OLD\"}]".utf8)
let newGroupsData=Data("[{\"id\":\"33333333-3333-4333-8333-333333333333\",\"name\":\"TEST-ONLY-CODEX-GROUP-NEW\"}]".utf8)
func pause(_ event:String) {
    guard event==point else { return }
    do { try Data(event.utf8).write(to:marker, options:.atomic) } catch { fail("boundary marker") }
    fflush(nil)
    raise(SIGSTOP)
    fail("fault process resumed without kill")
}
final class BoundaryDefaults: NativePreferencesAccess {
    let backing: UserDefaults
    var last: String?
    init(_ backing:UserDefaults) {self.backing=backing}
    func object(forKey key:String)->Any? {backing.object(forKey:key)}
    func dictionaryRepresentation()->[String:Any] {backing.dictionaryRepresentation()}
    func set(_ value:Any?,forKey key:String) {
        if key==snapshot {pause("before_snapshot_set")}
        if key==newHost {pause("before_host_set")}
        if key==complete {pause("before_marker_set")}
        backing.set(value,forKey:key);last=key
        if key==snapshot {pause("after_snapshot_set")}
        if key==newHost {pause("after_host_set")}
        if key==newSnippets {pause("after_snippets_set")}
        if key==newGroups {pause("after_groups_set")}
        if key==complete {pause("after_marker_set")}
    }
    func synchronize()->Bool {
        let ok=backing.synchronize()
        if last==snapshot {pause("after_snapshot_sync")}
        if last==complete {pause("after_marker_sync")}
        last=nil;return ok
    }
}
func checkedData(_ key:String,_ expected:Data) {guard defaults.data(forKey:key)==expected else {fail("mismatch \(key)")}}
if mode=="seed" {
    defaults.removePersistentDomain(forName:suite)
    defaults.set(oldHost,forKey:host);defaults.set(oldSnippets,forKey:snippets);defaults.set(oldGroups,forKey:groups)
    guard defaults.synchronize() else {fail("seed sync")}
    print("SYNTHETIC_SEED=PASS")
} else if mode=="fault" {
    let lease=try NativeStorageLease(directory:lockRoot)
    withExtendedLifetime(lease) { try! NativeStorageMigration.prepare(BoundaryDefaults(defaults)) }
    fail("boundary not reached")
} else if mode=="busy" {
    do { _ = try NativeStorageLease(directory:lockRoot);fail("lock unexpectedly acquired") }
    catch NativeStorageLease.LeaseError.busy { print("SYNTHETIC_FAULT_LOCK=BUSY") }
    catch {fail("unexpected lock error")}
} else if mode=="recover" {
    let lease=try NativeStorageLease(directory:lockRoot)
    try NativeStorageMigration.prepare(defaults)
    checkedData(host,oldHost);checkedData(snippets,oldSnippets);checkedData(groups,oldGroups)
    checkedData(newHost,oldHost);checkedData(newSnippets,oldSnippets);checkedData(newGroups,oldGroups)
    guard defaults.string(forKey:complete)?.hasPrefix("complete:")==true,
          defaults.data(forKey:snapshot) != nil, defaults.synchronize() else {fail("checkpoint")}
    let digest=SHA256.hash(data:defaults.data(forKey:snapshot)!).map {String(format:"%02x",$0)}.joined()
    print("SYNTHETIC_RECOVERY=PASS point=\(point) snapshot_sha256=\(digest)")
    withExtendedLifetime(lease) {}
} else {fail("unknown mode")}
