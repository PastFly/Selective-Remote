#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    content = read(path)
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old[:90]!r}")
    write(path, content.replace(old, new, 1))


# 1. Snippets: keep the panel open after Run Here / Insert.  A tiny post-host
# script wraps only those two context-menu actions, so explicit X / Escape still closes.
write(
    "Sources/SelectiveRemote/TerminalResources/terminal-panel-persistence.js",
    r'''(() => {
    "use strict";

    const contextMenu = document.getElementById("snippet-context-menu");
    const panel = document.getElementById("terminal-history");
    const snippetOptions = document.getElementById("snippet-options");
    const originalSetPanelMode = window.selectiveTerminalSetPanelMode;

    if (!contextMenu || !panel || !snippetOptions || typeof originalSetPanelMode !== "function") {
        return;
    }

    let preserveForCurrentSnippetAction = false;

    // Capture runs before terminal-host.js handles the same click.  Only actions that
    // used to close the Snippets panel get the one-shot preservation flag.
    contextMenu.addEventListener("click", (event) => {
        const button = event.target.closest("button[data-action]");
        if (!button || !["runHere", "insert"].includes(button.dataset.action)) {
            return;
        }
        preserveForCurrentSnippetAction = true;
        queueMicrotask(() => {
            preserveForCurrentSnippetAction = false;
        });
    }, true);

    window.selectiveTerminalSetPanelMode = (
        mode,
        notifySwift = false,
        restoreTerminalFocus = true
    ) => {
        const snippetsAreVisible = !panel.hidden && !snippetOptions.hidden;
        if (mode === "hidden" && preserveForCurrentSnippetAction && snippetsAreVisible) {
            window.requestAnimationFrame(() => window.selectiveTerminalFit?.());
            return;
        }
        return originalSetPanelMode(mode, notifySwift, restoreTerminalFocus);
    };
})();
'''
)

replace_once(
    "Sources/SelectiveRemote/TerminalResources/terminal.html",
    '    <script src="terminal-host.js"></script>\n',
    '    <script src="terminal-host.js"></script>\n'
    '    <script src="terminal-panel-persistence.js"></script>\n'
)

# 2. Settings: while update check is active, remove the closable capability from
# the actual SwiftUI Settings window. This blocks the title-bar close action and Cmd-W.
write(
    "Sources/SelectiveRemote/SettingsWindowCloseGuard.swift",
    r'''import AppKit
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
'''
)

replace_once(
    "Sources/SelectiveRemote/SelectiveRemoteApp.swift",
    '''                AppSettingsView(
                    model: model,
                    appearance: appAppearance,
                    appLock: appLock
                )
''',
    '''                AppSettingsView(
                    model: model,
                    appearance: appAppearance,
                    appLock: appLock
                )
                .background(
                    SettingsWindowCloseGuard(
                        preventsClosing: model.isCheckingForUpdates
                    )
                )
'''
)

# 3/4. Per-pane terminal themes. Existing persisted colorIndex remains the storage
# source, but it now selects an actual xterm palette, not only the pane border.
write(
    "Sources/SelectiveRemote/TerminalPaneTheme.swift",
    r'''import SwiftUI

enum TerminalPaneThemeChoice: Int, CaseIterable, Identifiable, Sendable {
    case inherited = 0
    case ocean = 1
    case hackerGreen = 2
    case dracula = 3
    case rosePine = 4
    case solarizedLight = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .inherited: "Общее оформление"
        case .ocean: TerminalThemePreset.ocean.title
        case .hackerGreen: TerminalThemePreset.hackerGreen.title
        case .dracula: TerminalThemePreset.dracula.title
        case .rosePine: TerminalThemePreset.rosePine.title
        case .solarizedLight: TerminalThemePreset.solarizedLight.title
        }
    }

    var preset: TerminalThemePreset? {
        switch self {
        case .inherited: nil
        case .ocean: .ocean
        case .hackerGreen: .hackerGreen
        case .dracula: .dracula
        case .rosePine: .rosePine
        case .solarizedLight: .solarizedLight
        }
    }

    static func normalized(_ colorIndex: Int) -> TerminalPaneThemeChoice {
        TerminalPaneThemeChoice(rawValue: max(0, colorIndex) % allCases.count) ?? .inherited
    }
}

extension TerminalAppearanceSnapshot {
    func applyingPaneTheme(colorIndex: Int) -> TerminalAppearanceSnapshot {
        guard let preset = TerminalPaneThemeChoice.normalized(colorIndex).preset else {
            return self
        }
        let panePalette = preset.palette
        return TerminalAppearanceSnapshot(
            fontFamily: fontFamily,
            fontSize: fontSize,
            lineHeight: lineHeight,
            cursorStyle: cursorStyle,
            cursorBlink: cursorBlink,
            syntaxHighlighting: syntaxHighlighting,
            syntaxScope: syntaxScope,
            syntaxHistoryOpacity: syntaxHistoryOpacity,
            syntaxBoldCommands: syntaxBoldCommands,
            syntaxPalette: TerminalSyntaxPalette(theme: panePalette),
            padding: padding,
            theme: panePalette
        )
    }
}

@MainActor
func setTerminalPaneTheme(
    _ choice: TerminalPaneThemeChoice,
    tabID: UUID,
    workspace: TerminalWorkspaceModel
) {
    guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else { return }
    let count = TerminalPaneThemeChoice.allCases.count
    let current = TerminalPaneThemeChoice.normalized(tab.colorIndex).rawValue
    let steps = (choice.rawValue - current + count) % count
    guard steps > 0 else { return }
    for _ in 0..<steps {
        workspace.cycleColor(tabID)
    }
}

struct TerminalPaneThemePicker: View {
    let colorIndex: Int
    let select: (TerminalPaneThemeChoice) -> Void

    private var current: TerminalPaneThemeChoice {
        .normalized(colorIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Цвет этой панели")
                .font(.headline)
            Text("Шрифт, курсор и остальные параметры остаются общими.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(TerminalPaneThemeChoice.allCases) { choice in
                Button {
                    select(choice)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(previewColor(choice))
                            .frame(width: 24, height: 18)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15))
                            }
                        Text(choice.title)
                        Spacer(minLength: 12)
                        if choice == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    choice == current ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func previewColor(_ choice: TerminalPaneThemeChoice) -> Color {
        let palette = choice.preset?.palette ?? TerminalThemePreset.midnight.palette
        return Color(nsColor: TerminalColorCodec.nsColor(palette.background))
    }
}
'''
)

