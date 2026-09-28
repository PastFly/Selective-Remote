import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

@Suite("Global Sync status rendered matrix")
@MainActor
struct SyncStatusUtilityRenderedTests {
    @Test("RU/EN, Light/Graphite, narrow/normal/wide render each attention state")
    @available(macOS, deprecated: 14)
    func matrix() throws {
        let output = ProcessInfo.processInfo.environment["SR_CAPTURE_SYNC_STATUS_MATRIX"]
        let states: [(String, SyncLifecycle)] = [
            ("synced", .synced), ("syncing", .syncing), ("unknown", .unknown),
            ("error", .error), ("conflict", .conflict), ("failClosed", .security),
        ]
        for (name, lifecycle) in states {
            for english in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    for width in [220, 280, 360] {
                        let view = VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Text("Selective Remote").font(.headline)
                                Spacer()
                                Image(systemName: "bell")
                                Image(systemName: "paintpalette")
                            }
                            CloudSyncServiceBlockView(
                                lifecycle: lifecycle,
                                english: english,
                                cloudSessionAvailable: true,
                                onCloud: {},
                                onSync: {}
                            )
                            .frame(width: CGFloat(width - 24))
                        }
                        .padding(12)
                        .frame(width: CGFloat(width), height: 115)
                        .preferredColorScheme(scheme)
                        let hosting = NSHostingView(rootView: view)
                        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 115)
                        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                                              backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        window.contentView = hosting
                        window.makeKeyAndOrderFront(nil)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                        window.layoutIfNeeded()
                        hosting.layoutSubtreeIfNeeded()
                        let image = try #require(CGWindowListCreateImage(
                            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                            [.boundsIgnoreFraming, .bestResolution]
                        ))
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        window.orderOut(nil)
                        #expect(bitmap.colorAt(x: width / 2, y: 76) != nil)
                        if let output {
                            let filename = "\(name)-\(english ? "en" : "ru")-\(scheme == .dark ? "graphite" : "light")-\(width).png"
                            let url = URL(fileURLWithPath: output).appending(path: filename)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                        }
                    }
                }
            }
        }
    }

    @Test("Service block height is stable across sync states")
    func stableHeight() {
        let states: [SyncLifecycle] = [.synced, .syncing, .unknown, .error, .conflict, .security]
        let heights = states.map { lifecycle in
            NSHostingView(rootView: CloudSyncServiceBlockView(
                lifecycle: lifecycle,
                english: false,
                cloudSessionAvailable: true,
                onCloud: {},
                onSync: {}
            ).frame(width: 220)).fittingSize.height
        }
        #expect(heights.allSatisfy { abs($0 - heights[0]) < 0.5 })
    }
}
