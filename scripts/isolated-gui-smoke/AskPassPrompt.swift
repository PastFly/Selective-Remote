import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never { fputs("SYNTHETIC_ASKPASS_BLOCKED: \(message)\n", stderr); exit(2) }
typealias PidPath = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
typealias ListPids = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
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
      let lib = dlopen("/usr/lib/libproc.dylib", RTLD_NOW), let symbol = dlsym(lib, "proc_pidpath"),
      let listSymbol = dlsym(lib, "proc_listallpids") else { fail("synthetic fixture or helper") }
let pathFn = unsafeBitCast(symbol, to: PidPath.self)
let listFn = unsafeBitCast(listSymbol, to: ListPids.self)
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
let system = AXUIElementCreateSystemWide()
var diagnostics = Set<String>()
func report(_ message: String) { if diagnostics.insert(message).inserted { print(message) } }
func syntheticPromptWindow(_ helperPID: pid_t) -> CGRect? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { report("SYNTHETIC_WINDOW_LIST=UNAVAILABLE"); return nil }
    let helperWindows = windows.enumerated().filter { ($0.element[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == helperPID }
    let appWindows = windows.enumerated().filter { ($0.element[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == appPID }
    let descriptions = helperWindows.map { item -> String in
        let layer = (item.element[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -999
        let raw = item.element[kCGWindowBounds as String] as? [String: Any]
        let rect = raw.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        return "index:\(item.offset),layer:\(layer),rect:\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }.joined(separator: ";")
    report("SYNTHETIC_WINDOW helper=\(descriptions) appCount=\(appWindows.count)")
    guard let helperIndex = windows.firstIndex(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == helperPID && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }),
          let appIndex = windows.firstIndex(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == appPID && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }),
          helperIndex < appIndex, let raw = windows[helperIndex][kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), (300...600).contains(rect.width), (150...400).contains(rect.height),
          rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1024, rect.maxY <= 768 else { return nil }
    return rect
}
func syntheticPromptArgumentsMatch(_ helperPID: pid_t) -> Bool {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(helperPID), "-o", "args="]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, output.count < 4096, let line = String(data: output, encoding: .utf8) else { return false }
    let keyMatch = line.contains(key), phraseMatch = line.localizedCaseInsensitiveContains("passphrase")
    report("SYNTHETIC_ASKPASS_ARGUMENTS keyMatch=\(keyMatch) phraseMatch=\(phraseMatch)")
    return keyMatch && phraseMatch
}
func focusedPID() -> pid_t? {
    guard let focused = attribute(system, "AXFocusedUIElement"), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    var pid: pid_t = 0
    return AXUIElementGetPid(unsafeBitCast(focused, to: AXUIElement.self), &pid) == .success ? pid : nil
}
let deadline = Date(timeIntervalSinceNow: 35)
var reported = Set<String>()
while Date() < deadline {
    guard kill(appPID, 0) == 0 else { fail("target app terminated") }
    guard CGDisplayPixelsWide(CGMainDisplayID()) == 1024, CGDisplayPixelsHigh(CGMainDisplayID()) == 768 else { fail("unexpected prompt geometry") }
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = pids.withUnsafeMutableBytes { listFn($0.baseAddress!, Int32($0.count)) }
    if reported.insert("pid-count").inserted { print("SYNTHETIC_ASKPASS_PID_COUNT=\(count)") }
    if count > 0 {
        for candidate in pids.prefix(Int(count)) where candidate > 1 {
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            guard pathBuffer.withUnsafeMutableBytes({ pathFn(candidate, $0.baseAddress!, UInt32($0.count)) }) > 0 else { continue }
            let path = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath().path
            let processName = URL(fileURLWithPath: path).lastPathComponent
            if processName.localizedCaseInsensitiveContains("askpass") {
                let diagnostic = "SYNTHETIC_ASKPASS_NAMED_PROCESS=\(processName) helperMatch=\(path == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path)"
                if reported.insert(diagnostic).inserted { print(diagnostic) }
            }
            guard path == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path else { continue }
            let nodes = snapshot(AXUIElementCreateApplication(candidate))
            let roles = nodes.compactMap { attribute($0, "AXRole") as? String }.joined(separator: ",")
            let diagnostic = "SYNTHETIC_ASKPASS_PROCESS_MATCH=YES roles=\(roles)"
            if reported.insert(diagnostic).inserted { print(diagnostic) }
            if roles.isEmpty, syntheticPromptArgumentsMatch(candidate), let rect = syntheticPromptWindow(candidate) {
                let point = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.72)
                guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { fail("synthetic AskPass click") }
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
                for character in "TESTONLYCODEXPASSPHRASE" {
                    guard syntheticPromptWindow(candidate) != nil, let stroke = syntheticKeyStroke(character),
                          let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: true),
                          let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: false) else { fail("synthetic AskPass input") }
                    let flags: CGEventFlags = stroke.shift ? .maskShift : []
                    keyDown.flags = flags; keyUp.flags = flags; keyDown.post(tap: .cghidEventTap); keyUp.post(tap: .cghidEventTap)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                }
                guard syntheticPromptWindow(candidate) != nil,
                      let returnDown = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                      let returnUp = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { fail("synthetic AskPass confirmation") }
                returnDown.post(tap: .cghidEventTap); returnUp.post(tap: .cghidEventTap)
                print("SYNTHETIC_ASKPASS_ENTERED=YES")
                exit(0)
            }
        }
    }
    var hit: AXUIElement?
    if AXUIElementCopyElementAtPosition(system, 500, 317, &hit) == .success, let hit {
        var pid: pid_t = 0
        if AXUIElementGetPid(hit, &pid) == .success, pid > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes({ pathFn(pid, $0.baseAddress!, UInt32($0.count)) })
            if count > 0 {
                let processPath = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
                let role = (attribute(hit, "AXRole") as? String) ?? ""
                let placeholder = (attribute(hit, "AXPlaceholderValue") as? String) ?? ""
                let diagnostic = "SYNTHETIC_ASKPASS_HIT role=\(role) placeholder=\(placeholder) helperMatch=\(processPath == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path) process=\(URL(fileURLWithPath: processPath).lastPathComponent)"
                if reported.insert(diagnostic).inserted { print(diagnostic) }
            }
            if count > 0,
               URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path,
               (attribute(hit, "AXRole") as? String) == "AXTextField",
               (attribute(hit, "AXPlaceholderValue") as? String) == "Passphrase" {
                var ancestor: AXUIElement? = hit, window: AXUIElement?
                for _ in 0..<12 {
                    guard let element = ancestor else { break }
                    if (attribute(element, "AXRole") as? String) == "AXWindow" { window = element; break }
                    ancestor = attribute(element, "AXParent").map { unsafeBitCast($0, to: AXUIElement.self) }
                }
                guard let window else { fail("AskPass window unavailable") }
                let nodes = snapshot(window)
                let labels = nodes.flatMap { node -> [String] in
                    ["AXTitle", "AXDescription", "AXHelp"].compactMap { attribute(node, $0) as? String }
                    + (((attribute(node, "AXRole") as? String) == "AXStaticText") ? [attribute(node, "AXValue") as? String].compactMap { $0 } : [])
                }.joined(separator: " ")
                guard labels.contains("SSH Key Passphrase"), labels.contains(key) else { fail("AskPass prompt identity") }
                let buttons = nodes.filter { (attribute($0, "AXRole") as? String) == "AXButton" && ((attribute($0, "AXTitle") as? String) == "Continue" || (attribute($0, "AXDescription") as? String) == "Continue") }
                guard buttons.count == 1, AXUIElementSetAttributeValue(hit, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                      focusedPID() == pid else { fail("AskPass focus or confirmation") }
                for character in "TESTONLYCODEXPASSPHRASE" {
                    guard let stroke = syntheticKeyStroke(character), focusedPID() == pid,
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
        }
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}
fail("matching synthetic AskPass prompt unavailable")
