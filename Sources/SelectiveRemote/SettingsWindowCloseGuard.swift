import AppKit
import SwiftUI

@MainActor
struct SettingsWindowCloseGuard: NSViewRepresentable {
    let preventsClosing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            window: nsView.window,
            preventsClosing: preventsClosing
        )
        if nsView.window == nil {
            DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                guard let nsView, let coordinator else { return }
                coordinator.update(
                    window: nsView.window,
                    preventsClosing: preventsClosing
                )
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var originallyClosable = true
        private var capturedWindow = false

        func update(window: NSWindow?, preventsClosing: Bool) {
            guard let window else { return }
            if self.window !== window {
                restore()
                self.window = window
                originallyClosable = window.styleMask.contains(.closable)
                capturedWindow = true
            }

            if preventsClosing {
                window.styleMask.remove(.closable)
                window.standardWindowButton(.closeButton)?.isEnabled = false
            } else {
                if originallyClosable {
                    window.styleMask.insert(.closable)
                }
                window.standardWindowButton(.closeButton)?.isEnabled = originallyClosable
            }
        }

        func restore() {
            guard capturedWindow, let window else {
                self.window = nil
                capturedWindow = false
                return
            }
            if originallyClosable {
                window.styleMask.insert(.closable)
            }
            window.standardWindowButton(.closeButton)?.isEnabled = originallyClosable
            self.window = nil
            capturedWindow = false
        }
    }
}
