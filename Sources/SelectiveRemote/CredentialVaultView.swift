import SwiftUI

struct CredentialVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var selectedKeyID: UUID?
    @State private var showsKeyGenerator = false

    private var selectedKey: SSHKeyRecord? {
        guard let selectedKeyID else { return model.sshKeys.first }
        return model.sshKeys.first(where: { $0.id == selectedKeyID })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keychain и SSH-ключи")
                        .font(.title2.bold())
                    Text("SSH-пароли и passphrase хранятся через Keychain; приватные SSH-ключи остаются файлами в ~/.ssh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SSH-ключи")
                        .font(.headline)
                    List(selection: $selectedKeyID) {
                        ForEach(model.sshKeys) { key in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(key.name)
                                Text("\(key.algorithm) · \(key.fingerprint)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(key.id)
                        }
                    }
                    HStack {
                        Button("Добавить…", systemImage: "plus") {
                            model.importSSHKey()
                            selectedKeyID = model.selectedSSHKey?.id ?? model.sshKeys.last?.id
                        }
                        Button("Создать…", systemImage: "key.horizontal") {
                            showsKeyGenerator = true
                        }
                        .disabled(model.selectedProfile.connectionType != .ssh)
                        Spacer()
                        Button(role: .destructive) {
                            guard let id = selectedKey?.id else { return }
                            model.removeSSHKey(id)
                            selectedKeyID = model.sshKeys.first?.id
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedKey == nil)
                    }
                }
                .padding(18)
                .frame(minWidth: 270)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        currentProfileCredentials
                        if let key = selectedKey {
                            keyDetails(key)
                        } else {
                            ContentUnavailableView(
                                "SSH-ключи не добавлены",
                                systemImage: "key.slash",
                                description: Text(
                                    "Добавьте существующий приватный ключ или создайте новый. "
                                        + "\(AppBrand.name) сохранит путь и отпечаток."
                                )
                            )
                            .frame(maxWidth: .infinity, minHeight: 280)
                        }
                    }
                    .padding(20)
                }
                .frame(minWidth: 470)
            }
        }
        .frame(minWidth: 820, minHeight: 590)
        .onAppear {
            selectedKeyID = model.selectedSSHKey?.id ?? model.sshKeys.first?.id
        }
        .sheet(isPresented: $showsKeyGenerator) {
            SSHKeyGenerationView { request, session in
                model.generateSSHKey(request, session: session)
            }
        }
    }

    private var currentProfileCredentials: some View {
        GroupBox("Текущий профиль: \(model.selectedProfile.friendlyName)") {
            VStack(alignment: .leading, spacing: 8) {
                if model.selectedProfile.connectionType == .rdp {
                    credentialStatus(
                        "Пароль RDP",
                        stored: model.selectedProfileHasSavedPassword
                    )
                    credentialStatus(
                        "Пароль RD Gateway",
                        stored: model.selectedProfileHasSavedGatewayPassword
                    )
                    Text("Удаление и замена паролей доступны на вкладке «Основные».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        model.selectedSSHKey.map { "Выбран ключ «\($0.name)»" }
                            ?? "Используются ~/.ssh/config и ключи ssh-agent",
                        systemImage: "terminal"
                    )
                    credentialStatus(
                        "Пароль SSH",
                        stored: model.selectedProfileHasSavedSSHPassword
                    )
                    Text(
                        model.selectedSSHPasswordRequiresUserPresence
                            ? "Доступ к сохранённому SSH-паролю подтверждается только Touch ID."
                            : "Сохранённый SSH-пароль доступен Terminal, SFTP и Forwarding через Keychain."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if model.selectedProfileHasSavedSSHPassword {
                        Button("Исправить доступ к SSH-паролю", systemImage: "wrench.and.screwdriver") {
                            model.repairSelectedSSHCredentialAccess()
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func keyDetails(_ key: SSHKeyRecord) -> some View {
        GroupBox("Параметры ключа") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Название")
                    TextField(
                        "Название ключа",
                        text: Binding(
                            get: { key.name },
                            set: { value in
                                var updated = key
                                updated.name = value
                                model.updateSSHKey(updated)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Алгоритм")
                    Text(key.algorithm)
                }
                GridRow {
                    Text("Fingerprint")
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Файл")
                    Text(key.privateKeyPath)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }

        GroupBox("SSH-ключ, passphrase и ssh-agent") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Добавить в ssh-agent и Keychain", systemImage: "plus.circle") {
                        model.addSSHKeyToAgent(key.id)
                    }

                    Button("Удалить из agent и Keychain", role: .destructive) {
                        model.removeSSHKeyFromAgentAndKeychain(key.id)
                    }
                }

                HStack {
                    Button("Убрать из ssh-agent", systemImage: "minus.circle") {
                        model.removeSSHKeyFromAgent(key.id)
                    }
                    Button("Установить на сервер", systemImage: "arrow.up.to.line") {
                        model.mutateSelectedProfile { $0.sshIdentityID = key.id }
                        model.installSelectedSSHPublicKey()
                        dismiss()
                    }
                    .disabled(
                        model.selectedProfile.connectionType != .ssh
                            || key.publicKeyPath == nil
                            || model.isSelectedSSHTerminalRunning
                    )
                    Spacer()
                    Button("Показать в Finder") { model.revealSSHKey(key.id) }
                    Button("Копировать .pub") { model.copySSHPublicKey(key.id) }
                        .disabled(key.publicKeyPath == nil)
                }

                Label(
                    model.hasSavedSSHKeyPassphrase(keyID: key.id)
                        ? "Ключ настроен через Apple OpenSSH Keychain"
                        : "Ключ ещё не добавлялся через Apple OpenSSH",
                    systemImage: model.hasSavedSSHKeyPassphrase(keyID: key.id)
                        ? "checkmark.shield.fill"
                        : "shield"
                )
                .font(.caption)
                .foregroundStyle(
                    model.hasSavedSSHKeyPassphrase(keyID: key.id) ? Color.green : Color.secondary
                )

                Text(
                    "Приватный ключ остаётся в файле ~/.ssh и не попадает в Keychain. "
                        + "В Keychain Apple OpenSSH может хранить только passphrase. "
                        + "Если в карточке профиля включён Touch ID, Selective Remote отдельно подтверждает использование ключа через биометрию."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func credentialStatus(_ title: String, stored: Bool) -> some View {
        Label(
            "\(title): \(stored ? "сохранён" : "не сохранён")",
            systemImage: stored ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(stored ? Color.green : Color.secondary)
    }
}
