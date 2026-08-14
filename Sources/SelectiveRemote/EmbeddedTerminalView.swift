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
    let onRemoteContextRetry: () -> Void
    let onFocus: () -> Void
    let onInput: (Data) -> Void
    let onTabNavigation: (Int) -> Void
    @Binding var historyVisible: Bool

    init(
        session: TerminalSessionModel,
        appearance: TerminalAppearanceSnapshot,
        historyContext: TerminalHistoryContext? = nil,
        remoteContext: TerminalRemoteContextSnapshot = .empty,
        onRemoteContextRetry: @escaping () -> Void = {},
        onFocus: @escaping () -> Void = {},
        onInput: ((Data) -> Void)? = nil,
        onTabNavigation: @escaping (Int) -> Void = { _ in },
        historyVisible: Binding<Bool> = .constant(false)
    ) {
        self.session = session
        self.appearance = appearance
        self.historyContext = historyContext
        self.remoteContext = remoteContext
        self.onRemoteContextRetry = onRemoteContextRetry
        self.onFocus = onFocus
        self.onInput = onInput ?? { _ in }
        self.onTabNavigation = onTabNavigation
        _historyVisible = historyVisible
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            appearance: appearance,
            historyContext: historyContext,
            remoteContext: remoteContext,
            onRemoteContextRetry: onRemoteContextRetry,
            onFocus: onFocus,
            onInput: onInput,
            onTabNavigation: onTabNavigation,
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
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.navigationMessageName
        )

        let webView = TerminalWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(to: webView)
        webView.layoutHandler = { [weak coordinator = context.coordinator] in
            coordinator?.requestFit()
        }
        webView.visibilityHandler = { [weak coordinator = context.coordinator] visible in
            if visible {
                coordinator?.terminalBecameVisible()
            }
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
        context.coordinator.updateRemoteContextRetryHandler(onRemoteContextRetry)
        context.coordinator.updateFocusHandler(onFocus)
        context.coordinator.updateInputHandler(onInput)
        context.coordinator.updateTabNavigationHandler(onTabNavigation)
        context.coordinator.updateSession(session)
        context.coordinator.updateAppearance(appearance)
        context.coordinator.updateHistoryVisibility(historyVisible)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        (webView as? TerminalWKWebView)?.layoutHandler = nil
        (webView as? TerminalWKWebView)?.visibilityHandler = nil
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
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.navigationMessageName
        )
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let inputMessageName = "terminalInput"
        static let resizeMessageName = "terminalResize"
        static let historyMessageName = "terminalHistory"
        static let focusMessageName = "terminalFocus"
        static let navigationMessageName = "terminalNavigation"

        private weak var session: TerminalSessionModel?
        private weak var webView: WKWebView?
        private var observerID: UUID?
        private var appearance: TerminalAppearanceSnapshot
        private var historyContext: TerminalHistoryContext?
        private var remoteContext: TerminalRemoteContextSnapshot
        private var onRemoteContextRetry: () -> Void
        private var onFocus: () -> Void
        private var onInput: (Data) -> Void
        private var onTabNavigation: (Int) -> Void
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
            onRemoteContextRetry: @escaping () -> Void,
            onFocus: @escaping () -> Void,
            onInput: @escaping (Data) -> Void,
            onTabNavigation: @escaping (Int) -> Void,
            historyVisible: Binding<Bool>
        ) {
            self.session = session
            self.appearance = appearance
            self.historyContext = historyContext
            self.remoteContext = remoteContext
            self.onRemoteContextRetry = onRemoteContextRetry
            self.onFocus = onFocus
            self.onInput = onInput
            self.onTabNavigation = onTabNavigation
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

        func updateRemoteContextRetryHandler(_ updated: @escaping () -> Void) {
            onRemoteContextRetry = updated
        }

        func updateFocusHandler(_ updated: @escaping () -> Void) {
            onFocus = updated
        }

        func updateInputHandler(_ updated: @escaping (Data) -> Void) {
            onInput = updated
        }

        func updateTabNavigationHandler(_ updated: @escaping (Int) -> Void) {
            onTabNavigation = updated
        }

        func updateHistoryVisibility(_ visible: Bool) {
            guard pageReady else {
                appliedHistoryVisibility = nil
                return
            }
            guard appliedHistoryVisibility != visible else { return }
            appliedHistoryVisibility = visible
            webView?.evaluateJavaScript(
                // Swift synchronizes history visibility when the active grid pane
                // changes. Do not return focus to a pane merely because its history
                // panel is being hidden programmatically: that focus event would
                // select the old pane again and make two panes bounce forever.
                "window.selectiveTerminalSetHistoryVisible?.(\(visible ? "true" : "false"), false, false)"
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

        func terminalBecameVisible() {
            guard pageReady else { return }
            requestFit()
            Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, self.pageReady else { return }
                self.requestFit()
                session?.refreshDisplay()
                try? await Task.sleep(for: .milliseconds(180))
                guard self.pageReady else { return }
                self.requestFit()
            }
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
            case Self.navigationMessageName:
                guard let value = message.body as? NSNumber else { return }
                onTabNavigation(value.intValue)
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

            // A host switch can recreate the WebView while the PTY keeps running.
            // Replaying ANSI output is not enough to reconstruct an alternate
            // screen perfectly (nano/vim/tmux). Re-send the PTY size so the remote
            // TUI receives SIGWINCH and paints a clean full frame.
            Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, self.pageReady else { return }
                self.requestFit()
                session?.refreshDisplay()
            }
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
            guard let payload = body as? [String: Any],
                  let action = payload["action"] as? String
            else { return }

            if action == "retryRemoteContext" {
                onRemoteContextRetry()
                return
            }
            guard let context = historyContext else { return }

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
    var visibilityHandler: ((Bool) -> Void)?

    override func layout() {
        super.layout()
        layoutHandler?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibilityHandler?(window != nil)
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
    let connect: (TerminalWorkspaceTab, String?) -> Void
    let installKey: () -> Void
    let toggleFocusMode: () -> Void
    let openSFTP: (TerminalWorkspaceTab) -> Void
    let discoverContext: (TerminalWorkspaceTab) async throws -> TerminalRemoteContextSnapshot

    @State private var showsAppearance = false
    @State private var showsHistory = false
    @State private var showsServerCommands = false
    @State private var refreshingContextTabIDs: Set<UUID> = []
    @State private var remoteContextRequestIDs: [UUID: UUID] = [:]
    @State private var renameTabID: UUID?
    @State private var renameValue = ""
    @State private var connectionEditorRequest: TerminalConnectionEditorRequest?
    @State private var showsLayoutPicker = false
    @State private var broadcastsInput = false
    @State private var showsBroadcastConfirmation = false
    @State private var reconnectingTabIDs: Set<UUID> = []
    @State private var showsCommandPalette = false

    private var session: TerminalSessionModel { workspace.selectedTab.session }

    private var remoteContextTaskID: String {
        "\(workspace.selectedTabID.uuidString)-\(session.phase.title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            terminalHeader

            terminalTabBar

            if broadcastsInput {
                broadcastBanner
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
                onSave: { connection, suggestedTitle, temporaryPassword in
                    if let tabID = request.tabID {
                        let updated = workspace.updateConnection(
                            tabID: tabID,
                            connection: connection,
                            suggestedTitle: suggestedTitle
                        )
                        invalidateRemoteContext(for: tabID)
                        if updated,
                           let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                            connect(tab, temporaryPassword)
                        }
                    } else {
                        if let tab = workspace.addTab(
                            connection: connection,
                            title: suggestedTitle
                        ) {
                            connect(tab, temporaryPassword)
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showsCommandPalette) {
            terminalCommandPalette
        }
        .sheet(isPresented: $showsServerCommands) {
            let tabID = workspace.selectedTabID
            ServerCommandsView(
                context: workspace.remoteContext(for: tabID) ?? .empty,
                isRefreshing: refreshingContextTabIDs.contains(tabID),
                onRefresh: { refreshRemoteContext(for: tabID) },
                onRun: { command in
                    runServerCommand(command, in: tabID)
                }
            )
        }
        .task(id: remoteContextTaskID) {
            let tab = workspace.selectedTab
            guard case .running = tab.session.phase else {
                invalidateRemoteContext(for: tab.id)
                return
            }
            guard workspace.remoteContext(for: tab.id)?.refreshedAt == nil else { return }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await loadRemoteContext(forTabID: tab.id)
        }
        .onChange(of: workspace.runningSessionCount) { _, count in
            if count < 2 {
                broadcastsInput = false
            }
        }
    }

    private var broadcastBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.22))
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("BROADCAST · ГРУППОВОЙ ВВОД")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.orange)
                Text("Каждая клавиша отправляется во все активные SSH-панели · \(workspace.runningSessionCount) активных")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 12)

            Button("Выключить", systemImage: "antenna.radiowaves.left.and.right.slash") {
                broadcastsInput = false
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.85), lineWidth: 2)
        }
        .shadow(color: Color.orange.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Групповой ввод включён")
    }

    private var terminalHeader: some View {
        let tab = workspace.selectedTab
        let state = sessionState(for: tab)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(paneColor(for: tab).opacity(0.16))
                Image(systemName: "terminal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(paneColor(for: tab))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(tab.title)
                        .font(.headline)
                        .lineLimit(1)
                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    terminalStatusBadge(for: tab, compact: false)
                }

                HStack(spacing: 7) {
                    Label(connectionHost(for: tab), systemImage: "server.rack")
                        .labelStyle(.titleAndIcon)
                    Text("·")
                    Text(connectionLabel(for: tab))
                        .monospaced()
                    if tab.session.startedAt != nil, state != .disconnected {
                        Text("·")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(uptimeText(for: tab, now: context.date))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            if broadcastsInput {
                Label("BROADCAST", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.orange.opacity(0.7), lineWidth: 1)
                    }
            }

            Button {
                if tab.session.isRunning {
                    reconnectTab(tab.id)
                } else {
                    requestConnection(for: tab)
                }
            } label: {
                Image(systemName: tab.session.isRunning ? "arrow.clockwise" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(reconnectingTabIDs.contains(tab.id))
            .help(tab.session.isRunning ? "Переподключить" : "Подключиться")

            Button {
                _ = duplicateAndConnect(tab.id)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.bordered)
            .disabled(workspace.displayedTabs.count >= 8 || workspace.isEmptyState)
            .help("Дублировать с подключением")

            Button {
                showsServerCommands = true
                if workspace.remoteContext(for: tab.id)?.refreshedAt == nil {
                    refreshRemoteContext(for: tab.id)
                }
            } label: {
                Image(systemName: "server.rack")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .disabled(!tab.session.isRunning)
            .help("Команды сервера")

            Button {
                showsHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("История и подсказки")

            if isFocusMode {
                Button("Вернуть интерфейс", systemImage: "arrow.down.right.and.arrow.up.left") {
                    toggleFocusMode()
                }
                .buttonStyle(.borderedProminent)
                .help("Показать боковую панель и обычный интерфейс приложения")
            }

            Menu {
                Button("Изменить подключение…", systemImage: "slider.horizontal.3") {
                    connectionEditorRequest = TerminalConnectionEditorRequest(
                        tabID: tab.id,
                        initialConnection: tab.connection
                    )
                }
                .disabled(tab.session.isRunning || (tab.isPrimary && locksPrimaryConnection))
                Button("Команды сервера", systemImage: "server.rack") {
                    showsServerCommands = true
                    if workspace.remoteContext(for: tab.id)?.refreshedAt == nil {
                        refreshRemoteContext(for: tab.id)
                    }
                }
                .disabled(!tab.session.isRunning)
                Button("Обновить контекст сервера", systemImage: "arrow.clockwise") { refreshRemoteContext() }
                    .disabled(!tab.session.isRunning || refreshingContextTabIDs.contains(workspace.selectedTabID))
                Button("Открыть в SFTP", systemImage: "folder.badge.gearshape") { openSFTP(tab) }
                    .disabled(workspace.isEmptyState)
                Divider()
                Button(
                    broadcastsInput ? "Выключить групповой ввод" : "Включить групповой ввод",
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    if broadcastsInput { broadcastsInput = false } else { showsBroadcastConfirmation = true }
                }
                .disabled(workspace.runningSessionCount < 2)
                Button("Очистить терминал", systemImage: "eraser") { tab.session.clear() }
                Divider()
                Button("Палитра действий", systemImage: "command") { showsCommandPalette = true }
                Button("Оформление", systemImage: "paintpalette") { showsAppearance.toggle() }
                if !isFocusMode {
                    Button("Развернуть терминал", systemImage: "arrow.up.left.and.arrow.down.right") {
                        toggleFocusMode()
                    }
                }
                if hasInstallableKey && tab.isPrimary && !tab.session.isRunning {
                    Divider()
                    Button("Установить SSH-ключ", systemImage: "key.horizontal") { installKey() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(isPresented: $showsAppearance, arrowEdge: .bottom) {
                TerminalAppearanceView(store: appearance, appAppearance: appAppearance)
            }

            if tab.session.isRunning {
                Button("Отключить", systemImage: "stop.fill", role: .destructive) {
                    reconnectingTabIDs.remove(tab.id)
                    tab.session.stop()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private var terminalTabBar: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.displayedTabs) { tab in
                        let isSelected = tab.id == workspace.selectedTabID
                        let state = sessionState(for: tab)

                        HStack(spacing: 4) {
                            Button {
                                workspace.selectedTabID = tab.id
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(statusColor(for: state))
                                        .frame(width: 8, height: 8)
                                    if tab.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.caption2)
                                            .foregroundStyle(paneColor(for: tab))
                                    }
                                    Text(tab.title)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                        .lineLimit(1)
                                    if state == .reconnecting {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            if (!tab.isPrimary || !locksPrimaryConnection) && !tab.isPinned {
                                Button {
                                    reconnectingTabIDs.remove(tab.id)
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
                        .padding(.vertical, 7)
                        .background(
                            isSelected
                                ? Color.accentColor.opacity(0.24)
                                : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? Color.accentColor.opacity(0.85)
                                        : Color.primary.opacity(0.06),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        }
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(height: 3)
                                    .padding(.horizontal, 10)
                                    .offset(y: 1)
                            }
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                workspace.selectedTabID = tab.id
                                renameValue = tab.title
                                renameTabID = tab.id
                            }
                        )
                        .contextMenu {
                            if tab.session.isRunning {
                                Button("Переподключить", systemImage: "arrow.clockwise") {
                                    reconnectTab(tab.id)
                                }
                                .disabled(reconnectingTabIDs.contains(tab.id))
                                Button("Отключить", systemImage: "stop.fill", role: .destructive) {
                                    reconnectingTabIDs.remove(tab.id)
                                    tab.session.stop()
                                }
                            } else {
                                Button("Подключить", systemImage: "play.fill") {
                                    selectTabIfNeeded(tab.id)
                                    requestConnection(for: tab)
                                }
                            }

                            Button(tab.isPinned ? "Открепить вкладку" : "Закрепить вкладку", systemImage: tab.isPinned ? "pin.slash" : "pin") {
                                workspace.togglePinned(tab.id)
                            }
                            Button("Сменить цвет", systemImage: "paintpalette.fill") {
                                workspace.cycleColor(tab.id)
                            }
                            Button("Очистить терминал", systemImage: "eraser") {
                                tab.session.clear()
                            }

                            Divider()

                            Button("Изменить подключение…", systemImage: "slider.horizontal.3") {
                                connectionEditorRequest = TerminalConnectionEditorRequest(
                                    tabID: tab.id,
                                    initialConnection: tab.connection
                                )
                            }
                            .disabled(
                                tab.session.isRunning
                                    || (tab.isPrimary && locksPrimaryConnection)
                            )
                            Button("Переименовать", systemImage: "pencil") {
                                renameValue = tab.title
                                renameTabID = tab.id
                            }
                            Button("Создать копию вкладки", systemImage: "plus.square.on.square") {
                                _ = workspace.duplicateTab(tab.id)
                            }
                            .disabled(workspace.displayedTabs.count >= 8)
                            Button("Дублировать с подключением", systemImage: "rectangle.on.rectangle.badge.plus") {
                                _ = duplicateAndConnect(tab.id)
                            }
                            .disabled(workspace.displayedTabs.count >= 8)

                            if workspace.displayedTabs.count < 8 {
                                Button("Новая вкладка", systemImage: "plus") {
                                    connectionEditorRequest = TerminalConnectionEditorRequest(
                                        tabID: nil,
                                        initialConnection: defaultProfileID.map { .savedProfile($0) }
                                            ?? .custom(host: "", username: "root")
                                    )
                                }
                            }

                            if (!tab.isPrimary || !locksPrimaryConnection) && !tab.isPinned {
                                Divider()
                                Button("Закрыть", systemImage: "xmark", role: .destructive) {
                                    reconnectingTabIDs.remove(tab.id)
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
                .padding(.vertical, 1)
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
            Button("Команды сервера", systemImage: "server.rack") {
                showsCommandPalette = false
                showsServerCommands = true
                if workspace.remoteContext(for: workspace.selectedTabID)?.refreshedAt == nil {
                    refreshRemoteContext()
                }
            }
            .disabled(!workspace.selectedTab.session.isRunning)
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
            }
        }
        .buttonStyle(.bordered)
        .padding(22)
        .frame(width: 430)
    }

    @ViewBuilder
    private var terminalWorkspace: some View {
        if workspace.layout == .grid {
            GeometryReader { proxy in
                let tabs = workspace.visibleTabs()
                let canAddPane = tabs.count < 4 && workspace.displayedTabs.count < 8
                let reservedAddPaneCount = canAddPane ? 1 : 0
                let emptyPaneCount = max(0, 4 - tabs.count - reservedAddPaneCount)
                let gap: CGFloat = 8
                let columnCount = 2
                let rowCount = 2
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
                    if canAddPane {
                        gridAddPane
                            .frame(width: paneWidth, height: paneHeight)
                    }
                    ForEach(0..<emptyPaneCount, id: \.self) { _ in
                        gridEmptyPane
                            .frame(width: paneWidth, height: paneHeight)
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
            }
        } else if workspace.isEmptyState {
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
        } else {
            terminalPane(workspace.selectedTab)
        }
    }

    private var gridAddPane: some View {
        Button {
            connectionEditorRequest = TerminalConnectionEditorRequest(
                tabID: nil,
                initialConnection: defaultProfileID.map { .savedProfile($0) }
                    ?? .custom(host: "", username: "")
            )
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.08), in: Circle())
                Text("Добавить SSH-панель")
                    .font(.callout.weight(.semibold))
                Text("Выбрать сервер или указать новый адрес")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.82))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(0.20),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                )
        }
        .help("Добавить SSH-панель")
    }

    private var gridEmptyPane: some View {
        VStack(spacing: 9) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 22, weight: .medium))
            Text("Свободная SSH-панель")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.34))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.018))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(0.13),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 6])
                )
        }
    }

    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        let color = paneColor(for: tab)
        let isSelected = tab.id == workspace.selectedTabID
        let state = sessionState(for: tab)
        let broadcastTarget = broadcastsInput && tab.session.isRunning

        return VStack(spacing: 0) {
            if workspace.layout != .single {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(tab.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if isSelected {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                            }
                            if broadcastTarget {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                        }

                        HStack(spacing: 5) {
                            Text(connectionHost(for: tab))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(1)
                            if tab.session.startedAt != nil, state != .disconnected {
                                Text("·")
                                    .foregroundStyle(.white.opacity(0.42))
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(uptimeText(for: tab, now: context.date))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.72))
                                }
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    terminalStatusBadge(for: tab, compact: true)

                    if tab.session.isRunning {
                        Button {
                            reconnectTab(tab.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(reconnectingTabIDs.contains(tab.id))
                        .help("Переподключить")
                    } else {
                        Button {
                            selectTabIfNeeded(tab.id)
                            requestConnection(for: tab)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Подключить")
                    }

                    Button {
                        _ = duplicateAndConnect(tab.id)
                    } label: {
                        Image(systemName: "plus.square.on.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(workspace.displayedTabs.count >= 8)
                    .help("Дублировать с подключением")

                    if (!tab.isPrimary || !locksPrimaryConnection) && !tab.isPinned {
                        Button {
                            reconnectingTabIDs.remove(tab.id)
                            workspace.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Закрыть панель")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : (broadcastTarget ? Color.orange.opacity(0.16) : color.opacity(0.14))
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.9)
                                : (broadcastTarget ? Color.orange.opacity(0.85) : color.opacity(0.4))
                        )
                        .frame(height: isSelected || broadcastTarget ? 2 : 1)
                }
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
                remoteContext: workspace.remoteContext(for: tab.id) ?? .empty,
                onRemoteContextRetry: {
                    selectTabIfNeeded(tab.id)
                    refreshRemoteContext(for: tab.id)
                },
                onFocus: { selectTabIfNeeded(tab.id) },
                onInput: { data in
                    workspace.sendInput(
                        data,
                        from: tab.id,
                        broadcast: broadcastsInput
                    )
                },
                onTabNavigation: { token in
                    navigateTabs(token)
                },
                historyVisible: Binding(
                    get: { showsHistory && tab.id == workspace.selectedTabID },
                    set: { visible in
                        // Each pane owns a WKWebView and can report its history visibility
                        // asynchronously. Ignore stale callbacks from a pane that stopped
                        // being active, otherwise two grid panes can keep re-selecting each
                        // other while the history panel is open.
                        guard tab.id == workspace.selectedTabID else { return }
                        showsHistory = visible
                    }
                )
            )
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if !tab.session.isRunning {
                    if let progress = tab.session.reconnectProgress {
                        terminalReconnectOverlay(tab: tab, progress: progress)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: state.systemImage)
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(statusColor(for: state))
                            Text(LocalizedStringKey(state.title))
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(connectionLabel(for: tab))
                                .font(.caption.monospaced())
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                            if let detail = state.detail {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.red.opacity(0.9))
                            }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalColorCodecView.color(appearance.palette.background))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor
                        : (broadcastTarget ? Color.orange : color.opacity(0.65)),
                    lineWidth: isSelected ? 3.5 : (broadcastTarget ? 3 : 1)
                )
                .allowsHitTesting(false)
        }
        .shadow(
            color: isSelected
                ? Color.accentColor.opacity(0.20)
                : (broadcastTarget ? Color.orange.opacity(0.16) : Color.clear),
            radius: isSelected || broadcastTarget ? 8 : 0
        )
    }

    private func terminalReconnectOverlay(
        tab: TerminalWorkspaceTab,
        progress: SmartReconnectProgress
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Smart Reconnect · \(progress.attemptLabel)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(progress.reason)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                if let countdown = progress.countdownText(now: context.date) {
                    Text(countdown)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                }
                Button("Отменить reconnect", systemImage: "xmark.circle") {
                    reconnectingTabIDs.remove(tab.id)
                    tab.session.stop()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
            }
        }
    }

    private func paneColor(for tab: TerminalWorkspaceTab) -> Color {
        let colors: [Color] = [.blue, .teal, .orange, .purple, .pink, .green]
        let index = max(0, tab.colorIndex) % colors.count
        return colors[index]
    }

    private func sessionState(for tab: TerminalWorkspaceTab) -> TerminalWorkspaceSessionState {
        TerminalWorkspaceSessionState.resolve(
            phase: tab.session.phase,
            isReconnecting: reconnectingTabIDs.contains(tab.id)
                || tab.session.reconnectProgress != nil,
            terminationRequested: tab.session.lastTerminationWasRequested
        )
    }

    private func statusColor(for state: TerminalWorkspaceSessionState) -> Color {
        switch state {
        case .connected:
            .green
        case .connecting:
            .blue
        case .reconnecting, .stopping:
            .orange
        case .disconnected:
            .secondary
        case .error:
            .red
        }
    }

    private func terminalStatusBadge(
        for tab: TerminalWorkspaceTab,
        compact: Bool
    ) -> some View {
        let state = sessionState(for: tab)
        let color = statusColor(for: state)
        return HStack(spacing: compact ? 4 : 5) {
            Image(systemName: state.systemImage)
                .font(compact ? .system(size: 9, weight: .semibold) : .caption2)
            if let progress = tab.session.reconnectProgress {
                Text("Reconnect \(progress.attempt)/\(progress.maximumAttempts)")
                    .font(compact ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold))
                    .lineLimit(1)
            } else {
                Text(LocalizedStringKey(state.title))
                    .font(compact ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 3 : 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        }
        .help(state.detail ?? state.title)
    }

    private func connectionHost(for tab: TerminalWorkspaceTab) -> String {
        switch tab.connection.kind {
        case .savedProfile:
            guard let profileID = tab.connection.profileID,
                  let profile = sshProfiles.first(where: { $0.id == profileID })
            else { return "Недоступный профиль" }
            let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
            return host.isEmpty ? "—" : host
        case .custom:
            let host = tab.connection.normalizedHost
            return host.isEmpty ? "—" : host
        }
    }

    private func uptimeText(for tab: TerminalWorkspaceTab, now: Date) -> String {
        guard let startedAt = tab.session.startedAt else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m \(seconds % 60)s"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h \(minutes % 60)m"
        }
        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }

    private func navigateTabs(_ token: Int) {
        let tabs = workspace.displayedTabs
        guard !tabs.isEmpty else { return }

        if token >= 0 {
            guard token < tabs.count else { return }
            workspace.selectedTabID = tabs[token].id
            return
        }

        guard let currentIndex = tabs.firstIndex(where: { $0.id == workspace.selectedTabID }) else {
            workspace.selectedTabID = tabs[0].id
            return
        }
        let delta = token == -2 ? -1 : 1
        let nextIndex = (currentIndex + delta + tabs.count) % tabs.count
        workspace.selectedTabID = tabs[nextIndex].id
    }

    private func reconnectTab(_ tabID: UUID) {
        guard !reconnectingTabIDs.contains(tabID),
              let tab = workspace.tabs.first(where: { $0.id == tabID })
        else { return }

        reconnectingTabIDs.insert(tabID)
        invalidateRemoteContext(for: tabID)

        Task { @MainActor in
            if tab.session.isRunning {
                tab.session.stop()
            }

            var attempts = 0
            while tab.session.isRunning, attempts < 40 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard !tab.session.isRunning,
                  let current = workspace.tabs.first(where: { $0.id == tabID })
            else {
                reconnectingTabIDs.remove(tabID)
                return
            }

            connect(current, nil)
            try? await Task.sleep(for: .milliseconds(450))
            reconnectingTabIDs.remove(tabID)
        }
    }

    @discardableResult
    private func duplicateAndConnect(_ tabID: UUID) -> TerminalWorkspaceTab? {
        guard let created = workspace.duplicateTab(tabID) else { return nil }
        connect(created, nil)
        return created
    }

    private func requestConnection(for tab: TerminalWorkspaceTab) {
        if tab.isPrimary, locksPrimaryConnection {
            connect(tab, nil)
            return
        }

        // A disconnected pane keeps its connection. The primary action should
        // reconnect that same server; changing the server remains available
        // through “Изменить подключение…”. Only an empty/stale pane opens the
        // connection editor.
        if canReuseConnection(tab.connection) {
            connect(tab, nil)
            return
        }

        connectionEditorRequest = TerminalConnectionEditorRequest(
            tabID: tab.id,
            initialConnection: tab.connection
        )
    }

    private func canReuseConnection(_ connection: TerminalTabConnection) -> Bool {
        switch connection.kind {
        case .savedProfile:
            guard let profileID = connection.profileID else { return false }
            return sshProfiles.contains { profile in
                profile.id == profileID && profile.connectionType == .ssh
            }
        case .custom:
            return connection.isValidCustomConnection
        }
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

    private func refreshRemoteContext(for tabID: UUID? = nil) {
        let resolvedTabID = tabID ?? workspace.selectedTabID
        invalidateRemoteContext(for: resolvedTabID)
        Task { await loadRemoteContext(forTabID: resolvedTabID) }
    }

    @MainActor
    private func invalidateRemoteContext(for tabID: UUID) {
        workspace.invalidateRemoteContext(for: tabID)
        remoteContextRequestIDs[tabID] = nil
        refreshingContextTabIDs.remove(tabID)
    }

    @MainActor
    private func loadRemoteContext(forTabID tabID: UUID) async {
        guard !refreshingContextTabIDs.contains(tabID),
              let tab = workspace.tabs.first(where: { $0.id == tabID }),
              case .running = tab.session.phase
        else { return }

        let expectedConnection = tab.connection
        let expectedHostLabel = connectionLabel(for: tab)
        let requestID = UUID()
        remoteContextRequestIDs[tabID] = requestID
        refreshingContextTabIDs.insert(tabID)
        workspace.setRemoteContext(.loading(hostLabel: expectedHostLabel), for: tabID)
        defer {
            if remoteContextRequestIDs[tabID] == requestID {
                remoteContextRequestIDs[tabID] = nil
                refreshingContextTabIDs.remove(tabID)
            }
        }

        do {
            let snapshot = try await discoverContext(tab)
            guard remoteContextRequestIDs[tabID] == requestID,
                  let currentTab = workspace.tabs.first(where: { $0.id == tabID }),
                  currentTab.connection == expectedConnection,
                  case .running = currentTab.session.phase
            else { return }
            workspace.setRemoteContext(snapshot, for: tabID)
        } catch {
            guard remoteContextRequestIDs[tabID] == requestID,
                  let currentTab = workspace.tabs.first(where: { $0.id == tabID }),
                  currentTab.connection == expectedConnection,
                  case .running = currentTab.session.phase
            else { return }
            workspace.setRemoteContext(
                TerminalRemoteContextSnapshot(
                    hostLabel: expectedHostLabel,
                    systemLabel: expectedHostLabel,
                    refreshedAt: Date(),
                    suggestions: [],
                    message: error.localizedDescription,
                    canRetry: true
                ),
                for: tabID
            )
        }
    }

    private func runServerCommand(_ rawCommand: String, in tabID: UUID) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty,
              !command.contains("\0"),
              command.count <= 4_096,
              let tab = workspace.tabs.first(where: { $0.id == tabID }),
              case .running = tab.session.phase
        else { return }

        _ = TerminalCommandHistoryStore.shared.record(
            command: command,
            profileID: historyContextID(for: tab)
        )
        tab.session.sendInput(Data((command + "\n").utf8))
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
    @EnvironmentObject private var model: AppModel

    let profiles: [ConnectionProfile]
    let onSave: (TerminalTabConnection, String, String?) -> Void
    let allowsInteractivePassword: Bool
    let allowsTemporaryPassword: Bool
    let actionTitle: String
    let heading: String
    let message: String
    let customAuthenticationMessage: String?

    @State private var kind: TerminalTabConnection.Kind
    @State private var selectedProfileID: UUID?
    @State private var host: String
    @State private var username: String
    @State private var port: Int
    @State private var password: String
    @State private var saveAsProfile: Bool
    @State private var profileName: String

    init(
        profiles: [ConnectionProfile],
        initialConnection: TerminalTabConnection,
        allowsInteractivePassword: Bool = true,
        allowsTemporaryPassword: Bool = true,
        actionTitle: String = "Подключить",
        heading: String = "Подключение вкладки",
        message: String = "Выберите сохранённый профиль или укажите временный SSH-адрес.",
        customAuthenticationMessage: String? = nil,
        onSave: @escaping (TerminalTabConnection, String, String?) -> Void
    ) {
        self.profiles = profiles
        self.onSave = onSave
        self.allowsInteractivePassword = allowsInteractivePassword
        self.allowsTemporaryPassword = allowsTemporaryPassword
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
        _password = State(initialValue: "")
        _saveAsProfile = State(initialValue: false)
        _profileName = State(initialValue: initialConnection.host)
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
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Hostname или IP", text: $host)
                        HStack(spacing: 10) {
                            TextField("Логин", text: $username, prompt: Text("root"))
                            TextField("Порт", value: $port, format: .number)
                                .frame(width: 105)
                        }
                        Text("Если логин не указан, используется root.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } label: {
                    Label("Сервер", systemImage: "server.rack")
                }

                if allowsTemporaryPassword || saveAsProfile {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("Пароль — необязательно", text: $password)
                            Text(
                                saveAsProfile
                                    ? "Пароль будет сохранён только в macOS Keychain."
                                    : "Пароль используется только для текущего подключения и удаляется из временной Keychain-записи после завершения сессии."
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    } label: {
                        Label("Аутентификация", systemImage: "key.fill")
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Сохранить как SSH-профиль", isOn: $saveAsProfile)
                            .toggleStyle(.switch)
                        if saveAsProfile {
                            TextField("Название подключения", text: $profileName)
                            Text("Адрес, логин и порт появятся в списке подключений; введённый пароль хранится только в macOS Keychain.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label("Сохранение", systemImage: "bookmark")
                }

                Text(
                    customAuthenticationMessage
                        ?? (allowsInteractivePassword
                            ? "Для временного подключения используется системный ssh-agent и ~/.ssh/config; при необходимости OpenSSH запросит пароль отдельно."
                            : "Для временного фонового подключения используйте SSH-ключ, системный ssh-agent или ~/.ssh/config. Для пароля сохраните подключение как SSH-профиль.")
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
        .frame(width: 560)
        .onChange(of: host) { _, value in
            if saveAsProfile, profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profileName = value
            }
        }
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
            onSave(.savedProfile(profile.id), profile.friendlyName, nil)
        case .custom:
            let effectiveUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "root"
                : username
            let connection = TerminalTabConnection.custom(
                host: host,
                username: effectiveUsername,
                port: port
            )
            guard connection.isValidCustomConnection else { return }

            if saveAsProfile {
                let suggestedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? connection.normalizedHost
                    : profileName
                guard let profileID = model.saveManualSSHProfile(
                    host: connection.normalizedHost,
                    username: effectiveUsername,
                    port: connection.port,
                    name: suggestedName,
                    password: password
                ) else { return }
                onSave(.savedProfile(profileID), suggestedName, nil)
            } else {
                let title = "\(effectiveUsername)@\(connection.normalizedHost)"
                onSave(connection, title, password.isEmpty ? nil : password)
            }
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
