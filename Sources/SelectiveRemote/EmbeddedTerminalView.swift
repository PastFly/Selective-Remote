import Foundation
import SwiftUI
@preconcurrency import WebKit

private enum TerminalResourceLocator {
    static var directoryURL: URL? {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TerminalResources", isDirectory: true)
        let bundledDirectory = Bundle.main.resourceURL?
            .appendingPathComponent("TerminalResources", isDirectory: true)
        return [bundledDirectory, Optional(sourceDirectory)]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct EmbeddedTerminalWebView: NSViewRepresentable {
    @ObservedObject var session: TerminalSessionModel
    let appearance: TerminalAppearanceSnapshot
    let historyContext: TerminalHistoryContext?
    let remoteContext: TerminalRemoteContextSnapshot
    let onFocus: () -> Void
    let onInput: (Data) -> Void
    @Binding var historyVisible: Bool

    init(
        session: TerminalSessionModel,
        appearance: TerminalAppearanceSnapshot,
        historyContext: TerminalHistoryContext? = nil,
        remoteContext: TerminalRemoteContextSnapshot = .empty,
        onFocus: @escaping () -> Void = {},
        onInput: ((Data) -> Void)? = nil,
        historyVisible: Binding<Bool> = .constant(false)
    ) {
        self.session = session
        self.appearance = appearance
        self.historyContext = historyContext
        self.remoteContext = remoteContext
        self.onFocus = onFocus
        self.onInput = onInput ?? { _ in }
        _historyVisible = historyVisible
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            appearance: appearance,
            historyContext: historyContext,
            remoteContext: remoteContext,
            onFocus: onFocus,
            onInput: onInput,
            historyVisible: _historyVisible
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.inputMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.resizeMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.historyMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.focusMessageName
        )

        let webView = TerminalWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(to: webView)
        webView.layoutHandler = { [weak coordinator = context.coordinator] in
            coordinator?.requestFit()
        }

        if let directory = TerminalResourceLocator.directoryURL {
            let page = directory.appendingPathComponent("terminal.html")
            webView.loadFileURL(page, allowingReadAccessTo: directory)
        } else {
            webView.loadHTMLString(
                """
                <html><body style="background:#10131a;color:#ff8787;font:14px -apple-system;
                padding:20px">Ресурсы встроенного терминала не найдены. Пересоберите приложение
                через scripts/build_app.sh.</body></html>
                """,
                baseURL: nil
            )
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateHistoryContext(historyContext)
        context.coordinator.updateRemoteContext(remoteContext)
        context.coordinator.updateFocusHandler(onFocus)
        context.coordinator.updateInputHandler(onInput)
        context.coordinator.updateSession(session)
        context.coordinator.updateAppearance(appearance)
        context.coordinator.updateHistoryVisibility(historyVisible)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        (webView as? TerminalWKWebView)?.layoutHandler = nil
        coordinator.detach()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.inputMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.resizeMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.historyMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.focusMessageName
        )
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let inputMessageName = "terminalInput"
        static let resizeMessageName = "terminalResize"
        static let historyMessageName = "terminalHistory"
        static let focusMessageName = "terminalFocus"

        private weak var session: TerminalSessionModel?
        private weak var webView: WKWebView?
        private var observerID: UUID?
        private var appearance: TerminalAppearanceSnapshot
        private var historyContext: TerminalHistoryContext?
        private var remoteContext: TerminalRemoteContextSnapshot
        private var onFocus: () -> Void
        private var onInput: (Data) -> Void
        private var historyVisible: Binding<Bool>
        private var appliedHistoryVisibility: Bool?
        private var pageReady = false
        private var pendingBase64: [String] = []
        private var writeInFlight = false
        private var navigationGeneration = 0

        init(
            session: TerminalSessionModel,
            appearance: TerminalAppearanceSnapshot,
            historyContext: TerminalHistoryContext?,
            remoteContext: TerminalRemoteContextSnapshot,
            onFocus: @escaping () -> Void,
            onInput: @escaping (Data) -> Void,
            historyVisible: Binding<Bool>
        ) {
            self.session = session
            self.appearance = appearance
            self.historyContext = historyContext
            self.remoteContext = remoteContext
            self.onFocus = onFocus
            self.onInput = onInput
            self.historyVisible = historyVisible
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            observeSession()
        }

        func updateSession(_ updated: TerminalSessionModel) {
            guard session !== updated else { return }
            detachObserver()
            session = updated
            pageReady = false
            writeInFlight = false
            pendingBase64.removeAll(keepingCapacity: true)
            observeSession()
            webView?.reload()
        }

        func updateAppearance(_ updated: TerminalAppearanceSnapshot) {
            guard appearance != updated else { return }
            appearance = updated
            applyAppearance()
        }

        func updateHistoryContext(_ updated: TerminalHistoryContext?) {
            guard historyContext != updated else { return }
            historyContext = updated
            refreshHistory()
        }

        func updateRemoteContext(_ updated: TerminalRemoteContextSnapshot) {
            guard remoteContext != updated else { return }
            remoteContext = updated
            refreshHistory()
        }

        func updateFocusHandler(_ updated: @escaping () -> Void) {
            onFocus = updated
        }

        func updateInputHandler(_ updated: @escaping (Data) -> Void) {
            onInput = updated
        }

        func updateHistoryVisibility(_ visible: Bool) {
            guard pageReady else {
                appliedHistoryVisibility = nil
                return
            }
            guard appliedHistoryVisibility != visible else { return }
            appliedHistoryVisibility = visible
            webView?.evaluateJavaScript(
                "window.selectiveTerminalSetHistoryVisible?.(\(visible ? "true" : "false"))"
            )
        }

        func detach() {
            detachObserver()
            webView = nil
            pageReady = false
            writeInFlight = false
            pendingBase64.removeAll()
            appliedHistoryVisibility = nil
        }

        func requestFit() {
            guard pageReady else { return }
            webView?.evaluateJavaScript("window.selectiveTerminalFit?.()")
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case Self.inputMessageName:
                guard let value = message.body as? String else { return }
                onInput(Data(value.utf8))
            case Self.resizeMessageName:
                guard let value = message.body as? [String: Any],
                      let columns = (value["columns"] as? NSNumber)?.intValue,
                      let rows = (value["rows"] as? NSNumber)?.intValue
                else { return }
                session?.resize(columns: columns, rows: rows)
            case Self.historyMessageName:
                handleHistoryMessage(message.body)
            case Self.focusMessageName:
                onFocus()
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            applyAppearance()
            requestFit()
            drainOutputQueue()
            refreshHistory()
            updateHistoryVisibility(historyVisible.wrappedValue)
            webView.evaluateJavaScript("window.selectiveTerminalFocus?.()")
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            // Reloading the internal WebView must not require reconnecting SSH.
            // Reattach the observer so TerminalSessionModel replays its retained
            // ANSI stream into the new xterm.js page after navigation finishes.
            navigationGeneration += 1
            pageReady = false
            writeInFlight = false
            appliedHistoryVisibility = nil
            pendingBase64.removeAll(keepingCapacity: true)
            detachObserver()
            observeSession()
        }

        private func observeSession() {
            guard let session else { return }
            observerID = session.addOutputObserver { [weak self] data in
                self?.write(data)
            }
        }

        private func detachObserver() {
            if let observerID {
                session?.removeOutputObserver(observerID)
            }
            observerID = nil
        }

        private func write(_ data: Data) {
            // A replay buffer can be several megabytes. Keeping chunks modest
            // prevents one giant evaluateJavaScript call and preserves the
            // exact ordering of ANSI/VT control sequences used by nano, vim
            // and tmux.
            let maximumChunkBytes = 48 * 1_024
            var offset = 0
            while offset < data.count {
                let end = min(offset + maximumChunkBytes, data.count)
                pendingBase64.append(
                    data.subdata(in: offset..<end).base64EncodedString()
                )
                offset = end
            }
            drainOutputQueue()
        }

        private func drainOutputQueue() {
            guard pageReady,
                  !writeInFlight,
                  !pendingBase64.isEmpty,
                  let webView
            else { return }

            let base64 = pendingBase64.removeFirst()
            let generation = navigationGeneration
            writeInFlight = true
            webView.evaluateJavaScript(
                "window.selectiveTerminalWriteBase64?.('\(base64)')"
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.navigationGeneration == generation
                    else { return }
                    self.writeInFlight = false
                    self.drainOutputQueue()
                }
            }
        }

        private func applyAppearance() {
            guard pageReady,
                  let data = try? JSONEncoder().encode(appearance),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript(
                "window.selectiveTerminalApplySettings?.(\(json))"
            )
        }

        private func handleHistoryMessage(_ body: Any) {
            guard let context = historyContext,
                  let payload = body as? [String: Any],
                  let action = payload["action"] as? String
            else { return }

            let store = TerminalCommandHistoryStore.shared
            switch action {
            case "record":
                guard let command = payload["command"] as? String else { return }
                _ = store.record(command: command, profileID: context.profileID)
                refreshHistory()
            case "remove":
                guard let value = payload["id"] as? String,
                      let id = UUID(uuidString: value)
                else { return }
                store.remove(entryID: id, profileID: context.profileID)
                refreshHistory()
            case "clear":
                store.clear(profileID: context.profileID)
                refreshHistory()
            case "setEnabled":
                guard let enabled = (payload["enabled"] as? NSNumber)?.boolValue
                else { return }
                store.isEnabled = enabled
                refreshHistory()
            case "toggleFavorite":
                guard let command = payload["command"] as? String else { return }
                _ = store.toggleFavorite(command: command, profileID: context.profileID)
                refreshHistory()
            case "saveTemplate":
                let id = (payload["id"] as? String).flatMap(UUID.init(uuidString:))
                guard let title = payload["title"] as? String,
                      let command = payload["command"] as? String
                else { return }
                let category = payload["category"] as? String ?? "Мои команды"
                _ = store.saveTemplate(
                    id: id,
                    title: title,
                    command: command,
                    category: category,
                    profileID: context.profileID
                )
                refreshHistory()
            case "removeTemplate":
                guard let value = payload["id"] as? String,
                      let id = UUID(uuidString: value)
                else { return }
                store.removeTemplate(id: id, profileID: context.profileID)
                refreshHistory()
            case "visibility":
                guard let visible = (payload["visible"] as? NSNumber)?.boolValue
                else { return }
                appliedHistoryVisibility = visible
                historyVisible.wrappedValue = visible
            default:
                break
            }
        }

        private func refreshHistory() {
            guard pageReady,
                  let context = historyContext,
                  let json = TerminalCommandHistoryStore.shared.webPayload(
                      for: context.profileID,
                      remote: remoteContext
                  )
            else { return }
            webView?.evaluateJavaScript(
                "window.selectiveTerminalSetHistory?.(\(json))"
            )
        }
    }
}

