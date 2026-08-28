import SwiftUI

struct CloudSettingsView: View {
    @AppStorage("SelectiveRemote.cloud.endpoint.v1")
    private var endpoint = SelectiveRemoteCloudEndpoint.production

    @State private var phase = Phase.idle
    @State private var metadata: SelectiveRemoteCloudMetadata?
    @State private var errorMessage: String?

    private let client = SelectiveRemoteCloudAPIClient()

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selective Remote Cloud")
                            .font(.headline)
                        Text(UpdateLocalization.text(
                            ru: "Необязательная сквозная синхронизация. Локальный режим продолжает работать без аккаунта.",
                            en: "Optional end-to-end encrypted sync. Local mode continues to work without an account."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "cloud.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Section(UpdateLocalization.text(ru: "Сервер", en: "Server")) {
                TextField("https://cloud.pastfly.ru", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { checkConnection() }

                HStack {
                    statusLabel
                    Spacer()
                    Button(UpdateLocalization.text(ru: "Проверить соединение", en: "Check Connection"), systemImage: "network") {
                        checkConnection()
                    }
                    .disabled(phase == .checking)
                }

                Text(UpdateLocalization.text(
                    ru: "Адрес сохраняется только на этом Mac. В production разрешён только HTTPS.",
                    en: "The address is stored only on this Mac. Production endpoints must use HTTPS."
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Section(UpdateLocalization.text(ru: "Аккаунт и Vault", en: "Account & Vault")) {
                LabeledContent(UpdateLocalization.text(ru: "Состояние", en: "Status")) {
                    Text(UpdateLocalization.text(
                        ru: "Не подключён",
                        en: "Not connected"
                    ))
                    .foregroundStyle(.secondary)
                }
                LabeledContent("API") {
                    Text(metadata.map { "v\($0.apiVersion)" } ?? "—")
                        .monospacedDigit()
                }
                LabeledContent(UpdateLocalization.text(ru: "Схема Vault", en: "Vault Schema")) {
                    Text(metadata.map { "v\($0.vaultSchemaVersion)" } ?? "—")
                        .monospacedDigit()
                }

                Button(UpdateLocalization.text(ru: "Войти в Selective Remote Cloud…", en: "Sign In to Selective Remote Cloud…"), systemImage: "person.crop.circle.badge.checkmark") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)

                Text(UpdateLocalization.text(
                    ru: "Вход будет включён после развёртывания API и проверки первого зашифрованного обмена. Пароль аккаунта не используется как ключ Vault.",
                    en: "Sign-in will be enabled after the API is deployed and the first encrypted exchange is verified. The account password is not used as the Vault key."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section(UpdateLocalization.text(ru: "Конфиденциальность", en: "Privacy")) {
                Label(
                    UpdateLocalization.text(
                        ru: "Шифрование выполняется на устройстве до отправки.",
                        en: "Encryption happens on the device before upload."
                    ),
                    systemImage: "lock.shield.fill"
                )
                Label(
                    UpdateLocalization.text(
                        ru: "Сервер хранит только ciphertext и историю ревизий.",
                        en: "The server stores only ciphertext and revision history."
                    ),
                    systemImage: "server.rack"
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch phase {
        case .idle:
            Label(UpdateLocalization.text(ru: "Не проверено", en: "Not checked"), systemImage: "circle")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(UpdateLocalization.text(ru: "Проверка…", en: "Checking…"))
            }
            .foregroundStyle(.secondary)
        case .available:
            Label(UpdateLocalization.text(ru: "Сервис доступен", en: "Service available"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label(errorMessage ?? UpdateLocalization.text(ru: "Недоступен", en: "Unavailable"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private func checkConnection() {
        phase = .checking
        metadata = nil
        errorMessage = nil
        Task { @MainActor in
            do {
                let url = try SelectiveRemoteCloudEndpoint.normalized(endpoint)
                endpoint = url.absoluteString
                metadata = try await client.metadata(endpoint: url)
                phase = .available
            } catch {
                errorMessage = error.localizedDescription
                phase = .failed
            }
        }
    }

    private enum Phase {
        case idle
        case checking
        case available
        case failed
    }
}
