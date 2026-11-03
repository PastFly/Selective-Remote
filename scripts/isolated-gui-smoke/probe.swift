import AppKit
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), pid > 1,
      let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
    fputs("FAIL: launched application process unavailable\n", stderr); exit(1)
}
guard AXIsProcessTrusted() else { fputs("BLOCKED: Accessibility unavailable\n", stderr); exit(2) }
let app = AXUIElementCreateApplication(pid)
var raw: CFTypeRef?
let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
guard result == .success, let windows = raw as? [AXUIElement], !windows.isEmpty else {
    fputs("FAIL: no accessible app window, AX status \(result.rawValue)\n", stderr); exit(3)
}
print("APP_PID=\(pid)")
print("ACCESSIBLE_WINDOW_COUNT=\(windows.count)")
for (index, window) in windows.enumerated() {
    var title: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
    print("WINDOW_\(index)_TITLE=\(title as? String ?? "")")
}
print("PRODUCT_CONNECTION_E2E=NOT_RUN")
print("UPGRADE_E2E=NOT_RUN")
