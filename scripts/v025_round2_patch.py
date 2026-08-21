#!/usr/bin/env python3
from pathlib import Path
import re

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
        raise RuntimeError(f"{path}: expected exactly one match, got {count}: {old[:120]!r}")
    write(path, content.replace(old, new, 1))


def regex_replace_once(path: str, pattern: str, replacement: str, flags: int = 0) -> None:
    content = read(path)
    changed, count = re.subn(pattern, replacement, content, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one regex match, got {count}: {pattern[:120]!r}")
    write(path, changed)


# ---------------------------------------------------------------------------
# 1. Update checks launched from Settings stay entirely inside Settings.
# ---------------------------------------------------------------------------
replace_once(
    "Sources/SelectiveRemote/AppModel.swift",
    '''    func checkForUpdates() {\n        checkForUpdates(announcesUpToDate: true)\n    }\n\n    private func checkForUpdatesAutomatically() {\n''',
    '''    func checkForUpdates() {\n        checkForUpdates(announcesUpToDate: true)\n    }\n\n    func checkForUpdatesFromSettings() {\n        // Settings already renders checking / up-to-date / available states inline.\n        // Do not publish updateMessage here: ContentView owns that alert and would\n        // steal key-window focus from the separate SwiftUI Settings scene.\n        checkForUpdates(announcesUpToDate: false)\n    }\n\n    private func checkForUpdatesAutomatically() {\n'''
)
replace_once(
    "Sources/SelectiveRemote/UpdateExperienceView.swift",
    '''                    Button("Проверить сейчас", systemImage: "arrow.clockwise") {\n                        model.checkForUpdates()\n                    }\n                    .disabled(model.isCheckingForUpdates)\n''',
    '''                    Button("Проверить сейчас", systemImage: "arrow.clockwise") {\n                        model.checkForUpdatesFromSettings()\n                    }\n                    .disabled(model.isCheckingForUpdates)\n'''
)


# ---------------------------------------------------------------------------
# 2. Full per-terminal appearance stores. Every tab gets the same settings
# surface as the global terminal appearance (themes/preview/font/cursor/syntax/
# custom theme), persisted under its stable tab UUID.
# ---------------------------------------------------------------------------
appearance_path = "Sources/SelectiveRemote/TerminalAppearance.swift"
appearance = read(appearance_path)
appearance = appearance.replace(
    '''        static let customPalette = "SelectiveRemote.terminal.customPalette.v1"\n        static let themeFavorites = "SelectiveRemote.terminal.themeFavorites.v1"\n    }\n''',
    '''        static let customPalette = "SelectiveRemote.terminal.customPalette.v1"\n        static let themeFavorites = "SelectiveRemote.terminal.themeFavorites.v1"\n\n        static let all = [\n            preset, palette, font, fontSize, lineHeight, cursorStyle, cursorBlink,\n            syntaxHighlighting, syntaxScope, syntaxFollowTheme, syntaxHistoryOpacity,\n            syntaxBoldCommands, syntaxPalette, padding, customPalette, themeFavorites\n        ]\n    }\n''',
    1
)
appearance = appearance.replace(
    '''    private let defaults: UserDefaults\n    private var customPalette: TerminalPalette\n\n    init(defaults: UserDefaults = .standard) {\n        self.defaults = defaults\n        let preset = defaults.string(forKey: Key.preset)\n            .flatMap(TerminalThemePreset.init(rawValue:)) ?? .midnight\n        let legacyPalette = defaults.data(forKey: Key.palette)\n            .flatMap { try? JSONDecoder().decode(TerminalPalette.self, from: $0) }\n        let storedCustomPalette = defaults.data(forKey: Key.customPalette)\n            .flatMap { try? JSONDecoder().decode(TerminalPalette.self, from: $0) }\n        let migratedCustomPalette = storedCustomPalette\n            ?? (preset == .custom ? legacyPalette : nil)\n            ?? TerminalThemePreset.midnight.palette\n\n        selectedPreset = preset\n        customPalette = migratedCustomPalette\n        palette = preset == .custom\n            ? migratedCustomPalette\n            : (legacyPalette ?? preset.palette)\n        favoritePresetIDs = Set(defaults.stringArray(forKey: Key.themeFavorites) ?? [])\n\n        if storedCustomPalette == nil,\n           preset == .custom,\n           let data = try? JSONEncoder().encode(migratedCustomPalette) {\n            defaults.set(data, forKey: Key.customPalette)\n        }\n\n        font = defaults.string(forKey: Key.font)\n            .flatMap(TerminalFontChoice.init(rawValue:)) ?? .sfMono\n        let storedFontSize = defaults.double(forKey: Key.fontSize)\n        fontSize = storedFontSize > 0 ? min(max(storedFontSize, 10), 28) : 14\n        let storedLineHeight = defaults.double(forKey: Key.lineHeight)\n        lineHeight = storedLineHeight > 0 ? min(max(storedLineHeight, 1.0), 1.6) : 1.15\n        cursorStyle = defaults.string(forKey: Key.cursorStyle)\n            .flatMap(TerminalCursorStyle.init(rawValue:)) ?? .block\n        cursorBlink = defaults.object(forKey: Key.cursorBlink) as? Bool ?? true\n        syntaxHighlighting = defaults.object(forKey: Key.syntaxHighlighting) as? Bool ?? true\n        syntaxScope = defaults.string(forKey: Key.syntaxScope)\n            .flatMap(TerminalSyntaxScope.init(rawValue:)) ?? .visibleCommands\n        syntaxFollowTheme = defaults.object(forKey: Key.syntaxFollowTheme) as? Bool ?? true\n        let storedSyntaxHistoryOpacity = defaults.double(forKey: Key.syntaxHistoryOpacity)\n        syntaxHistoryOpacity = storedSyntaxHistoryOpacity > 0\n            ? min(max(storedSyntaxHistoryOpacity, 0.45), 1.0)\n            : 0.82\n        syntaxBoldCommands = defaults.object(forKey: Key.syntaxBoldCommands) as? Bool ?? true\n        syntaxCustomPalette = defaults.data(forKey: Key.syntaxPalette)\n            .flatMap { try? JSONDecoder().decode(TerminalSyntaxPalette.self, from: $0) }\n            ?? TerminalSyntaxPalette(\n                theme: preset == .custom\n                    ? migratedCustomPalette\n                    : (legacyPalette ?? preset.palette)\n            )\n        let storedPadding = defaults.double(forKey: Key.padding)\n        padding = defaults.object(forKey: Key.padding) == nil\n            ? 10\n            : min(max(storedPadding, 0), 28)\n    }\n''',
    '''    private let defaults: UserDefaults\n    private let storageNamespace: String?\n    private var customPalette: TerminalPalette\n\n    init(\n        defaults: UserDefaults = .standard,\n        storageNamespace: String? = nil,\n        cloneGlobalIfMissing: Bool = false\n    ) {\n        self.defaults = defaults\n        self.storageNamespace = storageNamespace\n\n        let resolvedKey: (String) -> String = { key in\n            guard let storageNamespace, !storageNamespace.isEmpty else { return key }\n            return "\\(key).scope.\\(storageNamespace)"\n        }\n\n        if storageNamespace != nil,\n           cloneGlobalIfMissing,\n           defaults.object(forKey: resolvedKey(Key.preset)) == nil {\n            for key in Key.all {\n                if let value = defaults.object(forKey: key) {\n                    defaults.set(value, forKey: resolvedKey(key))\n                }\n            }\n        }\n\n        let preset = defaults.string(forKey: resolvedKey(Key.preset))\n            .flatMap(TerminalThemePreset.init(rawValue:)) ?? .midnight\n        let legacyPalette = defaults.data(forKey: resolvedKey(Key.palette))\n            .flatMap { try? JSONDecoder().decode(TerminalPalette.self, from: $0) }\n        let storedCustomPalette = defaults.data(forKey: resolvedKey(Key.customPalette))\n            .flatMap { try? JSONDecoder().decode(TerminalPalette.self, from: $0) }\n        let migratedCustomPalette = storedCustomPalette\n            ?? (preset == .custom ? legacyPalette : nil)\n            ?? TerminalThemePreset.midnight.palette\n\n        selectedPreset = preset\n        customPalette = migratedCustomPalette\n        palette = preset == .custom\n            ? migratedCustomPalette\n            : (legacyPalette ?? preset.palette)\n        favoritePresetIDs = Set(\n            defaults.stringArray(forKey: resolvedKey(Key.themeFavorites)) ?? []\n        )\n\n        if storedCustomPalette == nil,\n           preset == .custom,\n           let data = try? JSONEncoder().encode(migratedCustomPalette) {\n            defaults.set(data, forKey: resolvedKey(Key.customPalette))\n        }\n\n        font = defaults.string(forKey: resolvedKey(Key.font))\n            .flatMap(TerminalFontChoice.init(rawValue:)) ?? .sfMono\n        let storedFontSize = defaults.double(forKey: resolvedKey(Key.fontSize))\n        fontSize = storedFontSize > 0 ? min(max(storedFontSize, 10), 28) : 14\n        let storedLineHeight = defaults.double(forKey: resolvedKey(Key.lineHeight))\n        lineHeight = storedLineHeight > 0 ? min(max(storedLineHeight, 1.0), 1.6) : 1.15\n        cursorStyle = defaults.string(forKey: resolvedKey(Key.cursorStyle))\n            .flatMap(TerminalCursorStyle.init(rawValue:)) ?? .block\n        cursorBlink = defaults.object(forKey: resolvedKey(Key.cursorBlink)) as? Bool ?? true\n        syntaxHighlighting = defaults.object(\n            forKey: resolvedKey(Key.syntaxHighlighting)\n        ) as? Bool ?? true\n        syntaxScope = defaults.string(forKey: resolvedKey(Key.syntaxScope))\n            .flatMap(TerminalSyntaxScope.init(rawValue:)) ?? .visibleCommands\n        syntaxFollowTheme = defaults.object(\n            forKey: resolvedKey(Key.syntaxFollowTheme)\n        ) as? Bool ?? true\n        let storedSyntaxHistoryOpacity = defaults.double(\n            forKey: resolvedKey(Key.syntaxHistoryOpacity)\n        )\n        syntaxHistoryOpacity = storedSyntaxHistoryOpacity > 0\n            ? min(max(storedSyntaxHistoryOpacity, 0.45), 1.0)\n            : 0.82\n        syntaxBoldCommands = defaults.object(\n            forKey: resolvedKey(Key.syntaxBoldCommands)\n        ) as? Bool ?? true\n        syntaxCustomPalette = defaults.data(forKey: resolvedKey(Key.syntaxPalette))\n            .flatMap { try? JSONDecoder().decode(TerminalSyntaxPalette.self, from: $0) }\n            ?? TerminalSyntaxPalette(\n                theme: preset == .custom\n                    ? migratedCustomPalette\n                    : (legacyPalette ?? preset.palette)\n            )\n        let storedPadding = defaults.double(forKey: resolvedKey(Key.padding))\n        padding = defaults.object(forKey: resolvedKey(Key.padding)) == nil\n            ? 10\n            : min(max(storedPadding, 0), 28)\n    }\n''',
    1
)
if appearance.count('storageNamespace: String? = nil') != 1:
    raise RuntimeError("TerminalAppearanceStore init replacement failed")
appearance = appearance.replace(
    '''        defaults.set(favoritePresetIDs.sorted(), forKey: Key.themeFavorites)\n''',
    '''        defaults.set(favoritePresetIDs.sorted(), forKey: storageKey(Key.themeFavorites))\n''',
    1
)
appearance = appearance.replace(
    '''    func updateSyntaxColor(\n''',
    '''    func copySettings(from source: TerminalAppearanceStore) {\n        selectedPreset = source.selectedPreset\n        palette = source.palette\n        customPalette = source.customThemePalette\n        favoritePresetIDs = source.favoritePresetIDs\n        font = source.font\n        fontSize = source.fontSize\n        lineHeight = source.lineHeight\n        cursorStyle = source.cursorStyle\n        cursorBlink = source.cursorBlink\n        syntaxHighlighting = source.syntaxHighlighting\n        syntaxScope = source.syntaxScope\n        syntaxFollowTheme = source.syntaxFollowTheme\n        syntaxHistoryOpacity = source.syntaxHistoryOpacity\n        syntaxBoldCommands = source.syntaxBoldCommands\n        syntaxCustomPalette = source.syntaxCustomPalette\n        padding = source.padding\n        saveCustomPalette()\n        saveSyntaxPalette()\n        savePresetAndPalette()\n        defaults.set(\n            favoritePresetIDs.sorted(),\n            forKey: storageKey(Key.themeFavorites)\n        )\n    }\n\n    func updateSyntaxColor(\n''',
    1
)
appearance = appearance.replace(
    '''            defaults.set(data, forKey: Key.customPalette)\n''',
    '''            defaults.set(data, forKey: storageKey(Key.customPalette))\n''',
    1
)
appearance = appearance.replace(
    '''            defaults.set(data, forKey: Key.syntaxPalette)\n''',
    '''            defaults.set(data, forKey: storageKey(Key.syntaxPalette))\n''',
    1
)
appearance = appearance.replace(
    '''        defaults.set(selectedPreset.rawValue, forKey: Key.preset)\n        if let data = try? JSONEncoder().encode(palette) {\n            defaults.set(data, forKey: Key.palette)\n        }\n    }\n\n    private func saveScalar(_ value: Any, key: String) {\n        defaults.set(value, forKey: key)\n    }\n''',
    '''        defaults.set(selectedPreset.rawValue, forKey: storageKey(Key.preset))\n        if let data = try? JSONEncoder().encode(palette) {\n            defaults.set(data, forKey: storageKey(Key.palette))\n        }\n    }\n\n    private func saveScalar(_ value: Any, key: String) {\n        defaults.set(value, forKey: storageKey(key))\n    }\n\n    private func storageKey(_ key: String) -> String {\n        guard let storageNamespace, !storageNamespace.isEmpty else { return key }\n        return "\\(key).scope.\\(storageNamespace)"\n    }\n''',
    1
)
appearance = appearance.replace(
    '''    @ObservedObject var store: TerminalAppearanceStore\n    @ObservedObject var appAppearance: AppAppearanceStore\n\n    var body: some View {\n        Form {\n            Section("Язык приложения") {\n''',
    '''    @ObservedObject var store: TerminalAppearanceStore\n    @ObservedObject var appAppearance: AppAppearanceStore\n    var includesApplicationSettings = true\n    var individualTitle: String? = nil\n    var copyFrom: TerminalAppearanceStore? = nil\n\n    var body: some View {\n        Form {\n            if let individualTitle {\n                Section("Индивидуальное оформление") {\n                    Label(individualTitle, systemImage: "rectangle.inset.filled.and.person.filled")\n                        .font(.headline)\n                    Text("Тема, шрифт, курсор, подсветка синтаксиса и своя палитра сохраняются только для этой вкладки терминала.")\n                        .font(.caption)\n                        .foregroundStyle(.secondary)\n                    if let copyFrom {\n                        Button("Скопировать общее оформление", systemImage: "square.on.square") {\n                            store.copySettings(from: copyFrom)\n                        }\n                    }\n                }\n            }\n\n            if includesApplicationSettings {\n            Section("Язык приложения") {\n''',
    1
)
appearance = appearance.replace(
    '''            AppAppearanceSettingsSection(store: appAppearance)\n\n            Section("Терминал") {\n''',
    '''            AppAppearanceSettingsSection(store: appAppearance)\n            }\n\n            Section("Терминал") {\n''',
    1
)
appearance = appearance.replace(
    '''                Button("Сбросить оформление") {\n                    store.reset()\n                    appAppearance.reset()\n                }\n''',
    '''                Button("Сбросить оформление") {\n                    store.reset()\n                    if includesApplicationSettings {\n                        appAppearance.reset()\n                    }\n                }\n''',
    1
)
write(appearance_path, appearance)

workspace_path = "Sources/SelectiveRemote/TerminalWorkspace.swift"
workspace = read(workspace_path)
workspace = workspace.replace(
    '''struct TerminalWorkspaceTab: Identifiable {\n    let id: UUID\n    var title: String\n    let session: TerminalSessionModel\n    var isPrimary: Bool\n    var connection: TerminalTabConnection\n    var isPinned: Bool\n    var colorIndex: Int\n\n    @MainActor var isEmptyPlaceholder: Bool {\n''',
    '''struct TerminalWorkspaceTab: Identifiable {\n    let id: UUID\n    var title: String\n    let session: TerminalSessionModel\n    var isPrimary: Bool\n    var connection: TerminalTabConnection\n    var isPinned: Bool\n    var colorIndex: Int\n    let appearance: TerminalAppearanceStore\n\n    @MainActor\n    init(\n        id: UUID,\n        title: String,\n        session: TerminalSessionModel,\n        isPrimary: Bool,\n        connection: TerminalTabConnection,\n        isPinned: Bool,\n        colorIndex: Int,\n        appearanceDefaults: UserDefaults = .standard\n    ) {\n        self.id = id\n        self.title = title\n        self.session = session\n        self.isPrimary = isPrimary\n        self.connection = connection\n        self.isPinned = isPinned\n        self.colorIndex = colorIndex\n        appearance = TerminalAppearanceStore(\n            defaults: appearanceDefaults,\n            storageNamespace: "pane.\\(id.uuidString)",\n            cloneGlobalIfMissing: true\n        )\n    }\n\n    @MainActor var isEmptyPlaceholder: Bool {\n''',
    1
)
workspace = workspace.replace(
    '''    private var sessionObservers: [UUID: AnyCancellable] = [:]\n    private var sessionPhaseObservers: [UUID: AnyCancellable] = [:]\n''',
    '''    private var sessionObservers: [UUID: AnyCancellable] = [:]\n    private var sessionPhaseObservers: [UUID: AnyCancellable] = [:]\n    private var appearanceObservers: [UUID: AnyCancellable] = [:]\n''',
    1
)
# Every tab construction in this model should use the workspace's UserDefaults suite.
workspace = workspace.replace(
    '''                colorIndex: primaryMetadata.colorIndex ?? 0\n            )\n''',
    '''                colorIndex: primaryMetadata.colorIndex ?? 0,\n                appearanceDefaults: defaults\n            )\n''',
    1
)
workspace = workspace.replace(
    '''                    colorIndex: metadata.colorIndex ?? restoredTabs.count % 6\n                )\n''',
    '''                    colorIndex: metadata.colorIndex ?? restoredTabs.count % 6,\n                    appearanceDefaults: defaults\n                )\n''',
    1
)
workspace = workspace.replace(
    '''            colorIndex: tabs.count % 6\n        )\n''',
    '''            colorIndex: tabs.count % 6,\n            appearanceDefaults: defaults\n        )\n''',
    1
)
workspace = workspace.replace(
    '''            tabs[index].colorIndex = source.colorIndex\n            tabs[index].isPinned = false\n''',
    '''            tabs[index].colorIndex = source.colorIndex\n            tabs[index].appearance.copySettings(from: source.appearance)\n            tabs[index].isPinned = false\n''',
    1
)
workspace = workspace.replace(
    '''        sessionObservers[id] = nil\n        sessionPhaseObservers[id] = nil\n        tabs.remove(at: index)\n''',
    '''        sessionObservers[id] = nil\n        sessionPhaseObservers[id] = nil\n        appearanceObservers[id] = nil\n        tabs.remove(at: index)\n''',
    1
)
workspace = workspace.replace(
    '''        sessionPhaseObservers[tab.id] = tab.session.$phase.sink { [weak self] phase in\n            guard !phase.isRunning else { return }\n            Task { @MainActor [weak self] in\n                self?.invalidateRemoteContext(for: tab.id)\n            }\n        }\n''',
    '''        sessionPhaseObservers[tab.id] = tab.session.$phase.sink { [weak self] phase in\n            guard !phase.isRunning else { return }\n            Task { @MainActor [weak self] in\n                self?.invalidateRemoteContext(for: tab.id)\n            }\n        }\n        appearanceObservers[tab.id] = tab.appearance.objectWillChange.sink { [weak self] _ in\n            Task { @MainActor [weak self] in\n                self?.objectWillChange.send()\n            }\n        }\n''',
    1
)
write(workspace_path, workspace)

# Remove the limited six-color implementation. Per-pane editing now reuses the full editor.
pane_theme = ROOT / "Sources/SelectiveRemote/TerminalPaneTheme.swift"
if pane_theme.exists():
    pane_theme.unlink()

local_path = "Sources/SelectiveRemote/LocalTerminalView.swift"
local = read(local_path)
local = local.replace('    @State private var showsPaneTheme = false\n', '    @State private var showsPaneAppearance = false\n', 1)
local = local.replace(
    '''            Button {\n                showsPaneTheme.toggle()\n            } label: {\n                Image(systemName: "paintpalette.fill")\n                    .font(.title3)\n            }\n            .buttonStyle(.bordered)\n            .help("Цвет этой панели")\n            .popover(isPresented: $showsPaneTheme, arrowEdge: .bottom) {\n                TerminalPaneThemePicker(colorIndex: selectedTab.colorIndex) { choice in\n                    setTerminalPaneTheme(\n                        choice,\n                        tabID: selectedTab.id,\n                        workspace: workspace\n                    )\n                }\n            }\n''',
    '''            Button {\n                showsPaneAppearance.toggle()\n            } label: {\n                Image(systemName: "paintpalette.fill")\n                    .font(.title3)\n            }\n            .buttonStyle(.bordered)\n            .help("Индивидуальное оформление этой вкладки")\n            .popover(isPresented: $showsPaneAppearance, arrowEdge: .bottom) {\n                TerminalAppearanceView(\n                    store: selectedTab.appearance,\n                    appAppearance: appAppearance,\n                    includesApplicationSettings: false,\n                    individualTitle: selectedTab.title,\n                    copyFrom: appearance\n                )\n            }\n''',
    1
)
local = local.replace(
    '''        let paneAppearance = appearance.snapshot.applyingPaneTheme(\n            colorIndex: tab.colorIndex\n        )\n''',
    '''        let paneAppearance = tab.appearance.snapshot\n''',
    1
)
write(local_path, local)

ssh_path = "Sources/SelectiveRemote/EmbeddedTerminalView.swift"
ssh = read(ssh_path)
ssh = ssh.replace('    @State private var showsPaneTheme = false\n', '    @State private var showsPaneAppearance = false\n', 1)
ssh = ssh.replace(
    '''            Button {\n                showsPaneTheme.toggle()\n            } label: {\n                Image(systemName: "paintpalette.fill")\n                    .font(.title3)\n            }\n            .buttonStyle(.bordered)\n            .help(locale.identifier.lowercased().hasPrefix("en")\n                ? "Color for this terminal"\n                : "Цвет этой SSH-панели")\n            .popover(isPresented: $showsPaneTheme, arrowEdge: .bottom) {\n                TerminalPaneThemePicker(colorIndex: tab.colorIndex) { choice in\n                    setTerminalPaneTheme(\n                        choice,\n                        tabID: tab.id,\n                        workspace: workspace\n                    )\n                }\n            }\n''',
    '''            Button {\n                showsPaneAppearance.toggle()\n            } label: {\n                Image(systemName: "paintpalette.fill")\n                    .font(.title3)\n            }\n            .buttonStyle(.bordered)\n            .help(locale.identifier.lowercased().hasPrefix("en")\n                ? "Appearance for this terminal"\n                : "Индивидуальное оформление этой SSH-вкладки")\n            .popover(isPresented: $showsPaneAppearance, arrowEdge: .bottom) {\n                TerminalAppearanceView(\n                    store: tab.appearance,\n                    appAppearance: appAppearance,\n                    includesApplicationSettings: false,\n                    individualTitle: tab.title,\n                    copyFrom: appearance\n                )\n            }\n''',
    1
)
ssh = ssh.replace(
    '''        let paneAppearance = appearance.snapshot.applyingPaneTheme(\n            colorIndex: tab.colorIndex\n        )\n''',
    '''        let paneAppearance = tab.appearance.snapshot\n''',
    1
)
write(ssh_path, ssh)


# ---------------------------------------------------------------------------
# 3. One-monitor fullscreen RDP: SDL's accessible macOS menu reserves vertical
# space in a fullscreen Space. Hide it for our programmatic fullscreen so the
# remote framebuffer and visible window share the same full-height geometry.
# ---------------------------------------------------------------------------
replace_once(
    "Sources/SelectiveRemote/FreeRDPService.swift",
    '''        // Fullscreen RDP owns its macOS Space. Keeping the menu available\n        // reserves vertical space on notched MacBook displays while FreeRDP\n        // still creates a full-height monitor window, clipping the Windows\n        // taskbar below the visible area.\n        environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "1"\n''',
    '''        // Fullscreen RDP owns its macOS Space. An accessible macOS menu bar\n        // reserves vertical space while FreeRDP still creates a full-height\n        // monitor window, which can clip the Windows taskbar below the visible\n        // area. The app provides its own fullscreen escape shortcut, so keep the\n        // system menu hidden for programmatic SDL fullscreen.\n        environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "0"\n'''
)
replace_once(
    "Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift",
    '''@Test("Служебные окна SDL скрыты, а верхнее меню доступно в полном экране")\nfunc configuresSDLSessionEnvironment() {\n''',
    '''@Test("Служебные окна SDL скрыты, а macOS menu bar не режет fullscreen RDP")\nfunc configuresSDLSessionEnvironment() {\n'''
)
virtual_tests = read("Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift")
virtual_tests = virtual_tests.replace(
    '#expect(environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] == "1")',
    '#expect(environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] == "0")'
)
write("Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift", virtual_tests)


# ---------------------------------------------------------------------------
# 4. Replace v0.25.0 regression contracts with behavior-oriented coverage.
# ---------------------------------------------------------------------------
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

    @Test("Update check from Settings stays inline and keeps close guard")
    func settingsUpdateCheckDoesNotPublishMainWindowAlert() throws {
        let app = try source("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        let model = try source("Sources/SelectiveRemote/AppModel.swift")
        let view = try source("Sources/SelectiveRemote/UpdateExperienceView.swift")
        let guardSource = try source("Sources/SelectiveRemote/SettingsWindowCloseGuard.swift")

        #expect(app.contains("preventsClosing: model.isCheckingForUpdates"))
        #expect(model.contains("func checkForUpdatesFromSettings()"))
        #expect(model.contains("checkForUpdates(announcesUpToDate: false)"))
        #expect(view.contains("model.checkForUpdatesFromSettings()"))
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

    @Test("Individual terminal appearance persists every setting independently")
    @MainActor
    func scopedTerminalAppearancePersistsIndependently() {
        let suite = "SelectiveRemote.TerminalUX0250Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let global = TerminalAppearanceStore(defaults: defaults)
        global.applyPreset(.dracula)
        global.font = .menlo
        global.fontSize = 18
        global.lineHeight = 1.30
        global.cursorStyle = .bar
        global.cursorBlink = false
        global.syntaxHighlighting = false
        global.syntaxScope = .currentLine
        global.syntaxFollowTheme = false
        global.syntaxHistoryOpacity = 0.65
        global.syntaxBoldCommands = false
        global.padding = 22

        let pane = TerminalAppearanceStore(
            defaults: defaults,
            storageNamespace: "pane.test",
            cloneGlobalIfMissing: true
        )
        #expect(pane.selectedPreset == .dracula)
        #expect(pane.font == .menlo)
        #expect(pane.fontSize == 18)
        #expect(pane.cursorStyle == .bar)
        #expect(pane.syntaxHighlighting == false)
        #expect(pane.padding == 22)

        pane.applyPreset(.hackerGreen)
        pane.font = .monaco
        pane.fontSize = 20
        pane.syntaxHighlighting = true
        pane.padding = 7

        #expect(global.selectedPreset == .dracula)
        #expect(global.font == .menlo)
        #expect(global.fontSize == 18)
        #expect(global.syntaxHighlighting == false)
        #expect(global.padding == 22)

        let restored = TerminalAppearanceStore(
            defaults: defaults,
            storageNamespace: "pane.test",
            cloneGlobalIfMissing: true
        )
        #expect(restored.selectedPreset == .hackerGreen)
        #expect(restored.font == .monaco)
        #expect(restored.fontSize == 20)
        #expect(restored.syntaxHighlighting == true)
        #expect(restored.padding == 7)
    }

    @Test("Local and SSH terminals reuse the complete appearance editor")
    func paneAppearanceUsesFullEditor() throws {
        let appearance = try source("Sources/SelectiveRemote/TerminalAppearance.swift")
        let local = try source("Sources/SelectiveRemote/LocalTerminalView.swift")
        let ssh = try source("Sources/SelectiveRemote/EmbeddedTerminalView.swift")
        let workspace = try source("Sources/SelectiveRemote/TerminalWorkspace.swift")

        #expect(appearance.contains("TerminalThemeSelector(store: store)"))
        #expect(appearance.contains("DisclosureGroup(\"Шрифт и курсор\")"))
        #expect(appearance.contains("DisclosureGroup(\"Подсветка синтаксиса\")"))
        #expect(appearance.contains("DisclosureGroup(\"Своя тема\")"))
        #expect(appearance.contains("Скопировать общее оформление"))
        #expect(local.contains("store: selectedTab.appearance"))
        #expect(ssh.contains("store: tab.appearance"))
        #expect(local.contains("let paneAppearance = tab.appearance.snapshot"))
        #expect(ssh.contains("let paneAppearance = tab.appearance.snapshot"))
        #expect(workspace.contains("storageNamespace: \"pane.\\(id.uuidString)\""))
    }
}
'''
)


# ---------------------------------------------------------------------------
# 5. Candidate metadata / release notes.
# ---------------------------------------------------------------------------
replace_once(
    "scripts/build_app.sh",
    'BUILD_NUMBER="134"',
    'BUILD_NUMBER="135"'
)

for path, replacements in {
    "CHANGELOG.md": [
        (
            "- Во время ручной проверки обновлений окно «Настройки» временно нельзя закрыть; возможность закрытия автоматически возвращается после завершения проверки.",
            "- Ручная проверка обновлений теперь полностью остаётся внутри окна «Настройки»: оно не закрывается и не теряет фокус из-за системного alert; состояние и результат проверки отображаются inline."
        ),
        (
            "- Добавлено индивидуальное цветовое оформление каждой локальной и SSH-панели терминала с возможностью оставить глобальную тему или выбрать отдельную палитру.",
            "- Каждая локальная и SSH-вкладка получила полные индивидуальные настройки терминала: весь каталог тем с тем же предпросмотром, шрифт, размер, межстрочный интервал, курсор, подсветка синтаксиса, отступы и своя палитра."
        ),
        (
            "- Индивидуальная палитра использует уже сохраняемый цвет панели, поэтому выбор восстанавливается вместе с Terminal Workspace.",
            "- Индивидуальные настройки сохраняются по стабильному UUID вкладки, восстанавливаются вместе с Terminal Workspace и могут в один клик скопировать текущее общее оформление."
        ),
    ],
    "CHANGELOG_EN.md": [
        (
            "- While a manual update check is running, the Settings window cannot be closed; closing is restored automatically when the check finishes.",
            "- Manual update checks now stay entirely inside Settings: the window no longer loses focus to a main-window alert, and progress/result are rendered inline."
        ),
        (
            "- Added per-pane terminal color styling for both local and SSH terminals, with either the shared global theme or an individual palette.",
            "- Every local and SSH tab now has complete individual terminal appearance settings: the full theme catalog with the same preview, font, size, line height, cursor, syntax highlighting, padding, and custom palette."
        ),
        (
            "- Per-pane palettes reuse the workspace's persisted pane color, so the choice is restored with the Terminal Workspace.",
            "- Individual appearance is persisted by the tab's stable UUID, restored with the Terminal Workspace, and can copy the current global terminal appearance in one click."
        ),
    ],
}.items():
    content = read(path)
    for old, new in replacements:
        if old not in content:
            raise RuntimeError(f"{path}: changelog text not found: {old}")
        content = content.replace(old, new, 1)
    rdp_line = (
        "- Исправлен fullscreen RDP на одном мониторе macOS: системная строка меню больше не резервирует скрытую вертикальную область, из-за которой панель задач Windows могла оказаться ниже видимого экрана."
        if path.endswith("CHANGELOG.md") and not path.endswith("CHANGELOG_EN.md")
        else "- Fixed single-monitor fullscreen RDP on macOS: the system menu bar no longer reserves hidden vertical space that could push the Windows taskbar below the visible desktop."
    )
    marker = "## 0.24.0"
    before, after = content.split(marker, 1)
    if rdp_line not in before:
        before = before.rstrip() + "\n" + rdp_line + "\n\n"
    write(path, before + marker + after)

print("v0.25.0 round-two patch applied")