private final class TerminalWKWebView: WKWebView {
    var layoutHandler: (() -> Void)?

    override func layout() {
        super.layout()
        layoutHandler?()
    }
}

struct SSHTerminalView: View {
    @ObservedObject var workspace: TerminalWorkspaceModel
    @ObservedObject var appearance: TerminalAppearanceStore
    @ObservedObject var appAppearance: AppAppearanceStore
    let workspaceTitle: String
    let defaultProfileID: UUID?
    let locksPrimaryConnection: Bool
    let sshProfiles: [ConnectionProfile]
    let hasInstallableKey: Bool
    let isFocusMode: Bool
    let connect: (TerminalWorkspaceTab) -> Void
    let installKey: () -> Void
    let toggleFocusMode: () -> Void
    let openSFTP: (TerminalWorkspaceTab) -> Void
    let discoverContext: (TerminalWorkspaceTab) async throws -> TerminalRemoteContextSnapshot

    @State private var showsAppearance = false
    @State private var showsHistory = false
    @State private var remoteContexts: [UUID: TerminalRemoteContextSnapshot] = [:]
    @State private var refreshingContextTabIDs: Set<UUID> = []
    @State private var renameTabID: UUID?
    @State private var renameValue = ""
    @State private var connectionEditorRequest: TerminalConnectionEditorRequest?
    @State private var showsLayoutPicker = false
    @State private var broadcastsInput = false
    @State private var showsBroadcastConfirmation = false
    @State private var showsCommandPalette = false

