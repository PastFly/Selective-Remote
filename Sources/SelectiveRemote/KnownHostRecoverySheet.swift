import AppKit
import SwiftUI

struct KnownHostRecoverySheet: View {
    let candidate: SSHKnownHostRecoveryCandidate
    let isWorking: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var independentlyVerified = false

    private var isJumpHost: Bool { candidate.role == .jumpHost }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                isJumpHost
                    ? UpdateLocalization.text(ru: "Изменился ключ Jump Host", en: "Jump Host key changed")
                    : UpdateLocalization.text(ru: "Изменился ключ конечного Host", en: "Destination Host key changed"),
                systemImage: "exclamationmark.shield"
            )
            .font(.title2.weight(.semibold))

            Text(UpdateLocalization.text(
                ru: "Соединение остановлено: сохранённый ключ не совпадает с ключом сервера. Переустановка сервера может изменить ключ, но такое же предупреждение бывает при подмене соединения.",
                en: "The connection stopped because the saved key differs from the server key. A server reinstall can change its key, but the same warning can indicate interception."
            ))
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                detail(
                    UpdateLocalization.text(ru: "Узел", en: "Endpoint"),
                    candidate.endpoint
                )
                detail(
                    UpdateLocalization.text(ru: "Алгоритм", en: "Algorithm"),
                    candidate.originalEntry.algorithm
                )
                detail(
                    UpdateLocalization.text(ru: "Сохранённый fingerprint", en: "Saved fingerprint"),
                    candidate.oldFingerprint
                )
                detail(
                    UpdateLocalization.text(ru: "Новый fingerprint", en: "New observed fingerprint"),
                    candidate.newFingerprint
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            Text(UpdateLocalization.text(
                ru: "Сверьте новый fingerprint через независимый доверенный канал с администратором сервера. Проверка сети приложением не подтверждает личность сервера.",
                en: "Verify the new fingerprint with the server administrator through an independent trusted channel. A network scan by this app does not prove server identity."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                UpdateLocalization.text(
                    ru: "Я независимо проверил новый fingerprint",
                    en: "I independently verified the new fingerprint"
                ),
                isOn: $independentlyVerified
            )
            .disabled(isWorking)

            HStack {
                Button(UpdateLocalization.text(ru: "Копировать fingerprints", en: "Copy fingerprints")) {
                    let text = "\(candidate.endpoint)\n\(candidate.originalEntry.algorithm)\nOld: \(candidate.oldFingerprint)\nNew: \(candidate.newFingerprint)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(
                    isWorking
                        ? UpdateLocalization.text(ru: "Повторная проверка…", en: "Checking again…")
                        : UpdateLocalization.text(ru: "Заменить ключ и повторить", en: "Replace key and retry"),
                    action: onConfirm
                )
                .disabled(!independentlyVerified || isWorking)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620)
        .interactiveDismissDisabled(isWorking)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("\(label): \(value)")
        }
    }
}
