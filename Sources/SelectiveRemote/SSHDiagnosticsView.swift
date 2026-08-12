import SwiftUI
import Foundation

private struct SSHDiagnosticItem: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
    let ok: Bool
}

struct SSHDiagnosticsView: View {
    let profile: ConnectionProfile
    let identity: SSHKeyRecord?
    @State private var items: [SSHDiagnosticItem] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Диагностика SSH").font(.title2.bold())
                    Text("\(profile.username.isEmpty ? "SSH" : profile.username)@\(profile.host):\(profile.sshPort)")
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Проверить снова", systemImage: "arrow.clockwise") { run() }
                    .disabled(running)
            }

            if running { ProgressView("Проверяем сеть и конфигурацию OpenSSH…") }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(item.ok ? .green : .red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            Text("Диагностика не раскрывает пароли из Keychain и не меняет конфигурацию сервера.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 680, minHeight: 480)
        .onAppear { run() }
    }

    private func run() {
        running = true
        items = []
        let profile = profile
        let identity = identity
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [SSHDiagnosticItem] = []
            let targetHost = profile.sshProxyMode == .none ? profile.host : profile.sshProxyHost
            let targetPort = profile.sshProxyMode == .none ? profile.sshPort : profile.sshProxyPort
            let tcp = Self.runProcess("/usr/bin/nc", ["-z", "-G", "4", targetHost, String(targetPort)])
            result.append(.init(
                title: profile.sshProxyMode == .none ? "TCP до SSH-сервера" : "TCP до прокси",
                detail: tcp.status == 0 ? "\(targetHost):\(targetPort) доступен" : (tcp.output.isEmpty ? "Соединение не установлено" : tcp.output),
                ok: tcp.status == 0
            ))
            do {
                let settings = try SSHConnectionSettings(profile: profile, identity: identity)
                let args = SSHService.interactiveSSHArguments(settings: settings)
                result.append(.init(title: "Конфигурация OpenSSH", detail: args.joined(separator: " "), ok: true))
                let mode = profile.sshAuthenticationMode.title
                let authDetail: String
                switch profile.sshAuthenticationMode {
                case .password: authDetail = "Пароль · Keychain: \(KeychainService.passwordExists(reference: KeychainService.credentialReference(profileID: profile.id, kind: .ssh)) ? "сохранён" : "не сохранён")"
                case .key, .touchIDKey: authDetail = identity.map { "\(mode) · \($0.name) · \($0.fingerprint)" } ?? "\(mode) · ключ не выбран"
                case .agent: authDetail = "ssh-agent / ~/.ssh/config"
                case .automatic: authDetail = "OpenSSH выберет подходящий способ автоматически"
                }
                result.append(.init(title: "Аутентификация", detail: authDetail, ok: profile.sshAuthenticationMode == .automatic || profile.sshAuthenticationMode == .agent || profile.sshAuthenticationMode == .password || identity != nil))
                if profile.sshProxyMode != .none {
                    let saved = KeychainService.passwordExists(reference: KeychainService.credentialReference(profileID: profile.id, kind: .proxy))
                    result.append(.init(title: "Proxy", detail: "\(profile.sshProxyMode.title) · \(profile.sshProxyHost):\(profile.sshProxyPort) · пользователь: \(profile.sshProxyUsername.isEmpty ? "не задан" : profile.sshProxyUsername) · пароль Keychain: \(saved ? "сохранён" : "не сохранён")", ok: tcp.status == 0))
                }
            } catch {
                result.append(.init(title: "Конфигурация SSH", detail: error.localizedDescription, ok: false))
            }
            DispatchQueue.main.async { self.items = result; self.running = false }
        }
    }

    private nonisolated static func runProcess(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (255, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
