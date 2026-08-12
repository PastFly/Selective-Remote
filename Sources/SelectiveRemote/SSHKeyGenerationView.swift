import AppKit
import SwiftUI

struct SSHKeyGenerationView: View {
    @Environment(\.dismiss) private var dismiss
    let generate: (SSHKeyGenerationRequest, TerminalSessionModel) -> Bool

    @StateObject private var terminal = TerminalSessionModel()
    @StateObject private var appearance = TerminalAppearanceStore()
    @State private var algorithm: SSHKeyAlgorithm
    @State private var path: String
    @State private var comment = "\(NSUserName())@SelectiveRemote"
    @State private var protectUseWithUserPresence = true
    @State private var generationStarted = false

    init(
        touchIDPreset: Bool = false,
        generate: @escaping (SSHKeyGenerationRequest, TerminalSessionModel) -> Bool
    ) {
        self.generate = generate
        let initial: SSHKeyAlgorithm = touchIDPreset ? .ecdsaP256TouchID : .ed25519
        _algorithm = State(initialValue: initial)
        _path = State(initialValue: SSHKeyService.defaultPrivateKeyPath(for: initial))
        _protectUseWithUserPresence = State(initialValue: touchIDPreset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Новый SSH-ключ")
                        .font(.title2.bold())
                    Text("Приватный ключ остаётся только на этом Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if generationStarted {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(terminal.phase.title, systemImage: "terminal.fill")
                            .font(.headline)
                        Spacer()
                        if terminal.isRunning {
                            Button("Остановить", systemImage: "stop.fill", role: .destructive) {
                                terminal.stop()
                            }
                        } else {
                            Button("Готово") {
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                    }

                    EmbeddedTerminalWebView(
                        session: terminal,
                        appearance: appearance.snapshot
                    )
                        .frame(minHeight: 420)
                        .background(Color(red: 0.063, green: 0.075, blue: 0.102))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10))
                        }

                    Text(
                        "Это отдельный служебный терминал. Основная SSH-сессия может "
                            + "продолжать работать параллельно."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "key.horizontal.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 42, height: 42)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SSH ID")
                                .font(.headline)
                            Text("Ed25519 рекомендуется для новых подключений")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Алгоритм", selection: $algorithm) {
                        ForEach(SSHKeyAlgorithm.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Файл") {
                        HStack {
                            TextField("Путь приватного ключа", text: $path)
                                .textFieldStyle(.roundedBorder)
                            Button("Выбрать…") { chooseDestination() }
                        }
                    }
                    LabeledContent("Комментарий") {
                        TextField("user@host", text: $comment)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $protectUseWithUserPresence) {
                        Label("Touch ID перед использованием ключа", systemImage: "touchid")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)
                    Text(algorithm == .ecdsaP256TouchID
                        ? "Touch ID Key создаётся как ECDSA P-256 SSH-ключ без passphrase. Selective Remote не загружает его в ssh-agent и перед каждым использованием требует Touch ID."
                        : "Перед использованием выбранного приватного ключа Selective Remote запросит Touch ID; пароль пользователя Mac не используется как fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

                Label(
                    algorithm == .ecdsaP256TouchID
                        ? "Для Touch ID Key passphrase не запрашивается: подтверждение выполняет Touch ID перед запуском OpenSSH."
                        : "Passphrase ключа остаётся отдельной защитой OpenSSH. В служебном терминале можно задать её или нажать Enter два раза, чтобы оставить ключ без passphrase.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }
                    Button("Создать в отдельном терминале") {
                        let request = SSHKeyGenerationRequest(
                            algorithm: algorithm,
                            path: path,
                            comment: comment,
                            protectUseWithUserPresence: protectUseWithUserPresence
                        )
                        if generate(request, terminal) {
                            generationStarted = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: generationStarted ? 760 : 640)
        .interactiveDismissDisabled(terminal.isRunning)
        .onChange(of: algorithm) { oldValue, newValue in
            let oldDefault = SSHKeyService.defaultPrivateKeyPath(for: oldValue)
            if path == oldDefault {
                path = SSHKeyService.defaultPrivateKeyPath(for: newValue)
            }
            if newValue == .ecdsaP256TouchID {
                protectUseWithUserPresence = true
            }
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Сохранить новый приватный SSH-ключ"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = algorithm.defaultFilename
        let current = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
