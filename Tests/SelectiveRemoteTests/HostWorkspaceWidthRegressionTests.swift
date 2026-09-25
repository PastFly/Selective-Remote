import AppKit
import SwiftUI
import Testing
@testable import SelectiveRemote

private struct WidthProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

struct HostWorkspaceWidthRegressionTests {
    @MainActor
    @Test("Personal Host catalog and detail stay inside actual workspace width")
    func personalColumnsFitWindow() throws {
        try assertColumnsFit(catalogMinimum: 300, detailPreferred: 520)
    }

    @MainActor
    @Test("Team Host catalog and detail stay inside actual workspace width")
    func teamColumnsFitWindow() throws {
        try assertColumnsFit(catalogMinimum: 290, detailPreferred: 480)
    }

    @MainActor
    @Test("Team Snippet collection and inspector fit the residual width after sidebar")
    func teamSnippetColumnsFitWindow() throws {
        try assertColumnsFit(
            catalogMinimum: 340, detailPreferred: 420,
            widths: [670, 700, 790, 900], catalogPreference: false
        )
    }

    @Test("Profile Forwarding stacks before its 800 point split minimum exceeds the viewport")
    func forwardingBreakpoint() {
        #expect(AdaptiveWorkspaceLayout.usesStackedProfileForwarding(width: 670))
        #expect(AdaptiveWorkspaceLayout.usesStackedProfileForwarding(width: 790))
        #expect(!AdaptiveWorkspaceLayout.usesStackedProfileForwarding(width: 820))
    }

    @MainActor
    @Test("Host Shelf, catalog and full Terminal fit the supported window widths")
    func terminalInsideWorkspace() throws {
        let scenarios: [(Int, CGFloat, Bool, Bool, Int, String, ColorScheme)] = [
            (1050, 260, true, true, 1, "ru_RU", .light),
            (1050, 260, true, false, 1, "en_US", .dark),
            (1050, 380, true, false, 2, "en_US", .dark),
            (1100, 300, true, true, 3, "en_US", .light),
            (1100, 300, false, false, 4, "ru_RU", .dark),
            (1260, 300, true, true, 4, "ru_RU", .light),
            (1260, 300, true, false, 4, "en_US", .dark),
            (1450, 380, true, false, 2, "en_US", .dark),
            (1800, 260, true, true, 1, "en_US", .light),
            (1800, 260, false, false, 3, "ru_RU", .dark)
        ]

        for (width, sidebarWidth, catalogPreference, shelfShown, panes, locale, scheme) in scenarios {
            let suite = "SelectiveRemoteTests.WorkspaceWidth.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let workspace = TerminalWorkspaceModel(
                profileID: UUID(), primarySession: TerminalSessionModel(),
                primaryConnection: .custom(host: "synthetic.example.invalid", username: "tester"),
                defaults: defaults
            )
            if panes > 1 {
                for _ in 1..<panes { _ = workspace.addTab(select: false) }
                workspace.setLayout(panes == 2 ? .splitHorizontal : .grid)
            }
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
            let content = HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.gray
                    if shelfShown { Color.teal.frame(height: 180) }
                }
                .frame(width: sidebarWidth)
                GeometryReader { geometry in
                    let catalogVisible = SelectiveRemoteHostCatalogLayout.showsCatalog(
                        preference: catalogPreference,
                        availableWidth: geometry.size.width,
                        detailVisible: true
                    )
                    HSplitView {
                        if catalogVisible {
                            Color.gray
                                .frame(minWidth: 300, idealWidth: 380, maxWidth: 500)
                                .background(WidthProbe(name: "catalog"))
                        }
                        VStack(spacing: 0) {
                            SelectiveRemoteMeasuredHeaderRow(minimumIdentityWidth: 220) {
                                SelectiveRemoteSSHHeaderIdentity(
                                    title: "Synthetic Host",
                                    endpoint: "synthetic.example.invalid:22",
                                    showsBadge: true
                                )
                                .background(WidthProbe(name: "identity"))
                            } trailing: {
                                HStack {
                                    Text("Terminal / SFTP / Forwarding")
                                        .lineLimit(1)
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                .background(WidthProbe(name: "header-actions"))
                            }
                            terminal.background(WidthProbe(name: "terminal"))
                        }
                        .frame(
                            minWidth: SelectiveRemoteSplitColumnLayout.detailMinimumWidth(
                                preferred: 520,
                                availableWidth: geometry.size.width,
                                leadingVisible: catalogVisible,
                                leadingMinimumWidth: 300
                            ),
                            maxWidth: .infinity
                        )
                        .background(WidthProbe(name: "detail"))
                    }
                }
            }
            .environment(\.locale, Locale(identifier: locale))
            .preferredColorScheme(scheme)

