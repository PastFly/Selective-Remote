import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

@Suite("Notification Center rendered matrix")
@MainActor
struct NotificationCenterRenderedTests {
    @Test("RU and EN, Light and Graphite, narrow and regular popovers render every v1 state")
    // WindowServer captures the composited SwiftUI layers; view cache/PDF omit text.
    @available(macOS, deprecated: 14)
    func renderedMatrix() throws {
        let suite = "SelectiveRemoteTests.Notifications.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageStore.shared
        let originalLanguage = language.selection
        defer { language.selection = originalLanguage }
        let local = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let account = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let host = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let invitation = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let team = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let output = ProcessInfo.processInfo.environment["SR_CAPTURE_NOTIFICATION_MATRIX"]

        for state in ["empty", "device", "invitation", "syncError", "conflict",
                      "failClosed", "hostIdentity", "mixed", "read", "resolved"] {
            defaults.removePersistentDomain(forName: suite)
            let center = MacNotificationCenter(defaults: defaults, installationID: local)
            if ["device", "invitation", "syncError", "conflict", "failClosed",
                "mixed", "read", "resolved"].contains(state) {
                center.setAccount(account)
            }
            if ["hostIdentity", "mixed"].contains(state) {
                center.observeHostIdentity(profileID: host)
            }
            if ["device", "mixed", "read", "resolved"].contains(state) {
                center.reconcileDevices([host])
            }
            if ["invitation", "mixed"].contains(state) {
                center.reconcileInvitations([(id: invitation, teamID: team)])
            }
            if ["syncError", "conflict", "failClosed", "mixed"].contains(state) {
                let sync = SyncPresentationStore()
                if state == "failClosed" {
                    sync.recordTeamReport(.init(scannedVaults: 1, rotations: 1))
                    center.applySyncSnapshot(sync.team)
                } else {
                    sync.recordPersonalFailure(state == "syncError" ? .unknownFailure : .conflict)
                    center.applySyncSnapshot(sync.personal)
                }
            }
            if state == "read", let id = center.items.first?.id {
                center.markRead(id)
            }
            if state == "resolved" {
                center.reconcileDevices([])
            }
            for locale in [AppLanguage.russian, .english] {
                language.selection = locale
                for scheme in [ColorScheme.light, .dark] {
                    for width in [320, 390] {
                        let view = NotificationCenterView(center: center, onOpen: { _ in })
                            .preferredColorScheme(scheme)
                        let hosting = NSHostingView(rootView: view)
                        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 530)
                        let window = NSWindow(contentRect: hosting.frame,
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        window.contentView = hosting
                        window.makeKeyAndOrderFront(nil)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                        window.layoutIfNeeded()
                        hosting.layoutSubtreeIfNeeded()
                        let captured = try #require(CGWindowListCreateImage(
                            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                            [.boundsIgnoreFraming, .bestResolution]
                        ))
                        let bitmap = NSBitmapImageRep(cgImage: captured)
                        window.orderOut(nil)
                        #expect(bitmap.colorAt(x: width / 2, y: 35) != nil)
                        if let output {
                            let name = "\(state)-\(locale.rawValue)-\(scheme == .dark ? "graphite" : "light")-\(width).png"
                            let url = URL(fileURLWithPath: output).appending(path: name)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                        }
                    }
                }
            }
        }
    }
}
