import Foundation
import CryptoKit
import Darwin

struct TerminalRemoteContextSnapshot: Encodable {static let empty=Self()}
let env=ProcessInfo.processInfo.environment,args=CommandLine.arguments
func fail(_ text:String)->Never {fputs("SNIPPET_FAULT_ERROR: \(text)\n",stderr);exit(2)}
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner",
      let temp=env["RUNNER_TEMP"],let run=env["GITHUB_RUN_ID"],let root=env["SR_SNIPPET_FAULT_ROOT"],
      root==temp+"/snippet-write-boundaries",args.count==3,
      args[2].allSatisfy({$0.isLetter || $0.isNumber || $0=="_"}) else {fail("runner identity")}
let mode=args[1],point=args[2],suite="TEST-ONLY-CODEX-SNIPPETS-\(run)-\(point)"
let groupKey=NativeStorageMigration.newKey(for:"SelectiveRemote.terminal.snippetGroups.v1")!
let templateKey=NativeStorageMigration.newKey(for:"SelectiveRemote.terminal.commandTemplates.v1")!
let lockRoot=URL(fileURLWithPath:root).appendingPathComponent("lock-\(point)",isDirectory:true)
let marker=URL(fileURLWithPath:root).appendingPathComponent("stopped-\(point)")
let groupID=UUID(uuidString:"11111111-1111-4111-8111-111111111111")!
let templateID=UUID(uuidString:"22222222-2222-4222-8222-222222222222")!
func pause(_ name:String) {
    guard mode=="fault",point==name else {return}
    do {try Data(name.utf8).write(to:marker,options:.atomic)} catch {fail("marker")}
    fflush(nil);raise(SIGSTOP);fail("resumed without kill")
}
final class BoundaryDefaults: UserDefaults {
    var armed=false
    override func set(_ value:Any?,forKey key:String) {
        if armed && key==groupKey {pause("before_group")}
        super.set(value,forKey:key)
        if armed && key==groupKey {guard super.synchronize() else {fail("group sync")};pause("after_group")}
        if armed && key==templateKey {guard super.synchronize() else {fail("template sync")};pause("after_template")}
    }
}
guard let defaults=BoundaryDefaults(suiteName:suite) else {fail("suite")}
@MainActor func exercise() throws {
    let global=TerminalCommandHistoryStore.globalSnippetLibraryID
    if mode=="seed" {
        defaults.removePersistentDomain(forName:suite)
        let stamp=Date(timeIntervalSince1970:1_700_000_000)
        let group=TerminalSnippetGroup(id:groupID,profileID:global,name:"TEST-ONLY-OLD-GROUP",createdAt:stamp)
        let template=TerminalCommandTemplate(id:templateID,profileID:global,title:"TEST-ONLY-SNIPPET",command:"echo TEST-ONLY",category:group.name,groupID:groupID,targets:[.localTerminal],updatedAt:stamp)
        defaults.set(try JSONEncoder().encode([group]),forKey:groupKey)
        defaults.set(try JSONEncoder().encode([template]),forKey:templateKey)
        guard defaults.synchronize() else {fail("seed sync")}
        print("SNIPPET_SEED=PASS")
    } else if mode=="fault" {
        let lease=try NativeStorageLease(directory:lockRoot)
        let store=TerminalCommandHistoryStore(defaults:defaults)
        guard store.snippetGroups().contains(where:{$0.id==groupID && $0.name=="TEST-ONLY-OLD-GROUP"}),store.templates().contains(where:{$0.id==templateID}) else {fail("initial state")}
        defaults.armed=true
        _=store.renameSnippetGroup(id:groupID,name:"TEST-ONLY-NEW-GROUP",profileID:global)
        withExtendedLifetime(lease) {}
        fail("boundary not reached")
    } else if mode=="recover" {
        let lease=try NativeStorageLease(directory:lockRoot)
        let store=TerminalCommandHistoryStore(defaults:defaults)
        let groups=store.snippetGroups(),templates=store.templates()
        let report:[String:Any]=["groups":groups.map{["id":$0.id.uuidString,"name":$0.name]},"templates":templates.map{["id":$0.id.uuidString,"category":$0.category,"groupID":$0.groupID.uuidString]},"boundary":point]
        let reportData=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
        print("SNIPPET_RECOVERED=\(String(decoding:reportData,as:UTF8.self))")
        fflush(stdout)
        let old = groups.count==1 && groups[0].id==groupID && groups[0].name=="TEST-ONLY-OLD-GROUP" && templates.count==1 && templates[0].id==templateID && templates[0].groupID==groupID && templates[0].category=="TEST-ONLY-OLD-GROUP"
        let new = groups.count==1 && groups[0].id==groupID && groups[0].name=="TEST-ONLY-NEW-GROUP" && templates.count==1 && templates[0].id==templateID && templates[0].groupID==groupID && templates[0].category=="TEST-ONLY-NEW-GROUP"
        guard old || new else {fail("partially committed group rename")}
        print("SNIPPET_ATOMIC_RECOVERY=PASS state=\(old ? "old":"new")")
        withExtendedLifetime(lease) {}
    } else {fail("unknown mode")}
}
Task { @MainActor in
    do {try exercise();exit(0)} catch {fail("operation: \(error)")}
}
dispatchMain()
