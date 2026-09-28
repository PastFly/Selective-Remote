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
                            HStack(spacing: 8) {
                                Image(systemName: "cloud").frame(width: 22)
                                Text(english ? "Cloud Management" : "Управление Cloud")
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                            }
                            .font(.subheadline)
                            SyncStatusUtilityView(lifecycle: lifecycle, english: english, onOpen: {})
                                .padding(.leading, 30)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
}
