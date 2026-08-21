#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def write(path, text):
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_once(path, old, new):
    text = read(path)
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:160]!r}")
    write(path, text.replace(old, new, 1))


# --- Full per-pane appearance snapshot for named workspaces ---
replace_once(
    "Sources/SelectiveRemote/TerminalAppearance.swift",
    '''struct TerminalAppearanceSnapshot: Codable, Equatable, Sendable {
    let fontFamily: String
    let fontSize: Double
    let lineHeight: Double
    let cursorStyle: String
    let cursorBlink: Bool
    let syntaxHighlighting: Bool
    let syntaxScope: String
    let syntaxHistoryOpacity: Double
    let syntaxBoldCommands: Bool
    let syntaxPalette: TerminalSyntaxPalette
    let padding: Double
    let theme: TerminalPalette
}
''',
    '''struct TerminalAppearanceSnapshot: Codable, Equatable, Sendable {
    let fontFamily: String
    let fontSize: Double
    let lineHeight: Double
    let cursorStyle: String
    let cursorBlink: Bool
    let syntaxHighlighting: Bool
    let syntaxScope: String
    let syntaxHistoryOpacity: Double
    let syntaxBoldCommands: Bool
    let syntaxPalette: TerminalSyntaxPalette
    let padding: Double
    let theme: TerminalPalette
}

struct TerminalAppearanceWorkspaceSnapshot: Codable, Equatable, Sendable {
    let selectedPreset: String
    let palette: TerminalPalette
    let customPalette: TerminalPalette
    let font: String
    let fontSize: Double
    let lineHeight: Double
    let cursorStyle: String
    let cursorBlink: Bool
    let syntaxHighlighting: Bool
    let syntaxScope: String
    let syntaxFollowTheme: Bool
    let syntaxHistoryOpacity: Double
    let syntaxBoldCommands: Bool
    let syntaxCustomPalette: TerminalSyntaxPalette
    let padding: Double
}
'''
)

replace_once(
    "Sources/SelectiveRemote/TerminalAppearance.swift",
    '''    var customThemePalette: TerminalPalette { customPalette }

    var effectiveSyntaxPalette: TerminalSyntaxPalette {''',
    '''    var workspaceSnapshot: TerminalAppearanceWorkspaceSnapshot {
        TerminalAppearanceWorkspaceSnapshot(
            selectedPreset: selectedPreset.rawValue,
            palette: palette,
            customPalette: customPalette,
            font: font.rawValue,
            fontSize: clampedFontSize,
            lineHeight: clampedLineHeight,
            cursorStyle: cursorStyle.rawValue,
            cursorBlink: cursorBlink,
            syntaxHighlighting: syntaxHighlighting,
            syntaxScope: syntaxScope.rawValue,
            syntaxFollowTheme: syntaxFollowTheme,
            syntaxHistoryOpacity: clampedSyntaxHistoryOpacity,
            syntaxBoldCommands: syntaxBoldCommands,
            syntaxCustomPalette: syntaxCustomPalette,
            padding: clampedPadding
        )
    }

    func applyWorkspaceSnapshot(_ snapshot: TerminalAppearanceWorkspaceSnapshot) {
        selectedPreset = TerminalThemePreset(rawValue: snapshot.selectedPreset) ?? .custom
        palette = snapshot.palette
        customPalette = snapshot.customPalette
        font = TerminalFontChoice(rawValue: snapshot.font) ?? .sfMono
        fontSize = min(max(snapshot.fontSize, 10), 28)
        lineHeight = min(max(snapshot.lineHeight, 1.0), 1.6)
        cursorStyle = TerminalCursorStyle(rawValue: snapshot.cursorStyle) ?? .block
        cursorBlink = snapshot.cursorBlink
        syntaxHighlighting = snapshot.syntaxHighlighting
        syntaxScope = TerminalSyntaxScope(rawValue: snapshot.syntaxScope) ?? .visibleCommands
        syntaxFollowTheme = snapshot.syntaxFollowTheme
        syntaxHistoryOpacity = min(max(snapshot.syntaxHistoryOpacity, 0.45), 1.0)
        syntaxBoldCommands = snapshot.syntaxBoldCommands
        syntaxCustomPalette = snapshot.syntaxCustomPalette
        padding = min(max(snapshot.padding, 0), 28)
        saveCustomPalette()
        saveSyntaxPalette()
        savePresetAndPalette()
    }

    var customThemePalette: TerminalPalette { customPalette }

    var effectiveSyntaxPalette: TerminalSyntaxPalette {'''
)

