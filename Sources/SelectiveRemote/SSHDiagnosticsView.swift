import SwiftUI
import Foundation

struct SSHDiagnosticItem: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
    let parameters: String?
    let ok: Bool

    init(title: String, detail: String, parameters: String? = nil, ok: Bool) {
        self.title = title
        self.detail = detail
        self.parameters = parameters
        self.ok = ok
    }
}

struct SSHDiagnosticResultSnapshot: Sendable {
    let items: [SSHDiagnosticItem]
    let english: Bool

    static func completed(
        items: [SSHDiagnosticItem], startedInEnglish: Bool, currentEnglish: Bool
    ) -> Self? {
        guard startedInEnglish == currentEnglish else { return nil }
        return Self(items: items, english: startedInEnglish)
    }

    func isStale(english currentEnglish: Bool) -> Bool {
        english != currentEnglish
    }

    func visibleItems(english currentEnglish: Bool) -> [SSHDiagnosticItem] {
        isStale(english: currentEnglish) ? [] : items
    }
}

enum SSHDiagnosticCopy {
    static func localized(ru: String, en: String, english: Bool) -> String {
        english ? en : ru
    }

    static func authenticationTitle(_ mode: SSHAuthenticationMode, english: Bool) -> String {
        switch mode {
        case .automatic: localized(ru: "Автоматически", en: "Automatic", english: english)
        case .password: localized(ru: "Пароль", en: "Password", english: english)
        case .key: localized(ru: "SSH-ключ", en: "SSH key", english: english)
        case .touchIDKey: "Touch ID Key"
        case .agent: "ssh-agent / ~/.ssh/config"
        }
    }

    static func proxyTitle(_ mode: SSHProxyMode, english: Bool) -> String {
        switch mode {
        case .none: localized(ru: "Без прокси", en: "No proxy", english: english)
        case .http: "HTTP CONNECT"
        case .socks5: "SOCKS5"
        }
    }
}

