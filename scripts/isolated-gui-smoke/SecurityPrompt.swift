import AppKit
import ApplicationServices
import Darwin
import Foundation

func fail(_ message: String) -> Never { fputs("SYNTHETIC_PROMPT_BLOCKED: \(message)\n", stderr); exit(2) }
let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
var console = stat()
guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted", env["USER"] == "runner",
      getuid() > 0, stat("/dev/console", &console) == 0, console.st_uid == getuid(),
      let temp = env["RUNNER_TEMP"], args.count == 4, ["031", "032"].contains(args[3]),
      args[1] == temp + "/synthetic-keychain-password", let observedPID = Int32(args[2]), observedPID > 1,
      AXIsProcessTrusted(), CGPreflightPostEventAccess() else { fail("runner identity or permissions") }
var file = stat()
guard lstat(args[1], &file) == 0, (file.st_mode & S_IFMT) == S_IFREG, file.st_uid == getuid(),
      (file.st_mode & 0o777) == 0o600, file.st_nlink == 1,
      let secret = try? String(contentsOfFile: args[1], encoding: .utf8), secret.count == 48,
      secret.allSatisfy({ "0123456789abcdef".contains($0) }) else { fail("synthetic password file") }
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func snapshot(_ root: AXUIElement) -> [AXUIElement] {
    var pending = [root], result = [AXUIElement]()
    while let element = pending.popLast(), result.count < 1000 {
        if result.contains(where: { CFEqual($0, element) }) { continue }
        result.append(element)
        if let children = attribute(element, "AXChildren") as? [AXUIElement] { pending.append(contentsOf: children) }
    }
    return result
}
let deadline = Date(timeIntervalSinceNow: 18)
var reported = Set<pid_t>()
while Date() < deadline {
    if kill(observedPID, 0) != 0 { print("SYNTHETIC_PROMPT=NOT_NEEDED"); exit(0) }
    for agent in NSWorkspace.shared.runningApplications where agent.localizedName == "SecurityAgent" {
        if reported.insert(agent.processIdentifier).inserted {
            print("SECURITY_AGENT bundle=\(agent.bundleURL?.path ?? "none") pid=\(agent.processIdentifier)")
            let root = AXUIElementCreateApplication(agent.processIdentifier)
            print("SECURITY_AGENT_AX_ROLES=\(snapshot(root).compactMap { attribute($0, "AXRole") as? String }.joined(separator: ","))")
        }
        guard let path = agent.bundleURL?.resolvingSymlinksInPath().path,
              path == "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle" else { continue }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        for window in snapshot(root).filter({ (attribute($0, "AXRole") as? String) == "AXWindow" }) {
            let nodes = snapshot(window)
            let labels = nodes.flatMap { node -> [String] in
                ["AXTitle", "AXDescription", "AXHelp"].compactMap { attribute(node, $0) as? String }
                + (((attribute(node, "AXRole") as? String) == "AXStaticText") ? [attribute(node, "AXValue") as? String].compactMap { $0 } : [])
            }.joined(separator: " ")
            let service = "local.selectiveremote.credentials.unified." + (args[3] == "031" ? "v1" : "v2")
            guard labels.contains("selective-remote-synthetic"), labels.contains("keychain-probe"),
                  labels.contains(service) else { continue }
            let fields = nodes.filter { (attribute($0, "AXRole") as? String) == "AXTextField" || (attribute($0, "AXRole") as? String) == "AXSecureTextField" }
            let buttons = nodes.filter { (attribute($0, "AXRole") as? String) == "AXButton" &&
                ((attribute($0, "AXTitle") as? String) == "Allow" || (attribute($0, "AXDescription") as? String) == "Allow") }
            guard fields.count == 1, buttons.count == 1 else { fail("ambiguous security prompt") }
            _ = agent.activate(options: [])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == agent.processIdentifier,
                  AXUIElementSetAttributeValue(fields[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { fail("security prompt focus") }
            for character in secret {
                guard let stroke = syntheticKeyStroke(character), !stroke.shift,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == agent.processIdentifier,
                      let down = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: false) else { fail("security prompt input") }
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            guard AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { fail("security prompt allow") }
            print("SYNTHETIC_KEYCHAIN_ALLOW=REQUESTED")
            exit(0)
        }
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}
fail("matching synthetic security prompt not accessible")
