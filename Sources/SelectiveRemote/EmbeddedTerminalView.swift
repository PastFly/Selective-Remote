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
    @Binding var historyVisible: Bool

    init(
        session: TerminalSessionModel,
        appearance: TerminalAppearanceSnapshot,
        historyContext: TerminalHistoryContext? = nil,
        remoteContext: TerminalRemoteContextSnapshot = .empty,
        historyVisible: Binding<Bool> = .constant(false)
    ) {
        self.session = session
        self.appearance = appearance
        self.historyContext = historyContext
        self.remoteContext = remoteContext
        _historyVisible = historyVisible
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            appearance: appearance,
            historyContext: historyContext,
            remoteContext: remoteContext,
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
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let inputMessageName = "terminalInput"
        static let resizeMessageName = "terminalResize"
        static let historyMessageName = "terminalHistory"

        private weak var session: TerminalSessionModel?
        private weak var webView: WKWebView?
        private var observerID: UUID?
        private var appearance: TerminalAppearanceSnapshot
        private var historyContext: TerminalHistoryContext?
        private var remoteContext: TerminalRemoteContextSnapshot
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
            historyVisible: Binding<Bool>
        ) {
            self.session = session
            self.appearance = appearance
            self.historyContext = historyContext
            self.remoteContext = remoteContext
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
                session?.sendInput(Data(value.utf8))
            case Self.resizeMessageName:
                guard let value = message.body as? [String: Any],
                      let columns = (value["columns"] as? NSNumber)?.intValue,
                      let rows = (value["rows"] as? NSNumber)?.intValue
                else { return }
                session?.resize(columns: columns, rows: rows)
            case Self.historyMessageName:
                handleHistoryMessage(message.body)
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
    let profile: ConnectionProfile
    let hasInstallableKey: Bool
    let isFocusMode: Bool
    let connect: (TerminalSessionModel) -> Void
    let installKey: () -> Void
    let toggleFocusMode: () -> Void
    let discoverContext: () async throws -> TerminalRemoteContextSnapshot

    @State private var showsAppearance = false
    @State private var showsHistory = false
    @State private var remoteContext = TerminalRemoteContextSnapshot.empty
    @State private var isRefreshingContext = false
    @State private var renameTabID: UUID?
    @State private var renameValue = ""

    private var session: TerminalSessionModel { workspace.selectedTab.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Встроенный SSH-терминал", systemImage: "terminal.fill")
                        .font(.headline)
                    Text("\(session.phase.title) · \(session.terminalColumns)×\(session.terminalRows)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refreshRemoteContext()
                } label: {
                    if isRefreshingContext {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "server.rack")
                    }
                }
                .disabled(isRefreshingContext || !workspace.hasRunningSession)
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
                        connect(session)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            terminalTabBar

            terminalWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 360)
                .layoutPriority(1)
                .background(TerminalColorCodecView.color(appearance.palette.background))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10))
                }

            Text(
                "Соединение выполняет системный /usr/bin/ssh внутри \(AppBrand.name). "
                    + "Пароль сервера и passphrase ключа вводятся непосредственно в терминале "
                    + "и приложением не сохраняются. История команд хранится только на этом Mac; "
                    + "строки с пробелом в начале и распространёнными признаками секретов "
                    + "автоматически пропускаются."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SSH-терминал \(profile.friendlyName)")
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
        .task(id: workspace.hasRunningSession) {
            guard workspace.hasRunningSession,
                  remoteContext.refreshedAt == nil
            else { return }
            try? await Task.sleep(for: .seconds(1))
            await loadRemoteContext()
        }
    }

    private var terminalTabBar: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs) { tab in
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
                            if !tab.isPrimary {
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
                            Button("Переименовать") {
                                renameValue = tab.title
                                renameTabID = tab.id
                            }
                            if !tab.isPrimary {
                                Divider()
                                Button("Закрыть", role: .destructive) {
                                    workspace.closeTab(tab.id)
                                }
                            }
                        }
                    }
                }
            }

            Button {
                _ = workspace.addTab()
            } label: {
                Image(systemName: "plus")
            }
            .disabled(workspace.tabs.count >= 8)
            .help("Новая независимая SSH-вкладка")

            Menu {
                ForEach(TerminalWorkspaceLayout.allCases) { layout in
                    Button {
                        workspace.setLayout(layout)
                    } label: {
                        if workspace.layout == layout {
                            Label(layout.title, systemImage: "checkmark")
                        } else {
                            Text(layout.title)
                        }
                    }
                }
                if workspace.layout != .single {
                    Divider()
                    Menu("Вторая панель") {
                        ForEach(workspace.tabs.filter { $0.id != workspace.selectedTabID }) { tab in
                            Button(tab.title) { workspace.selectSecondary(tab.id) }
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Разделение терминала")
        }
    }

    @ViewBuilder
    private var terminalWorkspace: some View {
        if workspace.layout == .splitHorizontal, let secondary = workspace.secondaryTab {
            HStack(spacing: 8) {
                terminalPane(workspace.selectedTab)
                terminalPane(secondary)
            }
        } else if workspace.layout == .splitVertical, let secondary = workspace.secondaryTab {
            VStack(spacing: 8) {
                terminalPane(workspace.selectedTab)
                terminalPane(secondary)
            }
        } else {
            terminalPane(workspace.selectedTab)
        }
    }

    private func terminalPane(_ tab: TerminalWorkspaceTab) -> some View {
        VStack(spacing: 0) {
            if workspace.layout != .single {
                HStack {
                    Text(tab.title).font(.caption.weight(.semibold))
                    Spacer()
                    Text(tab.session.phase.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { workspace.selectedTabID = tab.id }
            }
            EmbeddedTerminalWebView(
                session: tab.session,
                appearance: appearance.snapshot,
                historyContext: TerminalHistoryContext(profileID: profile.id),
                remoteContext: remoteContext,
                historyVisible: Binding(
                    get: { showsHistory && tab.id == workspace.selectedTabID },
                    set: { visible in
                        if visible { workspace.selectedTabID = tab.id }
                        showsHistory = visible
                    }
                )
            )
        }
        .overlay(alignment: .topLeading) {
            if workspace.layout != .single, tab.id == workspace.selectedTabID {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func refreshRemoteContext() {
        guard !isRefreshingContext else { return }
        Task { await loadRemoteContext() }
    }

    @MainActor
    private func loadRemoteContext() async {
        guard !isRefreshingContext else { return }
        isRefreshingContext = true
        defer { isRefreshingContext = false }
        do {
            remoteContext = try await discoverContext()
        } catch {
            remoteContext.message = error.localizedDescription
            remoteContext.suggestions = []
            remoteContext.refreshedAt = Date()
        }
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