struct SSHDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguageStore.shared

    let profile: ConnectionProfile
    let identity: SSHKeyRecord?
    let jumpHost: ConnectionProfile?
    @State private var snapshot: SSHDiagnosticResultSnapshot?
    @State private var running = false
    @State private var requiresManualRefresh = false

    private var visibleItems: [SSHDiagnosticItem] {
        snapshot?.visibleItems(english: language.selection.usesEnglish) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Диагностика SSH")
                        .font(.title2.bold())
                    Text("\(profile.username.isEmpty ? "SSH" : profile.username)@\(profile.host):\(profile.sshPort)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Проверить снова", systemImage: "arrow.clockwise") {
                    run()
                }
                .disabled(running)
                Button("Готово") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("w", modifiers: .command)
            }

            if running {
                ProgressView("Проверяем сеть и конфигурацию OpenSSH…")
            } else if requiresManualRefresh || snapshot?.isStale(english: language.selection.usesEnglish) == true {
                Text(UpdateLocalization.text(
                    ru: "Язык изменён. Нажмите «Проверить снова», чтобы обновить результаты диагностики.",
                    en: "Language changed. Select Check Again to refresh the diagnostic results."
                ))
                .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(visibleItems) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(item.ok ? .green : .red)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let parameters = item.parameters, !parameters.isEmpty {
                                    DisclosureGroup("Показать параметры") {
                                        Text(parameters)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 4)
                                    }
                                    .font(.caption.weight(.medium))
                                }
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
            }

            Text("Диагностика не раскрывает пароли из Keychain и не меняет конфигурацию сервера.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 480)
        .interactiveDismissDisabled(true)
        .onExitCommand {
            dismiss()
        }
        .onAppear {
            run()
        }
    }

    private func run() {
        running = true
        snapshot = nil
        requiresManualRefresh = false
        let startedInEnglish = language.selection.usesEnglish
        let profile = profile
        let identity = identity
        let jumpHost = jumpHost
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [SSHDiagnosticItem] = []
            let targetHost = profile.sshProxyMode == .none ? profile.host : profile.sshProxyHost
            let targetPort = profile.sshProxyMode == .none ? profile.sshPort : profile.sshProxyPort
            let tcp = Self.runProcess(
                "/usr/bin/nc",
                ["-z", "-G", "4", targetHost, String(targetPort)]
            )
            result.append(.init(
                title: profile.sshProxyMode == .none
                    ? SSHDiagnosticCopy.localized(ru: "TCP до SSH-сервера", en: "TCP to SSH server", english: startedInEnglish)
                    : SSHDiagnosticCopy.localized(ru: "TCP до прокси", en: "TCP to proxy", english: startedInEnglish),
                detail: tcp.status == 0
                    ? SSHDiagnosticCopy.localized(ru: "\(targetHost):\(targetPort) доступен", en: "\(targetHost):\(targetPort) is reachable", english: startedInEnglish)
                    : (tcp.output.isEmpty ? SSHDiagnosticCopy.localized(ru: "Соединение не установлено", en: "Connection failed", english: startedInEnglish) : tcp.output),
                ok: tcp.status == 0
            ))
            do {
                let settings = try SSHConnectionSettings(
                    profile: profile,
                    identity: identity,
                    jumpHost: jumpHost
                )
                let args = SSHService.interactiveSSHArguments(settings: settings)
                result.append(.init(
                    title: SSHDiagnosticCopy.localized(ru: "Конфигурация OpenSSH", en: "OpenSSH configuration", english: startedInEnglish),
                    detail: Self.configurationSummary(profile: profile, english: startedInEnglish),
                    parameters: args.joined(separator: " "),
                    ok: true
                ))
                let mode = SSHDiagnosticCopy.authenticationTitle(profile.sshAuthenticationMode, english: startedInEnglish)
                let authDetail: String
                switch profile.sshAuthenticationMode {
                case .password:
                    let saved = KeychainService.passwordExists(reference: KeychainService.credentialReference(profileID: profile.id, kind: .ssh))
                    authDetail = SSHDiagnosticCopy.localized(
                        ru: "Пароль · Keychain: \(saved ? "сохранён" : "не сохранён")",
                        en: "Password · Keychain: \(saved ? "saved" : "not saved")",
                        english: startedInEnglish
                    )
                case .key, .touchIDKey:
                    authDetail = identity.map {
                        "\(mode) · \($0.name) · \($0.fingerprint)"
                    } ?? SSHDiagnosticCopy.localized(ru: "\(mode) · ключ не выбран", en: "\(mode) · no key selected", english: startedInEnglish)
                case .agent:
                    authDetail = "ssh-agent / ~/.ssh/config"
                case .automatic:
                    authDetail = SSHDiagnosticCopy.localized(ru: "OpenSSH выберет подходящий способ автоматически", en: "OpenSSH will choose a suitable method automatically", english: startedInEnglish)
                }
                result.append(.init(
                    title: SSHDiagnosticCopy.localized(ru: "Аутентификация", en: "Authentication", english: startedInEnglish),
                    detail: authDetail,
                    ok: profile.sshAuthenticationMode == .automatic
                        || profile.sshAuthenticationMode == .agent
                        || profile.sshAuthenticationMode == .password
                        || identity != nil
                ))
                if profile.sshProxyMode != .none {
                    let saved = KeychainService.passwordExists(
                        reference: KeychainService.credentialReference(
                            profileID: profile.id,
                            kind: .proxy
                        )
                    )
                    result.append(.init(
                        title: "Proxy",
                        detail: SSHDiagnosticCopy.localized(
                            ru: "\(SSHDiagnosticCopy.proxyTitle(profile.sshProxyMode, english: false)) · \(profile.sshProxyHost):\(profile.sshProxyPort) · пользователь: \(profile.sshProxyUsername.isEmpty ? "не задан" : profile.sshProxyUsername) · пароль Keychain: \(saved ? "сохранён" : "не сохранён")",
                            en: "\(SSHDiagnosticCopy.proxyTitle(profile.sshProxyMode, english: true)) · \(profile.sshProxyHost):\(profile.sshProxyPort) · user: \(profile.sshProxyUsername.isEmpty ? "not set" : profile.sshProxyUsername) · Keychain password: \(saved ? "saved" : "not saved")",
                            english: startedInEnglish
                        ),
                        ok: tcp.status == 0
                    ))
                }
            } catch {
                result.append(.init(
                    title: SSHDiagnosticCopy.localized(ru: "Конфигурация SSH", en: "SSH configuration", english: startedInEnglish),
                    detail: error.localizedDescription,
                    ok: false
                ))
            }
            DispatchQueue.main.async {
                self.snapshot = SSHDiagnosticResultSnapshot.completed(
                    items: result,
                    startedInEnglish: startedInEnglish,
                    currentEnglish: self.language.selection.usesEnglish
                )
                self.requiresManualRefresh = self.snapshot == nil
                self.running = false
            }
        }
    }

    private nonisolated static func configurationSummary(
        profile: ConnectionProfile,
        english: Bool
    ) -> String {
        let proxy = profile.sshProxyMode == .none
            ? SSHDiagnosticCopy.localized(ru: "без прокси", en: "without proxy", english: english)
            : SSHDiagnosticCopy.localized(ru: "через \(SSHDiagnosticCopy.proxyTitle(profile.sshProxyMode, english: false))", en: "via \(SSHDiagnosticCopy.proxyTitle(profile.sshProxyMode, english: true))", english: english)
        let authentication: String
        switch profile.sshAuthenticationMode {
        case .automatic:
            authentication = SSHDiagnosticCopy.localized(ru: "автоматическая аутентификация", en: "automatic authentication", english: english)
        case .password:
            authentication = SSHDiagnosticCopy.localized(ru: "аутентификация по паролю", en: "password authentication", english: english)
        case .key:
            authentication = SSHDiagnosticCopy.localized(ru: "аутентификация по SSH-ключу", en: "SSH key authentication", english: english)
        case .touchIDKey:
            authentication = SSHDiagnosticCopy.localized(ru: "SSH-ключ с Touch ID", en: "SSH key with Touch ID", english: english)
        case .agent:
            authentication = "ssh-agent / ~/.ssh/config"
        }
        return SSHDiagnosticCopy.localized(ru: "Порт \(profile.sshPort) · \(proxy) · \(authentication)", en: "Port \(profile.sshPort) · \(proxy) · \(authentication)", english: english)
    }

    private nonisolated static func runProcess(
        _ path: String,
        _ arguments: [String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (255, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }
}
