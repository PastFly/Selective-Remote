import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class DisplayManager {
    func currentDisplays() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(displayID)
            guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
                return nil
            }
            let uuid = unmanagedUUID.takeRetainedValue()
            let stableID = CFUUIDCreateString(nil, uuid) as String

            return DisplayDescriptor(
                id: stableID,
                systemID: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor),
                refreshRate: mode?.refreshRate ?? 0,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                isSystemMain: CGDisplayIsMain(displayID) != 0
            )
        }
        .sorted {
            if $0.frame.minX != $1.frame.minX {
                return $0.frame.minX < $1.frame.minX
            }
            if $0.frame.minY != $1.frame.minY {
                return $0.frame.minY > $1.frame.minY
            }
            return $0.systemID < $1.systemID
        }
    }
}

@MainActor
final class DisplayNumberOverlay {
    private var windows: [NSWindow] = []
    private var dismissalTask: Task<Void, Never>?

    func show(displays: [DisplayDescriptor], duration: TimeInterval = 2.5) {
        close()

        for (index, display) in displays.enumerated() {
            guard let screen = NSScreen.screens.first(where: { screen in
                guard let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return false
                }
                return value.uint32Value == display.systemID
            }) else { continue }

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver
            window.backgroundColor = NSColor.black.withAlphaComponent(0.62)
            window.isOpaque = false
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: DisplayBadge(
                number: index + 1,
                name: display.name
            ))
            window.orderFrontRegardless()
            windows.append(window)
        }

        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.hideWindows()
            self?.dismissalTask = nil
        }
    }

    func close() {
        dismissalTask?.cancel()
        dismissalTask = nil
        hideWindows()
    }

    private func hideWindows() {
        let visibleWindows = windows
        windows.removeAll()
        visibleWindows.forEach { window in
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}

private struct DisplayBadge: View {
    let number: Int
    let name: String

    var body: some View {
        VStack(spacing: 14) {
            Text("\(number)")
                .font(.system(size: 150, weight: .bold, design: .rounded))
            Text(name)
                .font(.system(size: 28, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
