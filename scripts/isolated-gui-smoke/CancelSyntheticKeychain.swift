import AppKit
import ApplicationServices
import Foundation
func attribute(_ e: AXUIElement,_ k:String)->CFTypeRef? { var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v : nil }
func nodes(_ root:AXUIElement)->[AXUIElement] { var q=[root],r:[AXUIElement]=[];while let e=q.popLast(),r.count<1000 { if r.contains(where:{CFEqual($0,e)}) {continue};r.append(e);if let c=attribute(e,"AXChildren") as? [AXUIElement] {q.append(contentsOf:c)} };return r }
let env=ProcessInfo.processInfo.environment
guard env["GITHUB_ACTIONS"]=="true",env["RUNNER_ENVIRONMENT"]=="github-hosted",env["USER"]=="runner",AXIsProcessTrusted() else {exit(2)}
let until=Date(timeIntervalSinceNow:35)
while Date()<until {
 for agent in NSWorkspace.shared.runningApplications where agent.localizedName == "SecurityAgent" {
  guard agent.bundleURL?.resolvingSymlinksInPath().path == "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle" else {continue}
  let tree=nodes(AXUIElementCreateApplication(agent.processIdentifier))
  let labels=tree.flatMap { e in ["AXTitle","AXDescription","AXValue"].compactMap {attribute(e,$0) as? String} }.joined(separator:" ")
  guard labels.contains("selective-remote-synthetic") else {continue}
  let buttons=tree.filter { element in (attribute(element,"AXRole") as? String)=="AXButton" && ["AXTitle","AXDescription"].contains { key in ["Cancel","Отмена"].contains((attribute(element,key) as? String) ?? "") } }
  if buttons.count==1 && AXUIElementPerformAction(buttons[0],kAXPressAction as CFString) == .success { print("SYNTHETIC_KEYCHAIN_UNLOCK_CANCELLED=YES"); exit(0) }
 }
 RunLoop.current.run(until:Date(timeIntervalSinceNow:0.2))
}
fputs("SYNTHETIC_KEYCHAIN_UNLOCK_CANCELLED=NO\n",stderr);exit(2)
