import SwiftUI

struct UpdateExperiencePopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let manifest = model.availableUpdateManifest {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Доступно обновление \(manifest.version)")
                            .font(.headline)
                        Text("Установка выполняется только после подтверждения пользователя.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.isDownloadingUpdate {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: model.updateDownloadProgress)
                        Text("Загрузка и проверка SHA-256 · \(Int(model.updateDownloadProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if model.downloadedUpdateDMGURL != nil {
                    Label("DMG загружен и проверен", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let error = model.updateInstallError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(
                    "Автоматически загружать обновления",
                    isOn: $model.automaticallyDownloadUpdates
                )
                .disabled(model.isDownloadingUpdate)

                Divider()

                HStack(spacing: 8) {
                    Button("Что нового") {
                        model.openAvailableReleaseNotes()
                    }
                    if model.downloadedUpdateDMGURL == nil {
                        Button("Загрузить обновление") {
                            model.downloadAvailableUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDownloadingUpdate)
                    } else {
                        Button("Установить и перезапустить") {
                            model.installDownloadedUpdateAndRestart()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Показать DMG") {
                            model.revealDownloadedUpdate()
                        }
                    }
                }

                Text("Selective Remote не использует sudo и не выполняет silent replacement. Если папка приложения недоступна для записи, будет предложена ручная замена из подключённого DMG.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.isCheckingForUpdates {
                ProgressView("Проверяем обновления…")
            } else {
                Text("Новых обновлений нет")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            model.markAvailableUpdateSeen()
        }
    }
}
