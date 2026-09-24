import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

struct TerminalMeasuredHeaderTests {
    @MainActor
    @Test("Rendered SSH header keeps Host identity and primary action inside its container")
    func renderedIdentityAndActions() {
        let widths: [CGFloat] = [320, 600, 900, 1200]
        for locale in ["ru_RU", "en_US"] {
            for scheme in [ColorScheme.light, .dark] {
                for status in ["Disconnected", "Connected", "Connection error"] {
                    for panelCount in 1...4 {
                        for width in widths {
                            let view = ViewThatFits(in: .horizontal) {
                                SelectiveRemoteMeasuredHeaderRow(minimumIdentityWidth: 180) {
                                    identity(locale: locale, status: status, panelCount: panelCount)
                                } trailing: {
                                    HStack(spacing: 0) {
                                        Color.green.frame(width: 380, height: 36)
                                        Color.blue.frame(width: 80, height: 36)
                                    }
                                }
                                SelectiveRemoteMeasuredHeaderRow(minimumIdentityWidth: 180) {
                                    identity(locale: locale, status: status, panelCount: panelCount)
                                } trailing: {
                                    Color.blue.frame(width: 80, height: 36)
                                }
                            }
                            .environment(\.locale, Locale(identifier: locale))
                            .preferredColorScheme(scheme)
                            let bitmap = render(view, width: width)
                            let primary = bitmap.colorAt(x: Int(width) - 20, y: 20)!
                                .usingColorSpace(.deviceRGB)!
                            #expect(primary.blueComponent > primary.redComponent)
                            let icon = bitmap.colorAt(x: 45, y: 20)!
                                .usingColorSpace(.deviceRGB)!
                            #expect(icon.redComponent > icon.blueComponent)
                            let secondary = bitmap.colorAt(x: Int(width) - 150, y: 20)!
                                .usingColorSpace(.deviceRGB)!
                            if width >= 900 {
                                #expect(secondary.greenComponent > secondary.redComponent + 0.2)
                            } else {
                                #expect(secondary.greenComponent <= secondary.redComponent + 0.2)
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func identity(locale: String, status: String, panelCount: Int) -> some View {
        SelectiveRemoteSSHHeaderIdentity(
            title: locale == "ru_RU" ? "Очень длинное название тестового хоста" : "Long synthetic Host title",
            endpoint: "synthetic-host.example.invalid:2222 / \(panelCount) panels / \(status)",
            showsBadge: true
        )
        .background(Color.red)
    }

    @MainActor
    private func render<Content: View>(_ view: Content, width: CGFloat) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 42)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: 42,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}
