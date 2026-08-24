import AppKit
import SwiftUI

struct LocalTerminalView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var workspace: TerminalWorkspaceModel
    @ObservedObject var appearance: TerminalAppearanceStore
    @ObservedObject var appAppearance: AppAppearanceStore
    @ObservedObject private var snippetStore = TerminalCommandHistoryStore.shared
    @ObservedObject private var namedWorkspaceStore = TerminalNamedWorkspaceStore.shared

    let sshProfiles: [ConnectionProfile]
    let isFocusMode: Bool
    let connect: (TerminalWorkspaceTab) -> Void
    let toggleFocusMode: () -> Void
    let executeSnippet: (TerminalCommandTemplate) -> TerminalSnippetRunResult

    @State private var showsHistory = false
    @State private var showsSnippets = false
    @State private var showsAppearance = false
    @State private var showsPaneAppearance = false
    @State private var renameTabID: UUID?
    @State private var renameValue = ""
    @State private var showsNamedWorkspaces = false
    @State private var showsSnippetLibrary = false

    private var selectedTab: TerminalWorkspaceTab { workspace.selectedTab }

    private var inspectorMode: TerminalWorkspaceInspectorMode {
        showsSnippets ? .snippets : .history
    }

    private var inspectorVisible: Bool {
        showsHistory || showsSnippets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tabBar
            terminalWithInspector
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 320)
            Text(
                "Локальный терминал запускает login shell текущего пользователя внутри псевдотерминала. "
                    + "История хранится только на этом Mac; строки с признаками секретов не сохраняются."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Локальный терминал")
        .alert("Переименовать вкладку", isPresented: Binding(
            get: { renameTabID != nil },
            set: { if !$0 { renameTabID = nil } }
        )) {
            TextField("Название вкладки", text: $renameValue)
            Button("Отмена", role: .cancel) { renameTabID = nil }
            Button("Сохранить") {
                if let renameTabID { workspace.renameTab(renameTabID, to: renameValue) }
                renameTabID = nil
            }
        }
        .sheet(isPresented: $showsSnippetLibrary) {
            TerminalSnippetsLibraryView(store: snippetStore, model: model)
                .frame(minWidth: 980, minHeight: 680)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Терминал").font(.title2.bold())
                Text(selectedTab.connection.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            Button {
                restart(selectedTab)
            } label: {
                Image(systemName: selectedTab.session.isRunning ? "arrow.clockwise" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .help(selectedTab.session.isRunning ? "Перезапустить shell" : "Запустить shell")

            Button {
                showsSnippets = false
                showsHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("История команд")

            Button {
                showsHistory = false
                showsSnippets.toggle()
            } label: {
                Image(systemName: "curlybraces")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("Сниппеты: вставить, скопировать или выполнить")

            Button {
                chooseWorkingDirectory(for: selectedTab)
            } label: {
                Image(systemName: "folder")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .disabled(selectedTab.session.isRunning)
            .help("Выбрать рабочую папку")

            Button {
                selectedTab.session.clear()
            } label: {
                Image(systemName: "eraser")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("Очистить терминал")

            Button {
                showsPaneAppearance.toggle()
            } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("Индивидуальное оформление этой вкладки")
            .popover(isPresented: $showsPaneAppearance, arrowEdge: .bottom) {
                TerminalAppearanceView(
                    store: selectedTab.appearance,
                    appAppearance: appAppearance,
                    includesApplicationSettings: false,
                    individualTitle: selectedTab.title,
                    copyFrom: appearance
                )
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

            if isFocusMode {
                Button("Вернуть интерфейс", systemImage: "arrow.down.right.and.arrow.up.left") {
                    toggleFocusMode()
                }
                .buttonStyle(.borderedProminent)
                .help("Показать боковую панель и обычный интерфейс приложения")
            } else {
                Button("Развернуть терминал", systemImage: "arrow.up.left.and.arrow.down.right") {
                    toggleFocusMode()
                }
                .buttonStyle(.bordered)
                .help("Скрыть навигацию и отдать терминалу максимум места")
            }

            Menu {
                Button("Переименовать вкладку…", systemImage: "pencil") {
                    renameValue = selectedTab.title
                    renameTabID = selectedTab.id
                }
                Button("Выбрать рабочую папку…", systemImage: "folder") {
                    chooseWorkingDirectory(for: selectedTab)
                }
                .disabled(selectedTab.session.isRunning)
                Button("Очистить терминал", systemImage: "eraser") {
                    selectedTab.session.clear()
                }
                Divider()
                Button("Рабочие пространства", systemImage: "rectangle.3.group") {
                    showsNamedWorkspaces = true
                }
                Button("Управлять сниппетами", systemImage: "curlybraces") {
                    showsSnippetLibrary = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if selectedTab.session.isRunning {
                Button("Завершить", systemImage: "stop.fill", role: .destructive) {
                    selectedTab.session.stop()
                }
                .buttonStyle(.bordered)
            }
        }
        .terminalToolbarContainer()
    }

    private var tabBar: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.displayedTabs) { tab in
                        HStack(spacing: 5) {
                            Button {
                                workspace.selectedTabID = tab.id
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(tab.session.isRunning ? Color.green : Color.secondary)
                                        .frame(width: 8, height: 8)
                                    Text(tab.title).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            if !tab.isPrimary && !tab.isPinned {
                                Button {
                                    workspace.closeTab(tab.id)
                                } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            workspace.selectedTabID == tab.id
                                ? Color.accentColor.opacity(0.22)
                                : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            renameValue = tab.title
                            renameTabID = tab.id
                        })
                        .contextMenu {
                            Button("Переименовать", systemImage: "pencil") {
                                renameValue = tab.title
                                renameTabID = tab.id
                            }
                            Button(tab.isPinned ? "Открепить" : "Закрепить", systemImage: "pin") {
                                workspace.togglePinned(tab.id)
                            }
                            if !tab.isPrimary && !tab.isPinned {
                                Divider()
                                Button("Закрыть", systemImage: "xmark", role: .destructive) {
                                    workspace.closeTab(tab.id)
                                }
                            }
                        }
                    }
                }
            }
            Button {
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
    }

    private var terminalWithInspector: some View {
        HStack(spacing: 8) {
            terminalPane(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                TerminalWorkspaceInspector(
                    store: snippetStore,
                    mode: inspectorMode,
                    profileID: selectedTab.id,
                    terminalTitle: selectedTab.title,
                    sessionIsRunning: selectedTab.session.isRunning,
                    remoteContext: .empty,
                    selectMode: { mode in
                        showsHistory = mode == .history
                        showsSnippets = mode == .snippets
                    },
                    refreshRemoteContext: {},
                    close: {
                        showsHistory = false
                        showsSnippets = false
                    },
                    insert: { command in
                        replaceCurrentLine(command, run: false)
                    },
                    runHere: { command in
                        replaceCurrentLine(command, run: true)
                    },
                    runOnTargets: executeSnippet,
                    openSnippetLibrary: {
                        showsSnippetLibrary = true
                    }
                )
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.20), value: inspectorVisible)
    }

    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        let paneAppearance = tab.appearance.snapshot
        return EmbeddedTerminalWebView(
            session: tab.session,
            appearance: paneAppearance,
            historyContext: TerminalHistoryContext(
                profileID: tab.id,
                snippetTargets: sshProfiles.map {
                    TerminalSnippetTargetOption(
                        id: $0.id,
                        title: $0.friendlyName.isEmpty ? $0.host : $0.friendlyName,
                        subtitle: $0.host
                    )
                }
            ),
            remoteContext: .empty,
            snippetRevision: snippetStore.snippetRevision,
            onRemoteContextRetry: {},
            onFocus: { workspace.selectedTabID = tab.id },
            onInput: { tab.session.sendInput($0) },
            onTabNavigation: { navigateTabs($0) },
            onSmartLink: { link in open(link) },
            onSnippetRun: executeSnippet,
            historyVisible: Binding(
                get: { false },
                set: { visible in
                    guard workspace.selectedTabID == tab.id else { return }
                    showsHistory = visible
                    if visible { showsSnippets = false }
                }
            ),
            snippetsVisible: Binding(
                get: { false },
                set: { visible in
                    guard workspace.selectedTabID == tab.id else { return }
                    showsSnippets = visible
                    if visible { showsHistory = false }
                }
            )
        )
        .id(tab.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalColorCodecView.color(paneAppearance.theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor.opacity(0.72), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .overlay {
            if !tab.session.isRunning {
                VStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Локальный shell остановлен").font(.headline)
                    Text(tab.connection.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button("Запустить", systemImage: "play.fill") { connect(tab) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func replaceCurrentLine(_ command: String, run: Bool) {
        let normalized = command.trimmingCharacters(in: .newlines)
        guard !normalized.isEmpty,
              !normalized.contains("\0"),
              selectedTab.session.isRunning
        else { return }
        let suffix = run ? "\r" : ""
        selectedTab.session.sendInput(Data(("\u{15}\(normalized)\(suffix)").utf8))
    }

    private func addTab() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let tab = workspace.addTab(
            connection: .local(workingDirectory: home),
            title: "Terminal \(workspace.displayedTabs.count + 1)"
        ) else { return }
        connect(tab)
    }

    private func restart(_ tab: TerminalWorkspaceTab) {
        guard tab.session.isRunning else {
            connect(tab)
            return
        }
        tab.session.stop()
        Task { @MainActor in
            for _ in 0..<50 where tab.session.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let current = workspace.tabs.first(where: { $0.id == tab.id }),
               !current.session.isRunning {
                connect(current)
            }
        }
    }

    private func chooseWorkingDirectory(for tab: TerminalWorkspaceTab) {
        let panel = NSOpenPanel()
        panel.title = "Рабочая папка локального терминала"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: tab.connection.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = workspace.updateConnection(
            tabID: tab.id,
            connection: .local(workingDirectory: url.path),
            suggestedTitle: tab.title
        )
    }

    private func navigateTabs(_ token: Int) {
        let tabs = workspace.displayedTabs
        guard !tabs.isEmpty else { return }
        if token >= 0 {
            if token < tabs.count { workspace.selectedTabID = tabs[token].id }
            return
        }
        let current = tabs.firstIndex(where: { $0.id == workspace.selectedTabID }) ?? 0
        let delta = token == -2 ? -1 : 1
        workspace.selectedTabID = tabs[(current + delta + tabs.count) % tabs.count].id
    }

    private func open(_ link: TerminalSmartLink) {
        switch link.kind {
        case .url:
            if let url = URL(string: link.value),
               let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
        case .path:
            let path = (link.value as NSString).expandingTildeInPath
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .host:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.value, forType: .string)
        }
    }
}
