import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never { fputs("SYNTHETIC_PROMPT_BLOCKED: \(message)\n", stderr); exit(2) }
let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
var console = stat()
guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted", env["USER"] == "runner",
      getuid() > 0, stat("/dev/console", &console) == 0, console.st_uid == getuid(),
      let temp = env["RUNNER_TEMP"], args.count == 5, ["031", "032"].contains(args[3]), ["probe", "candidate"].contains(args[4]),
      args[1] == temp + "/synthetic-keychain-password", let observedPID = Int32(args[2]), observedPID > 1,
      AXIsProcessTrusted(), CGPreflightPostEventAccess() else { fail("runner identity or permissions") }
if args[4] == "candidate" {
    typealias PidPath = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>, Int32) -> Int32
    guard args[3] == "031", let expected = env["SR_EXPECTED_EXECUTABLE"], expected.hasPrefix(temp + "/candidate-mount/"),
          let expectedHash = env["SR_EXPECTED_HASH"], expectedHash.count == 64,
          let lib = dlopen("/usr/lib/libproc.dylib", RTLD_NOW), let symbol = dlsym(lib, "proc_pidpath"),
          let sandbox = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW),
          let checkSymbol = dlsym(sandbox, "sandbox_check") else { fail("candidate identity configuration") }
    let pathFn = unsafeBitCast(symbol, to: PidPath.self)
    var buffer = [CChar](repeating: 0, count: 4096)
    guard buffer.withUnsafeMutableBytes({ pathFn(observedPID, $0.baseAddress!, UInt32($0.count)) }) > 0 else { fail("candidate process path") }
    let actual = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    let expectedPath = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
    let check = unsafeBitCast(checkSymbol, to: SandboxCheck.self)
    guard actual == expectedPath, let bytes = try? Data(contentsOf: URL(fileURLWithPath: actual), options: .mappedIfSafe),
          SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedHash,
          "network-outbound".withCString({ check(observedPID, $0, 0) }) == 1 else { fail("candidate process identity") }
}
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
            let requester = args[4] == "candidate" ? "Selective Remote" : "keychain-probe"
            guard labels.contains("selective-remote-synthetic"), labels.contains(requester),
                  labels.contains(service) else { continue }
            let fields = nodes.filter { (attribute($0, "AXRole") as? String) == "AXTextField" || (attribute($0, "AXRole") as? String) == "AXSecureTextField" }
            let buttons = nodes.filter { (attribute($0, "AXRole") as? String) == "AXButton" &&
                ((attribute($0, "AXTitle") as? String) == "Allow" || (attribute($0, "AXDescription") as? String) == "Allow") }
            guard fields.count == 1, buttons.count == 1 else { fail("ambiguous security prompt") }
            _ = agent.activate(options: [])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == agent.processIdentifier,
                  AXUIElementSetAttributeValue(fields[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { fail("security prompt focus") }
            guard let clearDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let clearUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { fail("security prompt clear") }
            clearDown.flags = .maskCommand; clearUp.flags = .maskCommand
            clearDown.post(tap: .cghidEventTap); clearUp.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            for character in secret {
                guard let stroke = syntheticKeyStroke(character), !stroke.shift,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == agent.processIdentifier,
                      let down = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: false) else { fail("security prompt input") }
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            }
            guard AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { fail("security prompt allow") }
            print("SYNTHETIC_KEYCHAIN_ALLOW=REQUESTED")
            exit(0)
        }
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}
fail("matching synthetic security prompt not accessible")