# --- Serializable workspace snapshot + safe disconnected restoration ---
replace_once(
    "Sources/SelectiveRemote/TerminalWorkspace.swift",
    '''private struct StoredTerminalWorkspace: Codable {
    struct Tab: Codable {
        let id: UUID
        var title: String
        let isPrimary: Bool
        var connection: TerminalTabConnection?
        var isPinned: Bool?
        var colorIndex: Int?
    }

    var tabs: [Tab]
    var selectedTabID: UUID?
    var secondaryTabID: UUID?
    var layout: TerminalWorkspaceLayout
}
''',
    '''private struct StoredTerminalWorkspace: Codable {
    struct Tab: Codable {
        let id: UUID
        var title: String
        let isPrimary: Bool
        var connection: TerminalTabConnection?
        var isPinned: Bool?
        var colorIndex: Int?
    }

    var tabs: [Tab]
    var selectedTabID: UUID?
    var secondaryTabID: UUID?
    var layout: TerminalWorkspaceLayout
}

struct TerminalWorkspaceSnapshot: Codable, Equatable, Sendable {
    struct Tab: Codable, Equatable, Sendable {
        let id: UUID
        var title: String
        var isPrimary: Bool
        var connection: TerminalTabConnection
        var isPinned: Bool
        var colorIndex: Int
        var appearance: TerminalAppearanceWorkspaceSnapshot
    }

    var tabs: [Tab]
    var selectedTabID: UUID?
    var secondaryTabID: UUID?
    var layout: TerminalWorkspaceLayout
}
'''
)

replace_once(
    "Sources/SelectiveRemote/TerminalWorkspace.swift",
    '''    func selectSecondary(_ id: UUID?) {
        guard let id,
              id != selectedTabID,
              tabs.contains(where: { $0.id == id })
        else {
            secondaryTabID = nil
            return
        }
        secondaryTabID = id
    }

    func stopAll() {''',
    '''    func selectSecondary(_ id: UUID?) {
        guard let id,
              id != selectedTabID,
              tabs.contains(where: { $0.id == id })
        else {
            secondaryTabID = nil
            return
        }
        secondaryTabID = id
    }

    func workspaceSnapshot() -> TerminalWorkspaceSnapshot {
        TerminalWorkspaceSnapshot(
            tabs: tabs.map { tab in
                TerminalWorkspaceSnapshot.Tab(
                    id: tab.id,
                    title: tab.title,
                    isPrimary: tab.isPrimary,
                    connection: tab.connection,
                    isPinned: tab.isPinned,
                    colorIndex: tab.colorIndex,
                    appearance: tab.appearance.workspaceSnapshot
                )
            },
            selectedTabID: selectedTabID,
            secondaryTabID: secondaryTabID,
            layout: layout
        )
    }

    @discardableResult
    func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) -> Bool {
        guard !hasRunningSession else { return false }
        var metadata = Array(snapshot.tabs.prefix(8))
        guard !metadata.isEmpty else { return false }

        var seen = Set<UUID>()
        metadata = metadata.filter { seen.insert($0.id).inserted }
        guard !metadata.isEmpty else { return false }
        let primaryIndex = metadata.firstIndex(where: { $0.isPrimary }) ?? 0
        for index in metadata.indices {
            metadata[index].isPrimary = index == primaryIndex
        }

        let reusablePrimarySession = tabs.first(where: { $0.isPrimary })?.session
            ?? tabs.first?.session
            ?? TerminalSessionModel()

        isRestoring = true
        sessionObservers.removeAll()
        sessionPhaseObservers.removeAll()
        appearanceObservers.removeAll()
        remoteContexts.removeAll()

        var restored: [TerminalWorkspaceTab] = []
        for (index, item) in metadata.enumerated() {
            let tab = TerminalWorkspaceTab(
                id: item.id,
                title: Self.normalizedTitle(item.title, fallback: "Терминал \(index + 1)"),
                session: item.isPrimary ? reusablePrimarySession : TerminalSessionModel(),
                isPrimary: item.isPrimary,
                connection: item.connection,
                isPinned: item.isPinned,
                colorIndex: item.colorIndex,
                appearanceDefaults: defaults
            )
            tab.appearance.applyWorkspaceSnapshot(item.appearance)
            restored.append(tab)
        }

        tabs = restored
        selectedTabID = snapshot.selectedTabID.flatMap { id in
            restored.contains(where: { $0.id == id }) ? id : nil
        } ?? restored[0].id
        secondaryTabID = snapshot.secondaryTabID.flatMap { id in
            restored.contains(where: { $0.id == id && $0.id != selectedTabID }) ? id : nil
        }
        layout = snapshot.layout
        observeSessions()
        isRestoring = false
        normalizeSelectionAndPersist()
        objectWillChange.send()
        return true
    }

    func stopAll() {'''
)