# Local terminal: make toolbar icon sizing match SSH and expose per-pane palette.
replace_once(
    "Sources/SelectiveRemote/LocalTerminalView.swift",
    '    @State private var showsAppearance = false\n',
    '    @State private var showsAppearance = false\n    @State private var showsPaneTheme = false\n'
)

for image in [
    'selectedTab.session.isRunning ? "arrow.clockwise" : "play.fill"',
    '"clock.arrow.circlepath"',
    '"text.badge.plus"',
    '"folder"',
    '"eraser"',
    '"paintpalette"',
]:
    old = f'                Image(systemName: {image})\n'
    new = old + '                    .font(.title3)\n'
    replace_once("Sources/SelectiveRemote/LocalTerminalView.swift", old, new)

replace_once(
    "Sources/SelectiveRemote/LocalTerminalView.swift",
    '''            Button {
                showsAppearance.toggle()
            } label: {
                Image(systemName: "paintpalette")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("Оформление терминала")
            .popover(isPresented: $showsAppearance, arrowEdge: .bottom) {
                TerminalAppearanceView(store: appearance, appAppearance: appAppearance)
            }
''',
    '''            Button {
                showsPaneTheme.toggle()
            } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("Цвет этой панели")
            .popover(isPresented: $showsPaneTheme, arrowEdge: .bottom) {
                TerminalPaneThemePicker(colorIndex: selectedTab.colorIndex) { choice in
                    setTerminalPaneTheme(
                        choice,
                        tabID: selectedTab.id,
                        workspace: workspace
                    )
                }
            }

            Button {
                showsAppearance.toggle()
            } label: {
                Image(systemName: "paintpalette")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("Общее оформление терминала")
            .popover(isPresented: $showsAppearance, arrowEdge: .bottom) {
                TerminalAppearanceView(store: appearance, appAppearance: appAppearance)
            }
'''
)

replace_once(
    "Sources/SelectiveRemote/LocalTerminalView.swift",
    '''    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        EmbeddedTerminalWebView(
            session: tab.session,
            appearance: appearance.snapshot,
''',
    '''    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        let paneAppearance = appearance.snapshot.applyingPaneTheme(
            colorIndex: tab.colorIndex
        )
        return EmbeddedTerminalWebView(
            session: tab.session,
            appearance: paneAppearance,
'''
)
replace_once(
    "Sources/SelectiveRemote/LocalTerminalView.swift",
    '        .background(TerminalColorCodecView.color(appearance.palette.background))\n',
    '        .background(TerminalColorCodecView.color(paneAppearance.theme.background))\n'
)

# SSH terminal: visible per-pane theme picker + pass that palette into each WebView.
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '    @State private var showsAppearance = false\n',
    '    @State private var showsAppearance = false\n    @State private var showsPaneTheme = false\n'
)

replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''            Button {
                showsHistory = false
                showsSnippets.toggle()
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help(locale.identifier.lowercased().hasPrefix("en") ? "Snippets" : "Сниппеты")

            if isFocusMode {
''',
    '''            Button {
                showsHistory = false
                showsSnippets.toggle()
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help(locale.identifier.lowercased().hasPrefix("en") ? "Snippets" : "Сниппеты")

            Button {
                showsPaneTheme.toggle()
            } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help(locale.identifier.lowercased().hasPrefix("en")
                ? "Color for this terminal"
                : "Цвет этой SSH-панели")
            .popover(isPresented: $showsPaneTheme, arrowEdge: .bottom) {
                TerminalPaneThemePicker(colorIndex: tab.colorIndex) { choice in
                    setTerminalPaneTheme(
                        choice,
                        tabID: tab.id,
                        workspace: workspace
                    )
                }
            }

            if isFocusMode {
'''
)

replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        let color = paneColor(for: tab)
        let isSelected = tab.id == workspace.selectedTabID
''',
    '''    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        let color = paneColor(for: tab)
        let paneAppearance = appearance.snapshot.applyingPaneTheme(
            colorIndex: tab.colorIndex
        )
        let isSelected = tab.id == workspace.selectedTabID
'''
)
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''            EmbeddedTerminalWebView(
                session: tab.session,
                appearance: appearance.snapshot,
''',
    '''            EmbeddedTerminalWebView(
                session: tab.session,
                appearance: paneAppearance,
'''
)
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '        .background(TerminalColorCodecView.color(appearance.palette.background))\n        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))\n',
    '        .background(TerminalColorCodecView.color(paneAppearance.theme.background))\n        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))\n'
)

# Test-candidate version. Production update manifest remains untouched until user approval.
replace_once(
    "scripts/build_app.sh",
    'VERSION="0.24.0"\n',
    'VERSION="0.25.0"\n'
)
replace_once(
    "scripts/build_app.sh",
    'BUILD_NUMBER="133"\n',
    'BUILD_NUMBER="134"\n'
)

# Regression tests for all four requested changes.
write(
    "Tests/TerminalResourcesTests/terminal-panel-persistence.test.js",
    r'''const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.join(__dirname, "../..");
const html = fs.readFileSync(
    path.join(root, "Sources/SelectiveRemote/TerminalResources/terminal.html"),
    "utf8"
);
const persistence = fs.readFileSync(
    path.join(root, "Sources/SelectiveRemote/TerminalResources/terminal-panel-persistence.js"),
    "utf8"
);

test("snippet persistence layer loads after terminal host", () => {
    const hostIndex = html.indexOf('src="terminal-host.js"');
    const persistenceIndex = html.indexOf('src="terminal-panel-persistence.js"');
    assert.ok(hostIndex >= 0);
    assert.ok(persistenceIndex > hostIndex);
});

test("run here and insert keep Snippets open while explicit close remains available", () => {
    assert.match(persistence, /\["runHere", "insert"\]/);
    assert.match(persistence, /mode === "hidden" && preserveForCurrentSnippetAction/);
    assert.match(persistence, /return originalSetPanelMode\(mode, notifySwift, restoreTerminalFocus\)/);
});
'''
)

write(
    "Tests/SelectiveRemoteTests/TerminalUX0250Tests.swift",
    r'''import Foundation
import Testing
@testable import SelectiveRemote

struct TerminalUX0250Tests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("Update check guards the Settings window from closing")
    func updateCheckCloseGuardExists() throws {
        let app = try source("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        let guardSource = try source("Sources/SelectiveRemote/SettingsWindowCloseGuard.swift")
        #expect(app.contains("preventsClosing: model.isCheckingForUpdates"))
        #expect(guardSource.contains("window.styleMask.remove(.closable)"))
        #expect(guardSource.contains("window.styleMask.insert(.closable)"))
    }

    @Test("Local toolbar uses SSH-sized icon controls")
    func localToolbarUsesTitle3Icons() throws {
        let local = try source("Sources/SelectiveRemote/LocalTerminalView.swift")
        #expect(local.contains("Image(systemName: \"clock.arrow.circlepath\")\n                    .font(.title3)"))
        #expect(local.contains("Image(systemName: \"text.badge.plus\")\n                    .font(.title3)"))
        #expect(local.contains("Image(systemName: \"paintpalette.fill\")\n                    .font(.title3)"))
    }

    @Test("Every terminal pane can override the global palette")
    func paneThemeOverrideIsAppliedToLocalAndSSH() throws {
        let theme = try source("Sources/SelectiveRemote/TerminalPaneTheme.swift")
        let local = try source("Sources/SelectiveRemote/LocalTerminalView.swift")
        let ssh = try source("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
        #expect(theme.contains("applyingPaneTheme(colorIndex:"))
        #expect(theme.contains("TerminalPaneThemeChoice"))
        #expect(local.contains("appearance: paneAppearance"))
        #expect(ssh.contains("appearance: paneAppearance"))
        #expect(local.contains("TerminalPaneThemePicker"))
        #expect(ssh.contains("TerminalPaneThemePicker"))
    }
}
'''
)

# Update an older source-contract assertion: insert no longer intentionally closes
# the panel. The dedicated persistence test now owns that behavior.
replace_once(
    "Tests/TerminalResourcesTests/terminal-snippet-global.test.js",
    '    assert.match(hostScript, /replaceCurrentLine\\(entry\\.command, true\\)/);\n',
    '    assert.match(hostScript, /action === "insert"/);\n'
)

print("v0.25.0 terminal UX patch applied")
