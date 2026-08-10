import AppKit
import SwiftUI

struct SSHKeyGenerationView: View {
    @Environment(\.dismiss) private var dismiss
    let generate: (SSHKeyGenerationRequest, TerminalSessionModel) -> Bool

    @StateObject private var terminal = TerminalSessionModel()
    @StateObject private var appearance = TerminalAppearanceStore()
    @State private var algorithm = SSHKeyAlgorithm.ed25519
    @State private var path = SSHKeyService.defaultPrivateKeyPath(for: .ed25519)
    @State private var comment = "\(NSUserName())@SelectiveRemote"
    @State private var generationStarted = false

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
                Form {
                    Picker("Алгоритм", selection: $algorithm) {
                        ForEach(SSHKeyAlgorithm.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.radioGroup)

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
                .formStyle(.grouped)

                Label(
                    "После запуска в отдельном терминале дважды появится безопасный запрос "
                        + "passphrase. Можно нажать Enter два раза, чтобы создать ключ без "
                        + "passphrase.",
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
                            comment: comment
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
