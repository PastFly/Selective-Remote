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

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, appearance: appearance)
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
        context.coordinator.updateSession(session)
        context.coordinator.updateAppearance(appearance)
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
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let inputMessageName = "terminalInput"
        static let resizeMessageName = "terminalResize"

        private weak var session: TerminalSessionModel?
        private weak var webView: WKWebView?
        private var observerID: UUID?
        private var appearance: TerminalAppearanceSnapshot
        private var pageReady = false
        private var pendingBase64: [String] = []
        private var writeInFlight = false

        init(
            session: TerminalSessionModel,
            appearance: TerminalAppearanceSnapshot
        ) {
            self.session = session
            self.appearance = appearance
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

        func detach() {
            detachObserver()
            webView = nil
            pageReady = false
            writeInFlight = false
            pendingBase64.removeAll()
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
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            applyAppearance()
            requestFit()
            drainOutputQueue()
            webView.evaluateJavaScript("window.selectiveTerminalFocus?.()")
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
            writeInFlight = true
            webView.evaluateJavaScript(
                "window.selectiveTerminalWriteBase64?.('\(base64)')"
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
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
    @ObservedObject var session: TerminalSessionModel
    @ObservedObject var appearance: TerminalAppearanceStore
    @ObservedObject var appAppearance: AppAppearanceStore
    let profile: ConnectionProfile
    let hasInstallableKey: Bool
    let isFocusMode: Bool
    let connect: () -> Void
    let disconnect: () -> Void
    let installKey: () -> Void
    let toggleFocusMode: () -> Void

    @State private var showsAppearance = false

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
                .disabled(!hasInstallableKey || session.isRunning)
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
                        disconnect()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Подключиться", systemImage: "play.fill") {
                        connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            EmbeddedTerminalWebView(
                session: session,
                appearance: appearance.snapshot
            )
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
                    + "и приложением не сохраняются."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SSH-терминал \(profile.friendlyName)")
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