            let host = NSHostingView(rootView: content)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            if ProcessInfo.processInfo.environment["SR_CAPTURE_WORKSPACE_MATRIX"] == "1" {
                let bitmap = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: width, pixelsHigh: 700,
                    bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath:
                        "/private/tmp/sr-workspace-\(width)-\(Int(sidebarWidth))-\(panes)-\(locale)-\(scheme == .dark ? "dark" : "light").png")
                )
            }
            for name in ["detail", "terminal"] {
                let probe = try #require(findProbe(name, in: host))
                let frame = probe.convert(probe.bounds, to: host)
                #expect(frame.maxX <= CGFloat(width) + 1,
                        "\(name) right edge \(frame.maxX) exceeds \(width)-px window; \(panes) panes")
                #expect(frame.minX >= sidebarWidth - 1)
            }
            let detailView = try #require(findProbe("detail", in: host))
            let detail = detailView.convert(detailView.bounds, to: host)
            let identityView = try #require(findProbe("identity", in: host))
            let actionsView = try #require(findProbe("header-actions", in: host))
            let identity = identityView.convert(identityView.bounds, to: host)
            let actions = actionsView.convert(actionsView.bounds, to: host)
            #expect(identity.maxX <= actions.minX + 1,
                    "Host identity overlaps header actions at \(width)px")
            #expect(actions.maxX <= detail.maxX + 1,
                    "Header actions exceed actual detail width at \(width)px")
        }
    }

    @MainActor
    private func assertColumnsFit(
        catalogMinimum: CGFloat, detailPreferred: CGFloat,
        widths: [Int] = [760, 790, 820, 900], catalogPreference: Bool = true
    ) throws {
        for width in widths {
            let content = GeometryReader { geometry in
                HSplitView {
                    if !catalogPreference || SelectiveRemoteHostCatalogLayout.showsCatalog(
                        preference: true,
                        availableWidth: geometry.size.width,
                        detailVisible: true
                    ) {
                        Color.gray
                            .frame(
                                minWidth: catalogMinimum,
                                idealWidth: catalogMinimum + 80,
                                maxWidth: catalogMinimum + 200
                            )
                            .background(WidthProbe(name: "catalog"))
                    }
                    Color.blue
                        .frame(
                            minWidth: SelectiveRemoteSplitColumnLayout.detailMinimumWidth(
                                preferred: detailPreferred,
                                availableWidth: geometry.size.width,
                                leadingVisible: true,
                                leadingMinimumWidth: catalogMinimum
                            ),
                            maxWidth: .infinity
                        )
                        .background(WidthProbe(name: "detail"))
                }
            }
            let host = NSHostingView(rootView: content)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            let detail = try #require(findProbe("detail", in: host))
            let detailFrame = detail.convert(detail.bounds, to: host)
            #expect(detailFrame.maxX <= CGFloat(width) + 1,
                    "detail trailing edge \(detailFrame.maxX) exceeds \(width)-px workspace")
        }
    }

    @MainActor
    private func findProbe(_ name: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == name { return root }
        for child in root.subviews {
            if let match = findProbe(name, in: child) { return match }
        }
        return nil
    }
}
