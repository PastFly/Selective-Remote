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
      (expected.hasPrefix(temp + "/candidate-mount/") || expected.hasPrefix(temp + "/candidate-mount2/")), expectedHash.count == 64,
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
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--terminate" {
    guard running.terminate() else { stop("graceful termination request failed") }
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
var windows: [AXUIElement] = []
if CommandLine.arguments.contains("--race-folder") || CommandLine.arguments.contains("--race-favorite") {
    _ = running.activate(options: [.activateIgnoringOtherApps])
}
let windowDeadline = Date(timeIntervalSinceNow: 15)
while Date() < windowDeadline {
    var raw: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
    if result == .success, let found = raw as? [AXUIElement], !found.isEmpty { windows = found; break }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
}
guard !windows.isEmpty else { stop("no accessible app window for pid \(pid)") }
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
func setUniqueField(_ placeholder: String, _ value: String, verifyVisibleValue: Bool = true, preferTopmost: Bool = false) {
    var matches = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder
    }
    if preferTopmost && matches.count > 1 {
        let positioned = matches.compactMap { element -> (AXUIElement, CGFloat)? in
            guard let raw = attr(element, "AXPosition"), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point) else { return nil }
            return (element, point.y)
        }.sorted { $0.1 < $1.1 }
        guard positioned.count == matches.count, positioned[0].1 < positioned[1].1 else { stop("ambiguous topmost field: \(placeholder)") }
        matches = [positioned[0].0]
    }
    if matches.count != 1 { print("SYNTHETIC_FIELD_MATCHES placeholder=\(placeholder) count=\(matches.count)") }
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
        if preferTopmost && ((attr(matches[0], "AXValue") as? String) == value) { confirmed = true; break }
        let current = snapshot(app).filter {
            (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder
        }
        if current.count == 1 {
            let fieldValue = attr(current[0], "AXValue")
            if (fieldValue as? String) == value || (fieldValue as? NSNumber)?.stringValue == value {
                confirmed = true; break
            }
            if placeholder == "22", let formatted = fieldValue as? String,
               syntheticPortMatches(formatted, value) {
                confirmed = true; break
            }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }
    if verifyVisibleValue && !confirmed {
        for _ in 0..<2 where !confirmed {
            let retry = snapshot(app).filter {
                (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder
            }
            guard retry.count == 1, running.activate(options: [.activateIgnoringOtherApps]) else { stop("retry input field") }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  AXUIElementSetAttributeValue(retry[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { stop("retry input focus") }
            key(0, down: true, flags: .maskCommand); key(0, down: false, flags: .maskCommand)
            for character in value {
                guard let stroke = syntheticKeyStroke(character), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop("retry input focus changed") }
                let flags: CGEventFlags = stroke.shift ? .maskShift : []
                key(stroke.code, down: true, flags: flags); key(stroke.code, down: false, flags: flags)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            }
            let retryDeadline = Date(timeIntervalSinceNow: 5)
            while Date() < retryDeadline {
                let current = snapshot(app).filter {
                    (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder
                }
                let fieldValue = current.count == 1 ? attr(current[0], "AXValue") : nil
                if (fieldValue as? String) == value || (fieldValue as? NSNumber)?.stringValue == value ||
                   (placeholder == "22" && (fieldValue as? String).map { syntheticPortMatches($0, value) } == true) {
                    confirmed = true; break
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            }
        }
    }
    if verifyVisibleValue && !confirmed {
        if placeholder == "22" {
            let current = snapshot(app).filter { (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder }
            let originalValue = attr(matches[0], "AXValue")
            print("SYNTHETIC_PORT_DIAGNOSTIC matches=\(current.count) string=\(originalValue as? String ?? "none") number=\((originalValue as? NSNumber)?.stringValue ?? "none")")
        }
        stop("typed field not confirmed: \(placeholder)")
    }
    key(48, down: true); key(48, down: false)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
}
if CommandLine.arguments.count == 3 && ["--race-name", "--race-folder", "--race-favorite"].contains(CommandLine.arguments[2]) {
    guard env["SR_BUILD_KIND"] == "candidate" else { stop("race requires candidate") }
    let mode = CommandLine.arguments[2]
    if mode == "--race-name" {
        setUniqueField("SSH Server", "TEST-ONLY-CODEX-RACE-NAME")
        print("SYNTHETIC_RACE_NAME_REQUESTED=YES")
    } else if mode == "--race-folder" {
        setUniqueField("For example: Work/Servers/Linux", "TEST-ONLY-CODEX-RACE-FOLDER")
        print("SYNTHETIC_RACE_FOLDER_REQUESTED=YES")
    } else {
        guard let ready = env["SR_RACE_READY"], let go = env["SR_RACE_GO"] else { stop("race barrier missing") }
        let controls = snapshot(app).filter { element in
            (attr(element, "AXRole") as? String) == "AXButton" &&
            ["AXHelp", "AXDescription", "AXTitle"].contains { (attr(element, $0) as? String) == "Favorite" }
        }
        guard controls.count == 1 else { stop("race favorite not unique") }
        do { try Data("ready".utf8).write(to: URL(fileURLWithPath: ready), options: .withoutOverwriting) } catch { stop("race ready flag") }
        let deadline = Date(timeIntervalSinceNow: 30)
        while !FileManager.default.fileExists(atPath: go) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard FileManager.default.fileExists(atPath: go) else { stop("race barrier timeout") }
        let start = ProcessInfo.processInfo.systemUptime
        guard AXUIElementPerformAction(controls[0], kAXPressAction as CFString) == .success else { stop("race favorite action") }
        print("SYNTHETIC_RACE_ACTION_UPTIME=\(start)")
        Thread.sleep(forTimeInterval: 2)
    }
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--edit-current-host" {
    guard env["SR_BUILD_KIND"] == "candidate" else { stop("host edit requires candidate") }
    setUniqueField("SSH Server", "TEST-ONLY-CODEX-EDITED")
    setUniqueField("For example: Work/Servers/Linux", "TEST-ONLY-CODEX-NEW-FOLDER")
    print("QA_SYNTHETIC_HOST_EDIT_REQUESTED=YES")
    exit(0)
}
if CommandLine.arguments.count == 3 && ["--duplicate-selected", "--delete-selected", "--toggle-favorite"].contains(CommandLine.arguments[2]) {
    guard env["SR_BUILD_KIND"] == "candidate" else { stop("host action requires candidate") }
    let deleting = CommandLine.arguments[2] == "--delete-selected"
    let favorite = CommandLine.arguments[2] == "--toggle-favorite"
    let wanted = deleting ? "Delete Host" : favorite ? "Favorite" : "Duplicate Host"
    let controls = snapshot(app).filter { element in
        (attr(element, "AXRole") as? String) == "AXButton" &&
        ["AXHelp", "AXDescription", "AXTitle"].contains { (attr(element, $0) as? String) == wanted }
    }
    if controls.count != 1 {
        for element in snapshot(app) {
            let role = attr(element, "AXRole") as? String ?? ""
            let title = attr(element, "AXTitle") as? String ?? ""
            let description = attr(element, "AXDescription") as? String ?? ""
            let help = attr(element, "AXHelp") as? String ?? ""
            if role == "AXButton" && (!title.isEmpty || !description.isEmpty || !help.isEmpty) {
                print("QA_BUTTON title=\(title) description=\(description) help=\(help)")
            }
        }
        stop("host control unavailable: \(wanted)")
    }
    if let enabled = attr(controls[0], "AXEnabled") as? Bool, !enabled { stop("host control disabled: \(wanted)") }
    guard AXUIElementPerformAction(controls[0], kAXPressAction as CFString) == .success else { stop("host control action failed: \(wanted)") }
    Thread.sleep(forTimeInterval: 2)
    if deleting {
        let nodes = snapshot(app)
        let prompt = nodes.contains { element in
            ["AXTitle", "AXDescription", "AXValue"].contains { (attr(element, $0) as? String) == "Delete Host?" }
        }
        let target = nodes.contains { element in
            ["AXTitle", "AXDescription", "AXValue"].contains { (attr(element, $0) as? String) == "TEST-ONLY-CODEX-LIVE-NEW — копия" }
        }
        let buttons = nodes.filter { element in
            (attr(element, "AXRole") as? String) == "AXButton" &&
            ["AXTitle", "AXDescription"].contains { (attr(element, $0) as? String) == "Delete" }
        }
        guard prompt, target, buttons.count == 1, CGPreflightPostEventAccess(),
              let position = attr(buttons[0], "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attr(buttons[0], "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { stop("synthetic delete confirmation unavailable") }
        var point = CGPoint.zero; var extent = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent),
              extent.width > 0, extent.height > 0,
              running.activate(options: [.activateIgnoringOtherApps]) else { stop("delete confirmation geometry") }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop("delete confirmation focus") }
        let center = CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) else { stop("delete mouse event") }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 2)
    }
    print("QA_HOST_ACTION_REQUESTED=\(deleting ? "DELETE" : favorite ? "FAVORITE" : "DUPLICATE")")
    exit(0)
}
if CommandLine.arguments.count == 3 && ["--create-late-host", "--create-current-host", "--create-live-old", "--create-live-current"].contains(CommandLine.arguments[2]) {
    let late = ["--create-late-host", "--create-live-old"].contains(CommandLine.arguments[2])
    let live = ["--create-live-old", "--create-live-current"].contains(CommandLine.arguments[2])
    guard env["SR_BUILD_KIND"] == (late ? "baseline" : "candidate") else { stop("mixed-write version mismatch") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    if late { pressUnique("AXButton", "Connections") }
    pressUnique("AXPopUpButton", "Add")
    pressUnique("AXMenuItem", "New SSH")
    setUniqueField("SSH Server", live ? (late ? "TEST-ONLY-CODEX-LIVE-OLD" : "TEST-ONLY-CODEX-LIVE-NEW") : (late ? "TEST-ONLY-CODEX-LATE-HOST" : "TEST-ONLY-CODEX-CURRENT-HOST"))
    setUniqueField(late ? "For example: Work" : "For example: Work/Servers/Linux", "TEST-ONLY-CODEX-MIXED-FOLDER")
    setUniqueField("server.example.com or a Host from ~/.ssh/config", live ? (late ? "192.0.2.13" : "192.0.2.14") : (late ? "192.0.2.11" : "192.0.2.12"))
    setUniqueField("username", "test")
    pressUnique("AXButton", "Authentication")
    setUniqueField("Пароль SSH-сервера", live ? (late ? "TEST-ONLY-CODEX-LIVE-OLD-SECRET" : "TEST-ONLY-CODEX-LIVE-NEW-SECRET") : (late ? "TEST-ONLY-CODEX-LATE-SECRET" : "TEST-ONLY-CODEX-CURRENT-SECRET"), verifyVisibleValue: false)
    pressUnique("AXButton", "Save")
    pressUnique("AXButton", "General")
    print("SYNTHETIC_MIXED_PROFILE_SAVE_REQUESTED=YES")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--inspect-late-host" {
    guard env["SR_BUILD_KIND"] == "candidate" else { stop("mixed inspection version") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    let visible = snapshot(app).contains {
        (attr($0, "AXTitle") as? String) == "TEST-ONLY-CODEX-LATE-HOST" ||
        (attr($0, "AXDescription") as? String) == "TEST-ONLY-CODEX-LATE-HOST"
    }
    print("LATE_LEGACY_HOST_VISIBLE_IN_CURRENT_UI=\(visible)")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--inspect-current-host" {
    guard env["SR_BUILD_KIND"] == "baseline" else { stop("downgrade inspection version") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    pressUnique("AXButton", "Connections")
    let visible = snapshot(app).contains {
        (attr($0, "AXTitle") as? String) == "TEST-ONLY-CODEX-CURRENT-HOST" ||
        (attr($0, "AXDescription") as? String) == "TEST-ONLY-CODEX-CURRENT-HOST"
    }
    print("CURRENT_HOST_VISIBLE_IN_DOWNGRADE_UI=\(visible)")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--inspect-snippets" {
    guard ["snippets", "snippets-current", "snippetfix"].contains(env["SR_BUILD_KIND"] ?? "") else { stop("snippet inspection requires isolated baseline") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    pressUnique("AXButton", "Snippets")
    pressUnique("AXButton", "New Group")
    setUniqueField("Название группы", "TEST-ONLY-CODEX-SNIPPET-GROUP")
    pressUnique("AXButton", "Save")
    print("SYNTHETIC_GROUP_SAVE_REQUESTED=YES")
    pressUnique("AXButton", "TEST-ONLY-CODEX-SNIPPET-GROUP, 0 сниппетов")
    for element in snapshot(app) {
        let role = attr(element, "AXRole") as? String ?? ""
        let description = attr(element, "AXDescription") as? String ?? ""
        let title = attr(element, "AXTitle") as? String ?? ""
        if ["AXButton", "AXPopUpButton"].contains(role), !description.isEmpty || !title.isEmpty {
            print("SNIPPET_FOLDER_NODE role=\(role) title=\(title) description=\(description)")
        }
    }
    let createButtons = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXButton" && (attr($0, "AXDescription") as? String) == "New Snippet"
    }
    guard createButtons.count == 2, AXUIElementPerformAction(createButtons[0], kAXPressAction as CFString) == .success else { stop("snippet folder creation control") }
    Thread.sleep(forTimeInterval: 1)
    Thread.sleep(forTimeInterval: 3)
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", temp + "/evidence/snippet-editor-screen.png"]
    try? capture.run()
    capture.waitUntilExit()
    let system = AXUIElementCreateSystemWide()
    var hitFields = [AXUIElement]()
    for (x, y) in [(450.0, 153.0), (450.0, 300.0), (250.0, 508.0)] {
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit)
        if let hit {
            var hitPID: pid_t = 0
            _ = AXUIElementGetPid(hit, &hitPID)
            print("SNIPPET_HIT x=\(x) y=\(y) status=\(status.rawValue) pidMatch=\(hitPID == pid) role=\(attr(hit, "AXRole") as? String ?? "") description=\(attr(hit, "AXDescription") as? String ?? "") placeholder=\(attr(hit, "AXPlaceholderValue") as? String ?? "")")
            guard hitPID == pid else { stop("snippet hit outside app") }
            hitFields.append(hit)
        } else { print("SNIPPET_HIT x=\(x) y=\(y) status=\(status.rawValue) missing=YES") }
    }
    guard hitFields.count == 3,
          (attr(hitFields[0], "AXRole") as? String) == "AXTextField",
          (attr(hitFields[1], "AXRole") as? String) == "AXTextArea",
          (attr(hitFields[2], "AXRole") as? String) == "AXCheckBox",
          (attr(hitFields[2], "AXDescription") as? String) == "Локальный терминал",
          CGDisplayPixelsWide(CGMainDisplayID()) == 1024, CGDisplayPixelsHigh(CGMainDisplayID()) == 768 else { stop("unexpected snippet dialog geometry") }
    func typeSynthetic(_ value: String, in element: AXUIElement) {
        guard CGPreflightPostEventAccess(), running.activate(options: [.activateIgnoringOtherApps]) else { stop("snippet input access") }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { stop("snippet input focus") }
        for character in value {
            guard let stroke = syntheticKeyStroke(character), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: false) else { stop("snippet input event") }
            let flags: CGEventFlags = stroke.shift ? .maskShift : []
            down.flags = flags; up.flags = flags; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        guard (attr(element, "AXValue") as? String) == value else { stop("snippet input value mismatch") }
    }
    typeSynthetic("TEST-ONLY-CODEX-SNIPPET", in: hitFields[0])
    typeSynthetic("TEST-ONLY-CODEX-COMMAND", in: hitFields[1])
    guard AXUIElementPerformAction(hitFields[2], kAXPressAction as CFString) == .success else { stop("snippet target selection") }
    var ancestor: AXUIElement? = hitFields[0]
    var sheet: AXUIElement?
    for _ in 0..<12 {
        guard let element = ancestor else { break }
        let role = attr(element, "AXRole") as? String ?? ""
        print("SNIPPET_ANCESTOR role=\(role) title=\(attr(element, "AXTitle") as? String ?? "")")
        if role == "AXSheet" { sheet = element }
        ancestor = attr(element, "AXParent").map { unsafeBitCast($0, to: AXUIElement.self) }
    }
    guard let sheet else { stop("snippet sheet unavailable") }
    for element in snapshot(sheet) {
        let role = attr(element, "AXRole") as? String ?? ""
        let title = attr(element, "AXTitle") as? String ?? ""
        let description = attr(element, "AXDescription") as? String ?? ""
        let placeholder = attr(element, "AXPlaceholderValue") as? String ?? ""
        if !title.isEmpty || !description.isEmpty || !placeholder.isEmpty || ["AXTextField", "AXTextArea"].contains(role) {
            print("SNIPPET_NODE role=\(role) title=\(title) description=\(description) placeholder=\(placeholder)")
        }
    }
    let saveButtons = snapshot(sheet).filter {
        (attr($0, "AXRole") as? String) == "AXButton" &&
        (["Save", "Сохранить"].contains((attr($0, "AXTitle") as? String) ?? "") ||
         ["Save", "Сохранить"].contains((attr($0, "AXDescription") as? String) ?? ""))
    }
    guard saveButtons.count == 1, AXUIElementPerformAction(saveButtons[0], kAXPressAction as CFString) == .success else { stop("snippet save control") }
    Thread.sleep(forTimeInterval: 1)
    print("SYNTHETIC_SNIPPET_SAVE_REQUESTED=YES")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--inspect-upgrade" {
    guard env["SR_BUILD_KIND"] == "candidate" else { stop("upgrade inspection requires candidate") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    let nodes = snapshot(app)
    let hostVisible = nodes.contains {
        (attr($0, "AXTitle") as? String) == "TEST-ONLY-CODEX-UPGRADE-HOST" ||
        (attr($0, "AXDescription") as? String) == "TEST-ONLY-CODEX-UPGRADE-HOST"
    }
    print("UPGRADE_HOST_ACCESSIBLE=\(hostVisible)")
    for element in nodes.prefix(500) {
        let role = attr(element, "AXRole") as? String ?? ""
        let title = attr(element, "AXTitle") as? String ?? ""
        let description = attr(element, "AXDescription") as? String ?? ""
        let placeholder = attr(element, "AXPlaceholderValue") as? String ?? ""
        if !title.isEmpty || !description.isEmpty || !placeholder.isEmpty {
            print("AX_NODE role=\(role) title=\(title) description=\(description) placeholder=\(placeholder)")
        }
    }
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--verify-snippets" {
    guard env["SR_BUILD_KIND"] == "candidate" else { stop("snippet verification requires candidate") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    pressUnique("AXButton", "Snippets")
    func visibleLabel(_ element: AXUIElement) -> String {
        ["AXTitle", "AXDescription", "AXValue"].compactMap { attr(element, $0) as? String }.joined(separator: " ")
    }
    var nodes = snapshot(app)
    var groups = nodes.filter {
        (attr($0, "AXRole") as? String) == "AXButton" &&
        visibleLabel($0).contains("TEST-ONLY-CODEX-SNIPPET-GROUP")
    }
    var items = nodes.filter { visibleLabel($0).contains("TEST-ONLY-CODEX-SNIPPET") && !visibleLabel($0).contains("TEST-ONLY-CODEX-SNIPPET-GROUP") }
    if items.isEmpty && groups.count == 1 {
        guard AXUIElementPerformAction(groups[0], kAXPressAction as CFString) == .success else { stop("migrated snippet group action") }
        Thread.sleep(forTimeInterval: 1)
        nodes = snapshot(app)
        groups = nodes.filter { visibleLabel($0).contains("TEST-ONLY-CODEX-SNIPPET-GROUP") }
        items = nodes.filter { visibleLabel($0).contains("TEST-ONLY-CODEX-SNIPPET") && !visibleLabel($0).contains("TEST-ONLY-CODEX-SNIPPET-GROUP") }
    }
    for element in nodes where visibleLabel(element).contains("TEST-ONLY-CODEX-SNIPPET") {
        print("MIGRATED_SNIPPET_NODE role=\(attr(element, "AXRole") as? String ?? "") label=\(visibleLabel(element))")
    }
    guard !items.isEmpty else { stop("migrated snippet not visible") }
    print("SYNTHETIC_SNIPPET_VISIBLE_IN_CANDIDATE=YES")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--double-click-rdp" {
    guard env["SR_BUILD_KIND"] == "network", env["RUNNER_ENVIRONMENT"] == "github-hosted" else { stop("RDP fixture runner identity") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    pressUnique("AXPopUpButton", "Add")
    pressUnique("AXMenuItem", "New RDP")
    setUniqueField("Work Computer", "TEST-ONLY-CODEX-RDP")
    setUniqueField("server.example.local", "127.0.0.1")
    setUniqueField("DOMAIN\\username", "test", preferTopmost: true)
    setUniqueField("Введите пароль RDP", "TEST-ONLY-CODEX-RDP-SECRET", verifyVisibleValue: false)
    let save = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXButton" &&
        ((attr($0, "AXTitle") as? String) == "Save" || (attr($0, "AXDescription") as? String) == "Save") &&
        (attr($0, "AXEnabled") as? Bool) == true
    }
    guard save.count == 1, AXUIElementPerformAction(save[0], kAXPressAction as CFString) == .success else { stop("synthetic RDP credential save") }
    Thread.sleep(forTimeInterval: 1)
    let hosts = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXButton" && (attr($0, "AXDescription") as? String) == "TEST-ONLY-CODEX-RDP"
    }
    guard hosts.count == 1 else { stop("synthetic RDP host row unavailable") }
    _ = AXUIElementPerformAction(hosts[0], "AXScrollToVisible" as CFString)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
    guard let position = attr(hosts[0], "AXPosition"), let size = attr(hosts[0], "AXSize"),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { stop("synthetic RDP row frame") }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { stop("synthetic RDP row frame") }
    point.x += dimensions.width / 2; point.y += dimensions.height / 2
    var hit: AXUIElement?, hitPID: pid_t = 0
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
          let hit, AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid,
          running.activate(options: [.activateIgnoringOtherApps]) else { stop("synthetic RDP hit test") }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop("synthetic RDP host focus") }
    for clicks in [1, 2] {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { stop("synthetic RDP mouse event") }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)); up.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    print("SYNTHETIC_RDP_HOST_DOUBLE_CLICK_POSTED=YES")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--double-click-ssh" {
    guard env["SR_BUILD_KIND"] == "network", env["RUNNER_ENVIRONMENT"] == "github-hosted" else { stop("network fixture runner identity") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    pressUnique("AXPopUpButton", "Add")
    pressUnique("AXMenuItem", "New SSH")
    setUniqueField("SSH Server", "TEST-ONLY-CODEX-LOOPBACK")
    setUniqueField("server.example.com or a Host from ~/.ssh/config", "127.0.0.1")
    setUniqueField("username", "runner")
    setUniqueField("22", "52222")
    let hosts = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXButton" &&
        (attr($0, "AXDescription") as? String) == "TEST-ONLY-CODEX-LOOPBACK"
    }
    guard hosts.count == 1 else { stop("synthetic host row unavailable") }
    _ = AXUIElementPerformAction(hosts[0], "AXScrollToVisible" as CFString)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
    guard let position = attr(hosts[0], "AXPosition"), let size = attr(hosts[0], "AXSize"),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { stop("synthetic host row unavailable") }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { stop("synthetic host row frame") }
    point.x += dimensions.width / 2; point.y += dimensions.height / 2
    var hit: AXUIElement?
    var rawHitPID: pid_t = 0
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
          let hit, AXUIElementGetPid(hit, &rawHitPID) == .success, rawHitPID == pid,
          running.activate(options: [.activateIgnoringOtherApps]) else { stop("synthetic host hit test") }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop("synthetic host focus") }
    let ready = URL(fileURLWithPath: temp + "/ssh-host-ready.flag")
    let go = temp + "/ssh-click-go.flag"
    guard !FileManager.default.fileExists(atPath: ready.path), !FileManager.default.fileExists(atPath: go) else { stop("synthetic click barrier already exists") }
    do { try Data("ready".utf8).write(to: ready, options: .withoutOverwriting) } catch { stop("synthetic click barrier") }
    let deadline = Date(timeIntervalSinceNow: 30)
    while !FileManager.default.fileExists(atPath: go) && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }
    guard FileManager.default.fileExists(atPath: go), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop("synthetic click barrier timeout") }
    for clicks in [1, 2] {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { stop("synthetic mouse event") }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)); up.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    print("SYNTHETIC_HOST_DOUBLE_CLICK_POSTED=YES")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--open-sftp" {
    guard env["SR_BUILD_KIND"] == "network", env["RUNNER_ENVIRONMENT"] == "github-hosted" else { stop("SFTP fixture runner identity") }
    for element in snapshot(app) where (attr(element, "AXDescription") as? String) == "SFTP" || (attr(element, "AXTitle") as? String) == "SFTP" {
        let position = attr(element, "AXPosition")
        var point = CGPoint.zero
        if let position, CFGetTypeID(position) == AXValueGetTypeID() { _ = AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point) }
        print("SYNTHETIC_SFTP_CONTROL role=\(attr(element, "AXRole") as? String ?? "") x=\(point.x)")
    }
    let tabs = snapshot(app).filter {
        guard ["AXButton", "AXRadioButton"].contains((attr($0, "AXRole") as? String) ?? ""),
              ((attr($0, "AXDescription") as? String) == "SFTP" || (attr($0, "AXTitle") as? String) == "SFTP"),
              let position = attr($0, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point) && point.x > 300
    }
    guard tabs.count == 1, AXUIElementPerformAction(tabs[0], kAXPressAction as CFString) == .success else { stop("synthetic SFTP tab unavailable") }
    Thread.sleep(forTimeInterval: 2)
    let remoteSelectors = snapshot(app).filter {
        guard ["AXButton", "AXRadioButton"].contains((attr($0, "AXRole") as? String) ?? ""),
              ((attr($0, "AXDescription") as? String) == "TEST-ONLY-CODEX-LOOPBACK" || (attr($0, "AXTitle") as? String) == "TEST-ONLY-CODEX-LOOPBACK"),
              let position = attr($0, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point) && point.x > 300
    }
    guard remoteSelectors.count == 1, AXUIElementPerformAction(remoteSelectors[0], kAXPressAction as CFString) == .success else { stop("synthetic SFTP remote selector") }
    let deadline = Date(timeIntervalSinceNow: 35)
    while Date() < deadline {
        let rows = snapshot(app).filter { element in
            ["AXTitle", "AXDescription", "AXValue"].compactMap { attr(element, $0) as? String }
                .contains(where: { $0.contains("TEST-ONLY-CODEX-SFTP-CHECK") })
        }
        if !rows.isEmpty { print("SYNTHETIC_SFTP_FILE_VISIBLE=YES"); exit(0) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
    }
    stop("synthetic SFTP file not visible")
}
if CommandLine.arguments.count == 3 {
    guard CommandLine.arguments[2] == "--verify-baseline", env["SR_BUILD_KIND"] == "baseline" else { stop("unknown verification mode") }
    let welcome = snapshot(app).filter {
        (attr($0, "AXRole") as? String) == "AXWindow" && (attr($0, "AXTitle") as? String) == "What's New in Selective Remote"
    }
    if !welcome.isEmpty { pressUnique("AXButton", "Done") }
    pressUnique("AXButton", "Connections")
    for (placeholder, expected) in [
        ("SSH Server", "TEST-ONLY-CODEX-UPGRADE-HOST"),
        ("For example: Work", "TEST-ONLY-CODEX-UPGRADE-FOLDER"),
        ("server.example.com or a Host from ~/.ssh/config", "192.0.2.10"),
        ("username", "test")
    ] {
        let fields = snapshot(app).filter {
            (attr($0, "AXRole") as? String) == "AXTextField" && (attr($0, "AXPlaceholderValue") as? String) == placeholder
        }
        guard fields.count == 1, (attr(fields[0], "AXValue") as? String) == expected else { stop("reopened field mismatch: \(placeholder)") }
    }
    print("BASELINE_REOPEN_UI=PASS")
    exit(0)
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

setUniqueField("SSH Server", "TEST-ONLY-CODEX-UPGRADE-HOST")
setUniqueField("For example: Work", "TEST-ONLY-CODEX-UPGRADE-FOLDER")
setUniqueField("server.example.com or a Host from ~/.ssh/config", "192.0.2.10")
setUniqueField("username", "test")
print("SYNTHETIC_PROFILE_FIELDS_ENTERED=YES")
pressUnique("AXButton", "Authentication")
setUniqueField("Пароль SSH-сервера", "TEST-ONLY-CODEX-UPGRADE-SECRET", verifyVisibleValue: false)
pressUnique("AXButton", "Save")
print("SYNTHETIC_CREDENTIAL_SAVE_REQUESTED=YES")
for element in snapshot(app).prefix(500) {
    let role = attr(element, "AXRole") as? String ?? ""
    let title = attr(element, "AXTitle") as? String ?? ""
    let description = attr(element, "AXDescription") as? String ?? ""
    let placeholder = attr(element, "AXPlaceholderValue") as? String ?? ""
    if !title.isEmpty || !description.isEmpty || !placeholder.isEmpty {
        print("AUTH_NODE role=\(role) title=\(title) description=\(description) placeholder=\(placeholder)")
    }
}
pressUnique("AXButton", "General")
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