# --- Named workspace store and shared picker UI ---
smart_path = "Sources/SelectiveRemote/SmartTerminalFeatures.swift"
smart = read(smart_path)
smart += r'''

struct NamedTerminalWorkspace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let scopeID: UUID
    var name: String
    var snapshot: TerminalWorkspaceSnapshot
    let createdAt: Date
    var updatedAt: Date
}

@MainActor
final class TerminalNamedWorkspaceStore: ObservableObject {
    static let shared = TerminalNamedWorkspaceStore()

    @Published private(set) var workspaces: [NamedTerminalWorkspace]
    private let defaults: UserDefaults
    private let key = "SelectiveRemote.terminal.namedWorkspaces.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([NamedTerminalWorkspace].self, from: data) {
            workspaces = decoded
        } else {
            workspaces = []
        }
    }

    func workspaces(for scopeID: UUID) -> [NamedTerminalWorkspace] {
        workspaces
            .filter { $0.scopeID == scopeID }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    func save(
        name rawName: String,
        scopeID: UUID,
        snapshot: TerminalWorkspaceSnapshot,
        now: Date = Date()
    ) -> NamedTerminalWorkspace? {
        guard let name = normalizedName(rawName), !snapshot.tabs.isEmpty else { return nil }
        if let index = workspaces.firstIndex(where: {
            $0.scopeID == scopeID && sameName($0.name, name)
        }) {
            workspaces[index].name = name
            workspaces[index].snapshot = snapshot
            workspaces[index].updatedAt = now
            persist()
            return workspaces[index]
        }
        let entry = NamedTerminalWorkspace(
            id: UUID(),
            scopeID: scopeID,
            name: name,
            snapshot: snapshot,
            createdAt: now,
            updatedAt: now
        )
        workspaces.append(entry)
        persist()
        return entry
    }

    func remove(id: UUID) {
        let previous = workspaces.count
        workspaces.removeAll { $0.id == id }
        if workspaces.count != previous { persist() }
    }

    private func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }

    private func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(data, forKey: key)
    }
}

struct TerminalNamedWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TerminalNamedWorkspaceStore
    @ObservedObject var workspace: TerminalWorkspaceModel
    @State private var name = ""
    @State private var feedback: String?

    private var entries: [NamedTerminalWorkspace] {
        store.workspaces(for: workspace.profileID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Рабочие пространства")
                        .font(.title3.weight(.semibold))
                    Text("Сохраняют вкладки, компоновку, подключения и оформление")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("Например, Production", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("Сохранить текущее", systemImage: "square.and.arrow.down") {
                    guard store.save(
                        name: name,
                        scopeID: workspace.profileID,
                        snapshot: workspace.workspaceSnapshot()
                    ) != nil else {
                        feedback = "Введите название рабочего пространства"
                        return
                    }
                    feedback = "Рабочее пространство сохранено"
                    name = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if workspace.hasRunningSession {
                Label(
                    "Для загрузки другого Workspace сначала отключите активные терминалы. Сохранение текущего состояния доступно.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "Загрузка восстанавливает структуру, но никогда не подключается к серверам автоматически.",
                    systemImage: "shield.checkered"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Нет сохранённых Workspaces",
                    systemImage: "rectangle.3.group",
                    description: Text("Соберите нужные вкладки и панели, затем сохраните текущее состояние.")
                )
                .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            workspaceRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 330)
            }

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func workspaceRow(_ entry: NamedTerminalWorkspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.snapshot.layout.systemImage)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(entry.snapshot.tabs.count) вкладок · \(entry.snapshot.layout.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Загрузить") {
                if workspace.restoreWorkspaceSnapshot(entry.snapshot) {
                    feedback = "Workspace «\(entry.name)» загружен"
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace.hasRunningSession)
            Button(role: .destructive) {
                store.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Удалить Workspace")
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
'''
write(smart_path, smart)

