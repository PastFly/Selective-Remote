import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never { fputs("SYNTHETIC_ASKPASS_BLOCKED: \(message)\n", stderr); exit(2) }
typealias PidPath = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
let env = ProcessInfo.processInfo.environment
var console = stat()
guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted", env["USER"] == "runner",
      getuid() > 0, stat("/dev/console", &console) == 0, console.st_uid == getuid(),
      let temp = env["RUNNER_TEMP"], let expectedHash = env["SR_EXPECTED_ASKPASS_HASH"], expectedHash.count == 64,
      CommandLine.arguments.count == 2, let appPID = Int32(CommandLine.arguments[1]), appPID > 1,
      AXIsProcessTrusted(), CGPreflightPostEventAccess() else { fail("runner identity or permissions") }
let helper = temp + "/candidate-mount/Selective Remote.app/Contents/Helpers/SelectiveRemoteSSHAskPass"
let key = temp + "/ssh-key-fixture/key"
var file = stat()
guard lstat(key, &file) == 0, (file.st_mode & S_IFMT) == S_IFREG, file.st_uid == getuid(),
      (file.st_mode & 0o777) == 0o600, file.st_nlink == 1,
      let bytes = try? Data(contentsOf: URL(fileURLWithPath: helper), options: .mappedIfSafe),
      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedHash,
      let lib = dlopen("/usr/lib/libproc.dylib", RTLD_NOW), let symbol = dlsym(lib, "proc_pidpath") else { fail("synthetic fixture or helper") }
let pathFn = unsafeBitCast(symbol, to: PidPath.self)
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
let deadline = Date(timeIntervalSinceNow: 35)
while Date() < deadline {
    guard kill(appPID, 0) == 0 else { fail("target app terminated") }
    for app in NSWorkspace.shared.runningApplications {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard buffer.withUnsafeMutableBytes({ pathFn(app.processIdentifier, $0.baseAddress!, UInt32($0.count)) }) > 0 else { continue }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        guard path == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path else { continue }
        let nodes = snapshot(AXUIElementCreateApplication(app.processIdentifier))
        let labels = nodes.flatMap { node -> [String] in
            ["AXTitle", "AXDescription", "AXHelp"].compactMap { attribute(node, $0) as? String }
            + (((attribute(node, "AXRole") as? String) == "AXStaticText") ? [attribute(node, "AXValue") as? String].compactMap { $0 } : [])
        }.joined(separator: " ")
        guard labels.contains("SSH Key Passphrase"), labels.contains(key) else { continue }
        let fields = nodes.filter { (attribute($0, "AXRole") as? String) == "AXTextField" && (attribute($0, "AXPlaceholderValue") as? String) == "Passphrase" }
        let buttons = nodes.filter { (attribute($0, "AXRole") as? String) == "AXButton" && ((attribute($0, "AXTitle") as? String) == "Continue" || (attribute($0, "AXDescription") as? String) == "Continue") }
        guard fields.count == 1, buttons.count == 1 else { fail("ambiguous AskPass prompt") }
        _ = app.activate(options: [])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              AXUIElementSetAttributeValue(fields[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { fail("AskPass focus") }
        for character in "TESTONLYCODEXPASSPHRASE" {
            guard let stroke = syntheticKeyStroke(character), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: false) else { fail("AskPass input") }
            let flags: CGEventFlags = stroke.shift ? .maskShift : []
            down.flags = flags; up.flags = flags; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { fail("AskPass confirmation") }
        print("SYNTHETIC_ASKPASS_ENTERED=YES")
        exit(0)
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}
fail("matching synthetic AskPass prompt unavailable")
