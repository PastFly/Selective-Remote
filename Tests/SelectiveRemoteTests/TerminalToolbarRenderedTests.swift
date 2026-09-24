import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

struct TerminalToolbarRenderedTests {
    @MainActor
    @Test("Rendered SSH Terminal uses half-screen space for visible quick actions")
    func halfScreenQuickActions() throws {
        let suite = "SelectiveRemoteTests.Toolbar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = TerminalWorkspaceModel(
            profileID: UUID(), primarySession: TerminalSessionModel(),
            primaryConnection: .custom(host: "synthetic.example.invalid", username: "tester"),
            defaults: defaults
        )
        let terminal = SSHTerminalView(
            workspace: workspace,
            appearance: TerminalAppearanceStore(defaults: defaults),
            appAppearance: AppAppearanceStore(defaults: defaults),
            workspaceTitle: "Synthetic Host",
            defaultProfileID: nil,
            locksPrimaryConnection: false,
            sshProfiles: [],
            hasInstallableKey: false,
            isFocusMode: false,
            connect: { _, _ in },
            installKey: {},
            toggleFocusMode: {},
            openSFTP: { _ in },
            openSFTPPath: { _, _ in },
            openSnippetLibrary: {},
            executeSnippet: { _ in .success },
            discoverContext: { _ in .empty }
        )
        for locale in ["ru_RU", "en_US"] {
            for scheme in [ColorScheme.light, .dark] {
                for width in [360, 450, 650, 850, 1100] {
                let view = terminal
                    .environment(\.locale, Locale(identifier: locale))
                    .preferredColorScheme(scheme)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: 480)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless],
                    backing: .buffered, defer: false
                )
                window.contentView = host
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 480,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if ProcessInfo.processInfo.environment["SR_CAPTURE_TOOLBAR_MATRIX"] == "1" {
                    let theme = scheme == .dark ? "graphite" : "light"
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: "/private/tmp/sr-terminal-toolbar-\(locale)-\(theme)-\(width).png")
                    )
                }
                guard width == 650 else { continue }
                var actionPixels = 0
                for x in 300..<500 {
                    guard let background = bitmap.colorAt(x: x, y: 4)?.usingColorSpace(.deviceRGB) else { continue }
                    for y in 10..<42 {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let difference = max(
                            abs(color.redComponent - background.redComponent),
                            abs(color.greenComponent - background.greenComponent),
                            abs(color.blueComponent - background.blueComponent)
                        )
                        if difference > 0.15 { actionPixels += 1 }
                    }
                }
                #expect(actionPixels > 100, "\(locale) \(scheme): quick actions should use half-screen space")
                }
            }
        }
    }
}