    private var session: TerminalSessionModel { workspace.selectedTab.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Встроенный SSH-терминал", systemImage: "terminal.fill")
                        .font(.headline)
                    Text(
                        "\(connectionLabel(for: workspace.selectedTab)) · "
                            + "\(session.phase.title) · "
                            + "\(session.terminalColumns)×\(session.terminalRows)"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    connectionEditorRequest = TerminalConnectionEditorRequest(
                        tabID: workspace.selectedTab.id,
                        initialConnection: workspace.selectedTab.connection
                    )
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(
                    session.isRunning
                        || (workspace.selectedTab.isPrimary && locksPrimaryConnection)
                )
                .help("Выбрать другой сервер для этой вкладки")
                .accessibilityLabel("Изменить подключение вкладки")

                Button {
                    refreshRemoteContext()
                } label: {
                    if refreshingContextTabIDs.contains(workspace.selectedTabID) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "server.rack")
                    }
                }
                .disabled(
                    refreshingContextTabIDs.contains(workspace.selectedTabID)
                        || !session.isRunning
                )
                .help("Обновить безопасные подсказки по службам и контейнерам сервера")
                .accessibilityLabel("Обновить команды сервера")

                Button {
                    showsHistory.toggle()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("История, поиск и общие подсказки команд")
                .accessibilityLabel("История и подсказки команд")
                .keyboardShortcut("y", modifiers: [.command, .shift])

                Button {
                    if broadcastsInput {
                        broadcastsInput = false
                    } else {
                        showsBroadcastConfirmation = true
                    }
                } label: {
                    Image(systemName: broadcastsInput ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right")
                }
                .disabled(workspace.runningSessionCount < 2)
                .help(
                    broadcastsInput
                        ? "Групповой ввод включён: клавиши отправляются во все активные панели"
                        : "Отправлять ввод во все активные панели"
                )
                .accessibilityLabel("Групповой ввод")

                Button {
                    openSFTP(workspace.selectedTab)
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .disabled(workspace.isEmptyState)
                .help("Открыть этот сервер в SFTP")
                .accessibilityLabel("Открыть сервер в SFTP")

                Button {
                    showsCommandPalette = true
                } label: {
                    Image(systemName: "command")
                }
                .help("Палитра действий — ⌘K")
                .accessibilityLabel("Палитра действий")
                .keyboardShortcut("k", modifiers: .command)

                Button {
                    showsAppearance.toggle()
                } label: {
                    Image(systemName: "paintpalette")
                }
                .help("Оформление терминала")
                .accessibilityLabel("Оформление терминала")
                .popover(isPresented: $showsAppearance, arrowEdge: .bottom) {
                    TerminalAppearanceView(
                        store: appearance,
                        appAppearance: appAppearance
                    )
                }

                Button {
                    toggleFocusMode()
                } label: {
                    Image(
                        systemName: isFocusMode
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .help(Text(isFocusMode ? "Вернуть интерфейс" : "Развернуть терминал"))
                .accessibilityLabel(
                    Text(isFocusMode ? "Вернуть интерфейс" : "Развернуть терминал")
                )
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                Button {
                    installKey()
                } label: {
                    Image(systemName: "key.horizontal")
                }
                .disabled(!hasInstallableKey || session.isRunning || !workspace.selectedTab.isPrimary)
                .help("Добавить выбранный публичный ключ в ~/.ssh/authorized_keys сервера")
                .accessibilityLabel("Установить SSH-ключ на сервер")

                Button {
                    session.clear()
                } label: {
                    Image(systemName: "eraser")
                }
                .help("Очистить терминал")
                .accessibilityLabel("Очистить терминал")
                if session.isRunning {
                    Button("Отключить", systemImage: "stop.fill", role: .destructive) {
                        session.stop()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Подключиться", systemImage: "play.fill") {
                        requestConnection(for: workspace.selectedTab)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            terminalTabBar

            if broadcastsInput {
                Label(
                    "Групповой ввод включён: клавиши отправляются во все активные панели",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }

            terminalWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 280)
                .layoutPriority(1)
                .background(TerminalColorCodecView.color(appearance.palette.background))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10))
                }

            Text(
                "Соединение выполняет системный /usr/bin/ssh внутри \(AppBrand.name). "
                    + "Сохранённый SSH-пароль передаётся OpenSSH через защищённый AskPass после выбранной проверки; "
                    + "несохранённые секреты можно ввести непосредственно в терминале. История команд хранится только на этом Mac; "
                    + "строки с пробелом в начале и распространёнными признаками секретов "
                    + "автоматически пропускаются."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SSH-терминал \(workspaceTitle)")
        .alert("Переименовать вкладку", isPresented: Binding(
            get: { renameTabID != nil },
            set: { if !$0 { renameTabID = nil } }
        )) {
            TextField("Название вкладки", text: $renameValue)
            Button("Отмена", role: .cancel) { renameTabID = nil }
            Button("Сохранить") {
                if let renameTabID {
                    workspace.renameTab(renameTabID, to: renameValue)
                }
                renameTabID = nil
            }
        }
        .alert("Включить групповой ввод?", isPresented: $showsBroadcastConfirmation) {
            Button("Отмена", role: .cancel) { }
            Button("Включить") { broadcastsInput = true }
        } message: {
            Text("Каждая введённая клавиша будет отправляться во все активные SSH-панели.")
        }
        .sheet(item: $connectionEditorRequest) { request in
            TerminalConnectionEditor(
                profiles: sshProfiles,
                initialConnection: request.initialConnection,
                onSave: { connection, suggestedTitle in
                    if let tabID = request.tabID {
                        let updated = workspace.updateConnection(
                            tabID: tabID,
                            connection: connection,
                            suggestedTitle: suggestedTitle
                        )
                        remoteContexts[tabID] = nil
                        if updated,
                           let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                            connect(tab)
                        }
                    } else {
                        if let tab = workspace.addTab(
                            connection: connection,
                            title: suggestedTitle
                        ) {
                            connect(tab)
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showsCommandPalette) {
            terminalCommandPalette
        }
        .task(id: "\(workspace.selectedTabID.uuidString)-\(session.isRunning)") {
            let tab = workspace.selectedTab
            guard tab.session.isRunning,
                  remoteContexts[tab.id]?.refreshedAt == nil
            else { return }
            try? await Task.sleep(for: .seconds(1))
            await loadRemoteContext(for: tab)
        }
    }

    private var terminalTabBar: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.displayedTabs) { tab in
                        HStack(spacing: 4) {
                            Button {
                                workspace.selectedTabID = tab.id
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(tab.session.isRunning ? Color.green : Color.secondary.opacity(0.45))
                                        .frame(width: 7, height: 7)
                                    Text(tab.title).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            if !tab.isPrimary || !locksPrimaryConnection {
                                Button {
                                    workspace.closeTab(tab.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .help("Закрыть вкладку")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            tab.id == workspace.selectedTabID
                                ? Color.accentColor.opacity(0.20)
                                : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contextMenu {
                            Button("Изменить подключение…") {
                                connectionEditorRequest = TerminalConnectionEditorRequest(
                                    tabID: tab.id,
                                    initialConnection: tab.connection
                                )
                            }
                            .disabled(
                                tab.session.isRunning
                                    || (tab.isPrimary && locksPrimaryConnection)
                            )
                            Button("Переименовать") {
                                renameValue = tab.title
                                renameTabID = tab.id
                            }
                            if !tab.isPrimary || !locksPrimaryConnection {
                                Divider()
                                Button("Закрыть", role: .destructive) {
                                    workspace.closeTab(tab.id)
                                }
                            }
                        }
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            reorderTabs(items, to: tab.id)
                        }
                    }
                }
            }

            Button {
                connectionEditorRequest = TerminalConnectionEditorRequest(
                    tabID: nil,
                    initialConnection: defaultProfileID.map {
                        .savedProfile($0)
                    } ?? .custom(host: "", username: "")
                )
            } label: {
                Image(systemName: "plus")
            }
            .disabled(workspace.displayedTabs.count >= 8)
            .help("Новая независимая SSH-вкладка")

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
            }
        }
    }

    private var terminalLayoutPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Компоновка терминалов")
                .font(.headline)
            Text("Порядок панелей можно менять перетаскиванием.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(TerminalWorkspaceLayout.allCases) { layout in
                Button {
                    workspace.setLayout(layout)
                    showsLayoutPicker = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: layout.systemImage)
                            .frame(width: 22)
                        Text(LocalizedStringKey(layout.title))
                        Spacer(minLength: 12)
                        if workspace.layout == layout {
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
                    workspace.layout == layout
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var terminalCommandPalette: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Действия терминала")
                .font(.title2.weight(.semibold))
            Button("Новое SSH-подключение", systemImage: "plus") {
                showsCommandPalette = false
                connectionEditorRequest = TerminalConnectionEditorRequest(
                    tabID: nil,
                    initialConnection: defaultProfileID.map { .savedProfile($0) }
                        ?? .custom(host: "", username: "")
                )
            }
            Button("Подключить выбранную панель", systemImage: "play.fill") {
                showsCommandPalette = false
                requestConnection(for: workspace.selectedTab)
            }
            .disabled(workspace.selectedTab.session.isRunning)
            Button("Открыть сервер в SFTP", systemImage: "folder.badge.gearshape") {
                showsCommandPalette = false
                openSFTP(workspace.selectedTab)
            }
            .disabled(workspace.isEmptyState)
            Button(
                broadcastsInput ? "Выключить групповой ввод" : "Включить групповой ввод",
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                showsCommandPalette = false
                if broadcastsInput {
                    broadcastsInput = false
                } else {
                    showsBroadcastConfirmation = true
                }
            }
            .disabled(workspace.runningSessionCount < 2)
            Divider()
            ForEach(TerminalWorkspaceLayout.allCases) { layout in
                Button(layout.title, systemImage: layout.systemImage) {
                    workspace.setLayout(layout)
                    showsCommandPalette = false
                }
                .disabled(workspace.isEmptyState)
            }
        }
        .buttonStyle(.bordered)
        .padding(22)
        .frame(width: 430)
    }

    @ViewBuilder
    private var terminalWorkspace: some View {
        if workspace.isEmptyState {
            VStack(spacing: 14) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Нет открытых терминалов")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Выберите сохранённый сервер или укажите новый SSH-адрес.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.68))
                Button("Подключиться", systemImage: "play.fill") {
                    requestConnection(for: workspace.selectedTab)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TerminalColorCodecView.color(appearance.palette.background))
        } else if workspace.layout == .splitHorizontal {
            HStack(spacing: 8) {
                ForEach(workspace.orderedSplitTabs()) { tab in
                    terminalPane(tab)
                }
            }
        } else if workspace.layout == .splitVertical {
            VStack(spacing: 8) {
                ForEach(workspace.orderedSplitTabs()) { tab in
                    terminalPane(tab)
                }
            }
        } else if workspace.layout == .grid {
            GeometryReader { proxy in
                let tabs = workspace.visibleTabs()
                let gap: CGFloat = 8
                let columnCount = tabs.count == 1 ? 1 : 2
                let rowCount = max(1, Int(ceil(Double(tabs.count) / Double(columnCount))))
                let paneWidth = max(
                    1,
                    (proxy.size.width - gap * CGFloat(columnCount - 1))
                        / CGFloat(columnCount)
                )
                let paneHeight = max(
                    1,
                    (proxy.size.height - gap * CGFloat(rowCount - 1))
                        / CGFloat(rowCount)
                )
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(paneWidth), spacing: gap),
                        count: columnCount
                    ),
                    spacing: gap
                ) {
                    ForEach(tabs) { tab in
                        terminalPane(tab)
                            .frame(width: paneWidth, height: paneHeight)
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
            }
        } else {
            terminalPane(workspace.selectedTab)
        }
    }

    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        let color = paneColor(for: tab)
        return VStack(spacing: 0) {
            if workspace.layout != .single {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.title).font(.caption.weight(.semibold))
                        Text(connectionLabel(for: tab))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer()
                    Text(tab.session.phase.title)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(color.opacity(tab.id == workspace.selectedTabID ? 0.28 : 0.16))
                .contentShape(Rectangle())
                .onTapGesture { selectTabIfNeeded(tab.id) }
                .draggable(tab.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    reorderTabs(items, to: tab.id)
                }
            }
            EmbeddedTerminalWebView(
                session: tab.session,
                appearance: appearance.snapshot,
                historyContext: TerminalHistoryContext(
                    profileID: historyContextID(for: tab)
                ),
                remoteContext: remoteContexts[tab.id] ?? .empty,
                onFocus: { selectTabIfNeeded(tab.id) },
                onInput: { data in
                    workspace.sendInput(
                        data,
                        from: tab.id,
                        broadcast: broadcastsInput
                    )
                },
                historyVisible: Binding(
                    get: { showsHistory && tab.id == workspace.selectedTabID },
                    set: { visible in
                        if visible { workspace.selectedTabID = tab.id }
                        showsHistory = visible
                    }
                )
            )
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if !tab.session.isRunning {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(color)
                        Text("Терминал не подключён")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(connectionLabel(for: tab))
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                        Button("Подключиться", systemImage: "play.fill") {
                            selectTabIfNeeded(tab.id)
                            requestConnection(for: tab)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalColorCodecView.color(appearance.palette.background))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    tab.id == workspace.selectedTabID
                        ? Color.accentColor
                        : color.opacity(0.65),
                    lineWidth: tab.id == workspace.selectedTabID ? 3 : 1
                )
                .allowsHitTesting(false)
        }
    }

    private func paneColor(for tab: TerminalWorkspaceTab) -> Color {
        let colors: [Color] = [.blue, .teal, .orange, .purple, .pink, .green]
        let index = tab.id.uuidString.utf8.reduce(0) {
            ($0 + Int($1)) % colors.count
        }
        return colors[index % colors.count]
    }

    private func requestConnection(for tab: TerminalWorkspaceTab) {
        if tab.isPrimary, locksPrimaryConnection {
            connect(tab)
            return
        }
        connectionEditorRequest = TerminalConnectionEditorRequest(
            tabID: tab.id,
            initialConnection: tab.connection
        )
    }

    private func reorderTabs(_ items: [String], to targetID: UUID) -> Bool {
        guard let value = items.first,
              let draggedID = UUID(uuidString: value),
              workspace.tabs.contains(where: { $0.id == draggedID })
        else { return false }
        workspace.moveTab(draggedID, to: targetID)
        return true
    }

    private func selectTabIfNeeded(_ id: UUID) {
        guard workspace.selectedTabID != id else { return }
        workspace.selectedTabID = id
    }

    private func refreshRemoteContext() {
        let tab = workspace.selectedTab
        guard !refreshingContextTabIDs.contains(tab.id) else { return }
        Task { await loadRemoteContext(for: tab) }
    }

    @MainActor
    private func loadRemoteContext(for tab: TerminalWorkspaceTab) async {
        guard !refreshingContextTabIDs.contains(tab.id) else { return }
        refreshingContextTabIDs.insert(tab.id)
        defer { refreshingContextTabIDs.remove(tab.id) }
        do {
            remoteContexts[tab.id] = try await discoverContext(tab)
        } catch {
            remoteContexts[tab.id] = TerminalRemoteContextSnapshot(
                hostLabel: connectionLabel(for: tab),
                systemLabel: "",
                refreshedAt: Date(),
                suggestions: [],
                message: error.localizedDescription
            )
        }
    }

    private func connectionLabel(for tab: TerminalWorkspaceTab) -> String {
        tab.connection.displayLabel(profiles: sshProfiles)
    }

    private func historyContextID(for tab: TerminalWorkspaceTab) -> UUID {
        if tab.connection.kind == .savedProfile,
           let profileID = tab.connection.profileID {
            return profileID
        }
        return tab.id
    }
}

private struct TerminalConnectionEditorRequest: Identifiable {
    let id = UUID()
    let tabID: UUID?
    let initialConnection: TerminalTabConnection
}

struct TerminalConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss

    let profiles: [ConnectionProfile]
    let onSave: (TerminalTabConnection, String) -> Void
    let allowsInteractivePassword: Bool
    let actionTitle: String
    let heading: String
    let message: String
    let customAuthenticationMessage: String?

    @State private var kind: TerminalTabConnection.Kind
    @State private var selectedProfileID: UUID?
    @State private var host: String
    @State private var username: String
    @State private var port: Int

    init(
        profiles: [ConnectionProfile],
        initialConnection: TerminalTabConnection,
        allowsInteractivePassword: Bool = true,
        actionTitle: String = "Подключить",
        heading: String = "Подключение вкладки",
        message: String = "Выберите сохранённый профиль или укажите временный SSH-адрес.",
        customAuthenticationMessage: String? = nil,
        onSave: @escaping (TerminalTabConnection, String) -> Void
    ) {
        self.profiles = profiles
        self.onSave = onSave
        self.allowsInteractivePassword = allowsInteractivePassword
        self.actionTitle = actionTitle
        self.heading = heading
        self.message = message
        self.customAuthenticationMessage = customAuthenticationMessage
        _kind = State(initialValue: initialConnection.kind)
        _selectedProfileID = State(
            initialValue: initialConnection.profileID ?? profiles.first?.id
        )
        _host = State(initialValue: initialConnection.host)
        _username = State(initialValue: initialConnection.username)
        _port = State(initialValue: initialConnection.port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(heading))
                    .font(.title2.weight(.semibold))
                Text(LocalizedStringKey(message))
                    .foregroundStyle(.secondary)
            }

            Picker("Источник", selection: $kind) {
                ForEach(TerminalTabConnection.Kind.allCases) { item in
                    Text(LocalizedStringKey(item.title)).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if kind == .savedProfile {
                Picker("SSH-профиль", selection: $selectedProfileID) {
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading) {
                            Text(profile.friendlyName)
                            Text(profile.host).foregroundStyle(.secondary)
                        }
                        .tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.menu)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Hostname или IP", text: $host)
                    TextField("Логин — необязательно", text: $username)
                    TextField("Порт", value: $port, format: .number)
                }
                Text(
                    customAuthenticationMessage
                        ?? (allowsInteractivePassword
                            ? "Пароль будет запрошен непосредственно в терминале. "
                                + "Временное подключение использует системный ssh-agent и ~/.ssh/config."
                            : "Фоновое подключение не может запросить пароль в терминале. "
                                + "Используйте SSH-ключ, системный ssh-agent или ~/.ssh/config.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                Button(actionTitle) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var canSave: Bool {
        switch kind {
        case .savedProfile:
            guard let selectedProfileID else { return false }
            return profiles.contains(where: { $0.id == selectedProfileID })
        case .custom:
            return TerminalTabConnection.custom(
                host: host,
                username: username,
                port: port
            ).isValidCustomConnection
        }
    }

    private func save() {
        switch kind {
        case .savedProfile:
            guard let selectedProfileID,
                  let profile = profiles.first(where: { $0.id == selectedProfileID })
            else { return }
            onSave(.savedProfile(profile.id), profile.friendlyName)
        case .custom:
            let connection = TerminalTabConnection.custom(
                host: host,
                username: username,
                port: port
            )
            guard connection.isValidCustomConnection else { return }
            let title = connection.normalizedUsername.isEmpty
                ? connection.normalizedHost
                : "\(connection.normalizedUsername)@\(connection.normalizedHost)"
            onSave(connection, title)
        }
        dismiss()
    }
}

private enum TerminalColorCodecView {
    static func color(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16)
        else { return Color(red: 0.063, green: 0.075, blue: 0.102) }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
