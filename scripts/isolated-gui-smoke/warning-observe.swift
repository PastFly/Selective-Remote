import AppKit
import ApplicationServices
import Foundation

func fail(_ message: String) -> Never { fputs("BLOCKED: \(message)\n", stderr); exit(1) }
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted",
      CommandLine.arguments.count == 4,
      let pid = Int32(CommandLine.arguments[1]), pid > 1,
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
      AXIsProcessTrusted() else { fail("runner, app or accessibility unavailable") }
let expected = CommandLine.arguments[2]
let mode = CommandLine.arguments[3]
let root = AXUIElementCreateApplication(pid)
func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
}
func elements() -> [AXUIElement] {
    var pending = [root], examined = 0
    var found: [AXUIElement] = []
    while let element = pending.popLast(), examined < 8000 {
        examined += 1
        found.append(element)
        if let children = attr(element, "AXChildren") as? [AXUIElement] { pending.append(contentsOf: children) }
    }
    return found
}
func findWarning() -> AXUIElement? { elements().first { attr($0, "AXIdentifier") as? String == "legacy-host-warning" } }
if mode == "ready" {
    let readyDeadline = Date(timeIntervalSinceNow: 25)
    var windows: [AXUIElement] = []
    repeat {
        guard !app.isTerminated else { fail("app exited before window appeared") }
        windows = attr(root, "AXWindows") as? [AXUIElement] ?? []
        if !windows.isEmpty { break }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
    } while Date() < readyDeadline
    guard !windows.isEmpty else { fail("no application window") }
    for window in windows {
        let title = attr(window, "AXTitle") as? String ?? ""
        guard title.hasPrefix("What's New in ") || title.hasPrefix("Что нового в ") else { continue }
        var pending = [window], button: AXUIElement?
        while let element = pending.popLast() {
            let role = attr(element, "AXRole") as? String
            let labels = ["AXTitle", "AXDescription", "AXValue"].compactMap { attr(element, $0) as? String }
            if role == "AXButton" && labels.contains(where: { $0 == "Done" || $0 == "Готово" }) { button = element; break }
            if let children = attr(element, "AXChildren") as? [AXUIElement] { pending.append(contentsOf: children) }
        }
        guard let button else { fail("release notes close button unavailable") }
        guard app.activate(options: [.activateIgnoringOtherApps]) else { fail("cannot activate synthetic app") }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { fail("release notes close action failed") }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    }
    print("APPLICATION_WINDOW=READY")
    exit(0)
}
let deadline = Date(timeIntervalSinceNow: mode == "absent" ? 8 : 25)
var alertActionAttempted = false
repeat {
    guard !app.isTerminated else { fail("app exited") }
    if mode == "dismiss" {
        let all = elements()
        let message = all.contains { element in
            ["AXTitle", "AXDescription", "AXValue"].compactMap { attr(element, $0) as? String }
                .contains { $0.contains(expected) }
        }
        let buttons = all.filter { element in
            (attr(element, "AXRole") as? String) == "AXButton" &&
            ["AXTitle", "AXDescription", "AXValue"].compactMap { attr(element, $0) as? String }.contains("OK")
        }
        if alertActionAttempted && buttons.isEmpty {
            print("WARNING_ALERT=CONFIRMED_AND_DISMISSED")
            exit(0)
        }
        if message && buttons.count == 1 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            alertActionAttempted = true
            _ = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        continue
    }
    if let warning = findWarning() {
        if mode == "clears" {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            continue
        }
        guard mode != "absent" else { fail("unexpected warning") }
        if mode == "open" {
            _ = AXUIElementPerformAction(warning, kAXPressAction as CFString)
            print("WARNING_STATUS=ACTION_ATTEMPTED")
            exit(0)
        }
        let content = ["AXLabel", "AXValue", "AXDescription", "AXTitle"].compactMap { attr(warning, $0) as? String }.joined(separator: " ")
        guard content.contains(expected) else { fail("warning text unavailable or incorrect") }
        guard let size = attr(warning, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID(),
              let position = attr(warning, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID() else { fail("warning geometry unavailable") }
        var dimensions = CGSize.zero, point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              dimensions.width > 200, dimensions.height > 20 else { fail("warning geometry invalid") }
        let screen = CGDisplayBounds(CGMainDisplayID())
        guard point.y >= screen.minY, point.y + dimensions.height <= screen.maxY,
              point.x >= screen.minX, point.x + min(dimensions.width, 620) <= screen.maxX else {
            fail("warning outside visible display")
        }
        guard app.activate(options: [.activateIgnoringOtherApps]) else { fail("cannot activate candidate app") }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        print("VISIBLE_WARNING=YES TEXT=EXPECTED GEOMETRY=VALID")
        exit(0)
    } else if mode == "clears" { print("VISIBLE_WARNING=CLEARED"); exit(0) }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
} while Date() < deadline
if mode == "absent" { print("VISIBLE_WARNING=NO"); exit(0) }
fail("warning not visible")
