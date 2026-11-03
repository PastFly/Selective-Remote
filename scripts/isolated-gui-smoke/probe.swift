import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

typealias PidPath = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>, Int32) -> Int32
func stop(_ message: String) -> Never { fputs("BLOCKED: \(message)\n", stderr); exit(2) }
let env = ProcessInfo.processInfo.environment
guard env["GITHUB_ACTIONS"] == "true", let expected = env["SR_EXPECTED_EXECUTABLE"],
      let expectedHash = env["SR_EXPECTED_HASH"], let temp = env["RUNNER_TEMP"],
      expected.hasPrefix(temp + "/candidate-mount/"), expectedHash.count == 64,
      [2, 3].contains(CommandLine.arguments.count), let pid = Int32(CommandLine.arguments[1]), pid > 1,
      let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { stop("runner or process identity") }
guard let lib = dlopen("/usr/lib/libproc.dylib", RTLD_NOW), let symbol = dlsym(lib, "proc_pidpath") else { stop("process path unavailable") }
let pathFn = unsafeBitCast(symbol, to: PidPath.self)
var buffer = [CChar](repeating: 0, count: 4096)
let count = buffer.withUnsafeMutableBytes { pathFn(pid, $0.baseAddress!, UInt32($0.count)) }
guard count > 0 else { stop("process path") }
let actual = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
let expectedPath = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
guard actual == expectedPath, let bytes = try? Data(contentsOf: URL(fileURLWithPath: actual), options: .mappedIfSafe),
      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedHash else { stop("wrong executable") }
guard let sandbox = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW),
      let checkSymbol = dlsym(sandbox, "sandbox_check") else { stop("network policy unavailable") }
let check = unsafeBitCast(checkSymbol, to: SandboxCheck.self)
guard "network-outbound".withCString({ check(pid, $0, 0) }) == 1 else { stop("network restriction unverified") }
if CommandLine.arguments.count == 3 {
    guard CommandLine.arguments[2] == "--terminate", running.terminate() else { stop("graceful termination request failed") }
    let deadline = Date(timeIntervalSinceNow: 15)
    while !running.isTerminated && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
    guard running.isTerminated else { stop("application did not terminate") }
    print("APPLICATION_GRACEFUL_TERMINATION=YES")
    exit(0)
}
guard AXIsProcessTrusted() else { stop("Accessibility unavailable") }
let app = AXUIElementCreateApplication(pid)
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func snapshot(_ root: AXUIElement) -> [AXUIElement] {
    var pending = [root], result = [AXUIElement]()
    while let element = pending.popLast(), result.count < 5000 {
        if result.contains(where: { CFEqual($0, element) }) { continue }
        result.append(element)
        if let children = attr(element, "AXChildren") as? [AXUIElement] { pending.append(contentsOf: children.reversed()) }
    }
    return result
}
var raw: CFTypeRef?
let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
guard result == .success, let windows = raw as? [AXUIElement], !windows.isEmpty else { stop("no accessible app window") }
print("APP_PID=\(pid)")
print("ACCESSIBLE_WINDOW_COUNT=\(windows.count)")
func pressUnique(_ role: String, _ label: String) {
    let matches = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == role &&
        ((attr($0, "AXTitle") as? String) == label || (attr($0, "AXDescription") as? String) == label)
    }
    guard matches.count == 1 else { stop("unique control unavailable: \(label)") }
    guard AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success else { stop("action failed: \(label)") }
    Thread.sleep(forTimeInterval: 1)
}
pressUnique("AXButton", "Done")
let remainingWelcome = snapshot(app).filter {
    (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
}
guard remainingWelcome.isEmpty else { stop("welcome remains open") }
print("WELCOME_CLOSED=YES")
if env["SR_BUILD_KIND"] == "baseline" {
pressUnique("AXButton", "Connections")
print("CONNECTIONS_OPEN_REQUESTED=YES")
pressUnique("AXPopUpButton", "Add")
pressUnique("AXMenuItem", "New SSH")
print("SYNTHETIC_PROFILE_CREATION_REQUESTED=YES")
func setUniqueField(_ placeholder: String, _ value: String) {
    let matches = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder
    }
    guard matches.count == 1 else { stop("unique field unavailable: \(placeholder)") }
    guard CGPreflightPostEventAccess(), running.activate(options: [.activateIgnoringOtherApps]) else { stop("input permission or activation") }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          AXUIElementSetAttributeValue(matches[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { stop("input focus") }
    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { stop("keyboard event") }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    key(0, down: true, flags: .maskCommand); key(0, down: false, flags: .maskCommand)
    for character in value {
        guard let stroke = syntheticKeyStroke(character),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop("unsupported input or focus") }
        let flags: CGEventFlags = stroke.shift ? .maskShift : []
        key(stroke.code, down: true, flags: flags)
        key(stroke.code, down: false, flags: flags)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
    }
    let deadline = Date(timeIntervalSinceNow: 5)
    var confirmed = false
    while Date() < deadline {
        let current = snapshot(app).filter {
            (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder
        }
        if current.count == 1 && (attr(current[0], "AXValue") as? String) == value { confirmed = true; break }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }
    guard confirmed else { stop("typed field not confirmed: \(placeholder)") }
    key(48, down: true); key(48, down: false)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
}
setUniqueField("SSH Server", "TEST-ONLY-CODEX-UPGRADE-HOST")
setUniqueField("For example: Work", "TEST-ONLY-CODEX-UPGRADE-FOLDER")
setUniqueField("server.example.com or a Host from ~/.ssh/config", "192.0.2.10")
setUniqueField("username", "test")
print("SYNTHETIC_PROFILE_FIELDS_ENTERED=YES")
} else if env["SR_BUILD_KIND"] == "candidate" {
    print("CANDIDATE_WINDOW_INSPECTION=YES")
} else { stop("unknown build kind") }
for element in snapshot(app).prefix(500) {
    let role = attr(element, "AXRole") as? String ?? ""
    let title = attr(element, "AXTitle") as? String ?? ""
    let description = attr(element, "AXDescription") as? String ?? ""
    let placeholder = attr(element, "AXPlaceholderValue") as? String ?? ""
    if !title.isEmpty || !description.isEmpty || !placeholder.isEmpty {
        print("AX_NODE role=\(role) title=\(title) description=\(description) placeholder=\(placeholder)")
    }
}
print("PRODUCT_CONNECTION_E2E=NOT_RUN")
print("UPGRADE_E2E=NOT_RUN")
