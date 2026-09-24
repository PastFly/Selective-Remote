import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

struct TunnelsRenderedLayoutTests {
    @MainActor
    @Test("Profile tunnel empty-state Create keeps a natural width")
    func profileEmptyCreate() throws {
        let model = AppModel()
        for width in [670, 900, 1500] {
            let view = PortForwardingView(profile: model.selectedProfile)
                .environmentObject(model)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 740)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            let create = try #require(visibleFrame("profile-tunnels.create", in: host))
            let parent = try #require(visibleFrame("profile-tunnels.empty", in: host))
            #expect(create.width >= 90 && create.width <= 260,
                    "profile create width \(create.width) at \(width)")
            #expect(create.maxX <= parent.maxX + 1)
        }
    }

    @MainActor
    @Test("Tunnels create, actions, search and filter keep usable nonoverlapping bounds")
    func toolbarBounds() throws {
        let model = AppModel()
        for locale in ["ru_RU", "en_US"] {
            for scheme in [ColorScheme.light, .dark] {
                for width in [670, 790, 900, 1200, 1500] {
                    let view = ForwardingManagerView(
                        model: model, onOpenTerminal: { _ in }, onOpenProfile: { _ in }
                    )
                    .environment(\.locale, Locale(identifier: locale))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(scheme)
                    let host = NSHostingView(rootView: view)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 740)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless],
                        backing: .buffered, defer: false
                    )
                    window.contentView = host
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    let create = try #require(visibleFrame("tunnels.create", in: host))
                    let toolbar = try #require(visibleFrame("tunnels.toolbar", in: host))
                    let search = try #require(visibleFrame("tunnels.search", in: host))
                    let stateFilter = try #require(visibleFrame("tunnels.filter", in: host))
                    #expect(create.width >= 90 && create.width <= 260,
                            "\(locale), \(width): create width \(create.width)")
                    #expect(create.maxX <= CGFloat(width) + 1)
                    #expect(toolbar.maxX <= CGFloat(width) + 1)
                    #expect(search.width >= 100,
                            "\(locale), \(width): search width \(search.width)")
                    #expect(stateFilter.width >= 24,
                            "\(locale), \(width): filter width \(stateFilter.width)")
                    #expect(search.maxX <= stateFilter.minX + 1)
                    #expect(stateFilter.maxX <= toolbar.maxX + 1)
                    for action in ["start", "stop", "restart", "more"] {
                        guard let frame = visibleFrame("tunnels.\(action)", in: host) else { continue }
                        #expect(frame.width >= 22,
                                "\(locale), \(width): \(action) width \(frame.width)")
                        #expect(frame.maxX <= search.minX + 1,
                                "\(locale), \(width): \(action) overlaps search")
                    }
                    if ProcessInfo.processInfo.environment["SR_CAPTURE_TUNNELS_MATRIX"] == "1" {
                        let bitmap = try #require(NSBitmapImageRep(
                            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 740,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB,
                            bytesPerRow: 0, bitsPerPixel: 0
                        ))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(
                            to: URL(fileURLWithPath: "/private/tmp/sr-tunnels-\(width)-\(locale)-\(scheme == .dark ? "dark" : "light").png")
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func visibleFrame(_ name: String, in host: NSView) -> CGRect? {
        allProbes(name, in: host).map { $0.convert($0.bounds, to: host) }
            .first { $0.width > 1 && $0.height > 1 && $0.minX >= -1 && $0.maxX <= host.bounds.maxX + 100 }
    }

    @MainActor
    private func allProbes(_ name: String, in view: NSView) -> [NSView] {
        let own = view.identifier?.rawValue == name ? [view] : []
        return own + view.subviews.flatMap { allProbes(name, in: $0) }
    }
}