# --- SSH workspace button in the terminal tab bar ---
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''    @ObservedObject var snippetStore = TerminalCommandHistoryStore.shared
    let workspaceTitle: String''',
    '''    @ObservedObject var snippetStore = TerminalCommandHistoryStore.shared
    @ObservedObject private var namedWorkspaceStore = TerminalNamedWorkspaceStore.shared
    let workspaceTitle: String'''
)
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''    @State private var showsCommandPalette = false

    private var session:''',
    '''    @State private var showsCommandPalette = false
    @State private var showsNamedWorkspaces = false

    private var session:'''
)
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''            Button {
                showsLayoutPicker.toggle()
            } label: {
                Image(systemName: workspace.layout.systemImage)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Компоновка терминалов")
            .popover(isPresented: $showsLayoutPicker, arrowEdge: .bottom) {
                terminalLayoutPicker
            }''',
    '''            Button {
                showsNamedWorkspaces.toggle()
            } label: {
                Image(systemName: "rectangle.3.group")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Именованные рабочие пространства")
            .popover(isPresented: $showsNamedWorkspaces, arrowEdge: .bottom) {
                TerminalNamedWorkspaceView(
                    store: namedWorkspaceStore,
                    workspace: workspace
                )
            }

            Button {
                showsLayoutPicker.toggle()
            } label: {
                Image(systemName: workspace.layout.systemImage)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Компоновка терминалов")
            .popover(isPresented: $showsLayoutPicker, arrowEdge: .bottom) {
                terminalLayoutPicker
            }'''
)

# Also expose Workspaces from the command palette for keyboard-oriented users.
replace_once(
    "Sources/SelectiveRemote/EmbeddedTerminalView.swift",
    '''            Button("Команды сервера", systemImage: "server.rack") {
                showsCommandPalette = false
                showsServerCommands = true
                if workspace.remoteContext(for: workspace.selectedTabID)?.refreshedAt == nil {
                    refreshRemoteContext()
                }
            }
            .disabled(!workspace.selectedTab.session.isRunning)
            Button(
                broadcastsInput ?''',
    '''            Button("Команды сервера", systemImage: "server.rack") {
                showsCommandPalette = false
                showsServerCommands = true
                if workspace.remoteContext(for: workspace.selectedTabID)?.refreshedAt == nil {
                    refreshRemoteContext()
                }
            }
            .disabled(!workspace.selectedTab.session.isRunning)
            Button("Рабочие пространства", systemImage: "rectangle.3.group") {
                showsCommandPalette = false
                showsNamedWorkspaces = true
            }
            Button(
                broadcastsInput ?'''
)

# --- Local Terminal gets the same named-workspace capability ---
replace_once(
    "Sources/SelectiveRemote/LocalTerminalView.swift",
    '''    @ObservedObject private var snippetStore = TerminalCommandHistoryStore.shared

    let sshProfiles:''',
    '''    @ObservedObject private var snippetStore = TerminalCommandHistoryStore.shared
    @ObservedObject private var namedWorkspaceStore = TerminalNamedWorkspaceStore.shared

    let sshProfiles:'''
)
replace_once(
    "Sources/SelectiveRemote/LocalTerminalView.swift",
    '''    @State private var renameValue = ""

    private var selectedTab:''',
    '''    @State private var renameValue = ""
    @State private var showsNamedWorkspaces = false

    private var selectedTab:'''
)
replace_once(
    "Sources/SelectiveRemote/LocalTerminalView.swift",
    '''            Button {
                addTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(workspace.displayedTabs.count >= 8)
            .help("Новая локальная вкладка")
        }
    }''',
    '''            Button {
                addTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(workspace.displayedTabs.count >= 8)
            .help("Новая локальная вкладка")

            Button {
                showsNamedWorkspaces.toggle()
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .buttonStyle(.bordered)
            .help("Именованные рабочие пространства")
            .popover(isPresented: $showsNamedWorkspaces, arrowEdge: .bottom) {
                TerminalNamedWorkspaceView(
                    store: namedWorkspaceStore,
                    workspace: workspace
                )
            }
        }
    }'''
)

# --- Regression coverage ---
test_path = "Tests/SelectiveRemoteTests/TerminalProductivity0260Tests.swift"
tests = read(test_path)
tests += r'''

@Test("Named Workspace store persists and updates the same name")
@MainActor
func namedWorkspaceStorePersists() throws {
    let suite = "SelectiveRemoteTests.NamedWorkspace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let scope = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: scope,
        primarySession: TerminalSessionModel(),
        primaryConnection: .custom(host: "one.example", username: "root"),
        defaults: defaults
    )
    let snapshot = workspace.workspaceSnapshot()
    let store = TerminalNamedWorkspaceStore(defaults: defaults)
    let first = try #require(store.save(name: "Production", scopeID: scope, snapshot: snapshot))
    #expect(store.workspaces(for: scope).count == 1)

    workspace.renameTab(workspace.selectedTabID, to: "Primary")
    let updated = try #require(store.save(name: "production", scopeID: scope, snapshot: workspace.workspaceSnapshot()))
    #expect(updated.id == first.id)
    #expect(store.workspaces(for: scope).count == 1)

    let reloaded = TerminalNamedWorkspaceStore(defaults: defaults)
    #expect(reloaded.workspaces(for: scope).first?.snapshot.tabs.first?.title == "Primary")
}

@Test("Named Workspace restores layout, connections and full pane appearance without connecting")
@MainActor
func namedWorkspaceRestoresSafely() throws {
    let suite = "SelectiveRemoteTests.NamedWorkspaceRestore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let scope = UUID()
    let firstProfile = UUID()
    let secondProfile = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: scope,
        primarySession: TerminalSessionModel(),
        primaryConnection: .savedProfile(firstProfile),
        defaults: defaults
    )
    workspace.renameTab(workspace.selectedTabID, to: "API")
    let firstID = workspace.selectedTabID
    let second = try #require(workspace.addTab(
        connection: .savedProfile(secondProfile),
        title: "Database"
    ))
    workspace.setLayout(.splitHorizontal)
    workspace.selectedTabID = firstID
    workspace.selectSecondary(second.id)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.applyPreset(.dracula)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.fontSize = 18
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.syntaxFollowTheme = false

    let snapshot = workspace.workspaceSnapshot()
    workspace.renameTab(firstID, to: "Changed")
    workspace.setLayout(.single)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.applyPreset(.hackerGreen)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.fontSize = 12

    #expect(workspace.restoreWorkspaceSnapshot(snapshot))
    #expect(!workspace.hasRunningSession)
    #expect(workspace.tabs.count == 2)
    #expect(workspace.layout == .splitHorizontal)
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.title == "API")
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.connection == .savedProfile(firstProfile))
    #expect(workspace.tabs.first(where: { $0.id == second.id })?.connection == .savedProfile(secondProfile))
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.appearance.selectedPreset == .dracula)
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.appearance.fontSize == 18)
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.appearance.syntaxFollowTheme == false)
}

@Test("Named Workspaces are exposed in SSH and Local Terminal and never auto-connect on restore")
func namedWorkspaceSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let ssh = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift"),
        encoding: .utf8
    )
    let local = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/LocalTerminalView.swift"),
        encoding: .utf8
    )
    let workspace = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalWorkspace.swift"),
        encoding: .utf8
    )
    #expect(ssh.contains("TerminalNamedWorkspaceView"))
    #expect(local.contains("TerminalNamedWorkspaceView"))
    #expect(workspace.contains("guard !hasRunningSession else { return false }"))
    #expect(workspace.contains("restoreWorkspaceSnapshot"))
}
'''
write(test_path, tests)

print("v0.26.0 phase 3 named workspaces patch applied")
