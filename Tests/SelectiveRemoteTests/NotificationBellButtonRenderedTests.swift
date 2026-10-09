import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

@Suite("Notification bell focus rendering")
@MainActor
struct NotificationBellButtonRenderedTests {
    @Test("Focused and unfocused bell render in Light and Graphite",
          .enabled(if: ProcessInfo.processInfo.environment["SR_CAPTURE_BELL_FOCUS"] != nil))
    @available(macOS, deprecated: 14)
    func focusedBell() throws {
        guard let output = ProcessInfo.processInfo.environment["SR_CAPTURE_BELL_FOCUS"] else { return }
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        app.activate(ignoringOtherApps: true)
        for focused in [false, true] {
            for dark in [false, true] {
                let state = BellFocusProbeState()
                let hosting = NSHostingView(rootView: BellFocusProbe(
                    state: state, initiallyFocused: focused
                ).preferredColorScheme(dark ? .dark : .light))
                hosting.frame = CGRect(x: 0, y: 0, width: 240, height: 100)
                let window = NSWindow(contentRect: hosting.frame,
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "TEST-ONLY-CODEX Bell focus"
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                if focused { window.selectNextKeyView(nil) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                // A SwiftPM runner can own a responder without an active/key window.
                // Such a capture cannot verify the macOS keyboard-focus appearance.
                try #require(NSApp.isActive && window.isKeyWindow,
                             "Focus capture requires an active application and key window; use an isolated .app host for desktop verification.")
                print("Bell probe: focused=\(focused), key=\(window.isKeyWindow), active=\(NSApp.isActive), responder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                let captured = try #require(CGWindowListCreateImage(
                    .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                    [.boundsIgnoreFraming, .bestResolution]
                ))
                let bitmap = NSBitmapImageRep(cgImage: captured)
                let name = "bell-\(focused ? "focused" : "unfocused")-\(dark ? "graphite" : "light").png"
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appending(path: name))
                window.orderOut(nil)
            }
        }
    }
}

@MainActor
private final class BellFocusProbeState: ObservableObject {
    @Published var activations = 0
}

private struct BellFocusProbe: View {
    @ObservedObject var state: BellFocusProbeState
    let initiallyFocused: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 18) {
            NotificationBellButton(attentionCount: 3, english: true) {
                state.activations += 1
            }
            .focused($focused)
            Button {} label: { Image(systemName: "paintpalette") }
                .buttonStyle(.borderless)
                .focusable(false)
        }
        .padding(28)
        .frame(width: 240, height: 100)
        .onAppear { focused = initiallyFocused }
    }
}
