import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showsExport = false
    @State private var importRequest: BackupImportRequest?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Полная резервная копия") {
                Label(
                    "Архив защищён отдельным паролем и содержит выбранные локальные данные.",
                    systemImage: "lock.doc.fill"
                )
                Text("По умолчанию включены профили, настройки, Snippets, Keychain, приватные SSH/CA-ключи, Session Logs и журнал подключений.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Создать зашифрованный архив…", systemImage: "archivebox") {
                    showsExport = true
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Восстановление") {
                Text("Перед восстановлением Selective Remote проверяет пароль и целостность всех вложений, а затем создаёт зашифрованный rollback-архив текущего состояния.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Проверить и восстановить архив…", systemImage: "arrow.counterclockwise") {
                    chooseArchive()
                }
                .disabled(hasActiveSessions)
                if hasActiveSessions {
                    Label(
                        "Перед восстановлением закройте активные RDP, SSH, SFTP, Terminal и туннели.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Криптография") {
                LabeledContent("Шифрование", value: "AES-256-GCM")
                LabeledContent("Получение ключа", value: "PBKDF2-HMAC-SHA256 · 600 000")
                Text("Пароль архива не сохраняется. Без него восстановить Keychain и приватные ключи невозможно.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsExport) {
            BackupExportSheet { result in
                showsExport = false
                message = result
            }
        }
        .sheet(item: $importRequest) { request in
            BackupImportSheet(request: request) { result in
                importRequest = nil
                message = result
            }
        }
        .alert("Backup & Restore", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var hasActiveSessions: Bool {
        model.runningSessionCount > 0
            || model.runningSSHTerminalCount > 0
            || model.runningLocalTerminalCount > 0
            || model.runningSSHTunnelCount > 0
            || model.sftpWorkspace.activeRemoteCount > 0
            || model.sftpWorkspace.activeTransferCount > 0
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "Выберите архив Selective Remote"
        panel.prompt = "Выбрать"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "srbackup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRequest = BackupImportRequest(url: url)
    }
}

private struct BackupImportRequest: Identifiable {
    let id = UUID()
    let url: URL
}

private struct BackupExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: (String) -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @State private var revealsPassword = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Зашифрованная резервная копия", systemImage: "lock.doc.fill")
                .font(.title2.bold())
            Text("Придумайте отдельный пароль длиной не менее 12 символов. Он потребуется на другом Mac и не сохраняется в Keychain.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Содержимое") {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Профили, группы, Snippets, туннели и настройки", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Label("Пароли и другие записи Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Label("Приватные SSH-ключи и SSH CA", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Label("Session Logs", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Label("Журнал подключений", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            passwordFields

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Отмена") { dismiss() }
                    .disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Создать архив…", systemImage: "archivebox") {
                    export()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport || busy)
            }
        }
        .padding(22)
        .frame(width: 590)
    }

    @ViewBuilder
    private var passwordFields: some View {
        GroupBox("Пароль архива") {
            VStack(alignment: .leading, spacing: 10) {
                if revealsPassword {
                    TextField("Пароль", text: $password)
                    TextField("Повторите пароль", text: $confirmation)
                } else {
                    SecureField("Пароль", text: $password)
                    SecureField("Повторите пароль", text: $confirmation)
                }
                Toggle("Показать пароль", isOn: $revealsPassword)
                    .font(.caption)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)
        }
    }

    private var canExport: Bool {
        password.count >= 12 && password == confirmation
    }

    private func export() {
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await KeychainService.authenticateDeviceOwner(
                    reason: "Создать полную зашифрованную резервную копию Selective Remote"
                )
                let panel = NSSavePanel()
                panel.title = "Сохранить зашифрованную резервную копию"
                panel.prompt = "Сохранить"
                panel.nameFieldStringValue = "Selective-Remote-Backup.srbackup"
                panel.allowedContentTypes = [UTType(filenameExtension: "srbackup") ?? .data]
                guard panel.runModal() == .OK, let url = panel.url else {
                    busy = false
                    return
                }
                let summary = try SelectiveRemoteBackupService.shared.exportArchive(
                    to: url,
                    password: password,
                    options: .full
                )
                password = ""
                confirmation = ""
                onComplete("Архив создан: \(url.lastPathComponent)\nПрофилей: \(summary.profileCount), секретов: \(summary.credentialCount), приватных ключей: \(summary.privateKeyCount), Session Logs: \(summary.sessionLogCount).")
            } catch {
                errorMessage = error.localizedDescription
                busy = false
            }
        }
    }
}

private struct BackupImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: BackupImportRequest
    let onComplete: (String) -> Void

    @State private var password = ""
    @State private var revealsPassword = false
    @State private var inspection: SelectiveRemoteBackupInspection?
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Проверка резервной копии", systemImage: "checkmark.shield")
                .font(.title2.bold())
            Text(request.url.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            GroupBox("Пароль архива") {
                VStack(alignment: .leading, spacing: 10) {
                    if revealsPassword {
                        TextField("Пароль", text: $password)
                    } else {
                        SecureField("Пароль", text: $password)
                    }
                    Toggle("Показать пароль", isOn: $revealsPassword)
                        .font(.caption)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 4)
            }

            if let inspection {
                BackupSummaryView(summary: inspection.summary)
                Label(
                    "Восстановление заменит локальные данные содержимым архива. Перед заменой автоматически создаётся rollback-архив с тем же паролем.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Отмена") { dismiss() }
                    .disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if inspection == nil {
                    Button("Проверить архив", systemImage: "checkmark.shield") {
                        inspect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.count < 12 || busy)
                } else {
                    Button("Восстановить", systemImage: "arrow.counterclockwise", role: .destructive) {
                        restore()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
            }
        }
        .padding(22)
        .frame(width: 590)
    }

    private func inspect() {
        busy = true
        errorMessage = nil
        do {
            inspection = try SelectiveRemoteBackupService.shared.inspectArchive(
                at: request.url,
                password: password
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }

    private func restore() {
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await KeychainService.authenticateDeviceOwner(
                    reason: "Восстановить секреты и приватные ключи Selective Remote"
                )
                let result = try SelectiveRemoteBackupService.shared.restoreArchive(
                    at: request.url,
                    password: password
                )
                password = ""
                onComplete("Данные восстановлены. Перезапустите Selective Remote, чтобы применить профили и настройки.\nRollback: \(result.rollbackURL.path)")
            } catch {
                errorMessage = error.localizedDescription
                busy = false
            }
        }
    }
}

private struct BackupSummaryView: View {
    let summary: SelectiveRemoteBackupSummary

    var body: some View {
        GroupBox("Содержимое архива") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                row("Создан", summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                row("Версия", summary.appVersion)
                row("Профили", String(summary.profileCount))
                row("Snippets", String(summary.snippetCount))
                row("Секреты Keychain", String(summary.credentialCount))
                row("Приватные ключи", String(summary.privateKeyCount))
                row("Session Logs", String(summary.sessionLogCount))
                row("Журнал подключений", String(summary.activityLogCount))
                row("Размер файлов", ByteCountFormatter.string(fromByteCount: summary.totalFileBytes, countStyle: .file))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
