import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var appearance: AppAppearanceStore
    @ObservedObject var appLock: AppLockStore

    var body: some View {
        TabView {
            Form {
                AppAppearanceSettingsSection(store: appearance)
                Section {
                    Button("Сбросить оформление") { appearance.reset() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Оформление", systemImage: "paintpalette") }

            UpdateSettingsView(model: model)
                .tabItem { Label("Обновления", systemImage: "arrow.down.circle") }

            AppLockSettingsView(store: appLock)
                .tabItem { Label("Безопасность", systemImage: "lock.shield") }
        }
        .frame(width: 610, height: 520)
        .background {
            AppWindowBackdrop(appearance: appearance.snapshot)
                .ignoresSafeArea()
        }
        .preferredColorScheme(appearance.theme.colorScheme)
        .appTextSize(appearance.textSize)
        .controlSize(appearance.density.controlSize)
    }
}

private struct UpdateSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Версия приложения") {
                LabeledContent("Установлено") {
                    Text(AppBuildInfo.fullText).monospacedDigit()
                }
                if let manifest = model.availableUpdateManifest {
                    LabeledContent("Доступно") {
                        Text(manifest.version)
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    LabeledContent("Состояние") {
                        Label(
                            model.isCheckingForUpdates ? "Проверка…" : "Установлена актуальная версия",
                            systemImage: model.isCheckingForUpdates
                                ? "arrow.triangle.2.circlepath"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(model.isCheckingForUpdates ? Color.secondary : Color.green)
                    }
                }
                LabeledContent("Последняя проверка") {
                    Text(lastCheckText).foregroundStyle(.secondary)
                }
            }

            Section("Автоматизация") {
                Toggle("Проверять обновления при запуске и каждые 5 часов", isOn: $model.automaticallyCheckForUpdates)
                Toggle("Автоматически загружать найденные обновления", isOn: $model.automaticallyDownloadUpdates)
                    .disabled(!model.automaticallyCheckForUpdates)
            }

            Section("Действия") {
                HStack {
                    Button("Проверить сейчас", systemImage: "arrow.clockwise") {
                        model.checkForUpdatesFromSettings()
                    }
                    .disabled(model.isCheckingForUpdates)
                    Spacer()
                    if model.availableUpdateManifest != nil {
                        Button("Что нового") { model.openAvailableReleaseNotes() }
                    } else {
                        Button("История версий") { model.openInstalledReleaseNotes() }
                    }
                }
                if model.availableUpdateManifest != nil {
                    UpdateExperiencePopover(model: model)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckText: String {
        guard let date = model.lastSuccessfulUpdateCheckDate else { return "Ещё не выполнялась" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct UpdateExperiencePopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let manifest = model.availableUpdateManifest {
                updateHeader(manifest)
                updateProgress(manifest)

                if let error = model.updateInstallError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }

                Toggle(
                    "Автоматически загружать обновления",
                    isOn: $model.automaticallyDownloadUpdates
                )
                .disabled(model.isDownloadingUpdate || model.updateDownloadStage == .installing)

                Divider()

                HStack(spacing: 8) {
                    Button("Что нового") {
                        model.openAvailableReleaseNotes()
                    }
                    Spacer()
                    if model.downloadedUpdateDMGURL == nil {
                        Button("Загрузить обновление") {
                            model.downloadAvailableUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDownloadingUpdate)
                    } else {
                        Button("Показать DMG") {
                            model.revealDownloadedUpdate()
                        }
                        Button("Установить и перезапустить") {
                            model.installDownloadedUpdateAndRestart()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.updateDownloadStage == .installing)
                    }
                }

                HStack {
                    Image(systemName: "clock")
                    Text(lastCheckText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text(UpdateLocalization.text(
                    ru: "Selective Remote не использует sudo и не выполняет silent replacement. Если папка приложения недоступна для записи, будет предложена ручная замена из подключённого DMG.",
                    en: "Selective Remote does not use sudo or perform a silent replacement. If the application folder is not writable, Finder will be opened for a manual replacement from the mounted DMG."
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if model.isCheckingForUpdates {
                ProgressView("Проверяем обновления…")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Новых обновлений нет", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(lastCheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Что нового") {
                            model.openInstalledReleaseNotes()
                        }
                        Spacer()
                        Button("Проверить сейчас", systemImage: "arrow.clockwise") {
                            model.checkForUpdates()
                        }
                        .disabled(model.isCheckingForUpdates)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 430)
        .onAppear {
            model.markAvailableUpdateSeen()
        }
    }

    private func updateHeader(_ manifest: SelectiveRemoteUpdateManifest) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 6) {
                Text(UpdateLocalization.text(
                    ru: "Доступно обновление \(manifest.version)",
                    en: "Update \(manifest.version) is available"
                ))
                .font(.headline)

                HStack(spacing: 8) {
                    versionPill(
                        UpdateLocalization.text(ru: "Установлено", en: "Installed"),
                        AppBuildInfo.version,
                        emphasized: false
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    versionPill(
                        UpdateLocalization.text(ru: "Доступно", en: "Available"),
                        manifest.version,
                        emphasized: true
                    )
                }
            }
            Spacer()
        }
    }

    private func versionPill(
        _ title: String,
        _ version: String,
        emphasized: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(version).monospacedDigit().fontWeight(.semibold)
        }
        .font(.caption2)
        .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            emphasized ? Color.accentColor.opacity(0.11) : Color.secondary.opacity(0.09),
            in: Capsule()
        )
    }

    private func updateProgress(_ manifest: SelectiveRemoteUpdateManifest) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            updateStep(
                title: UpdateLocalization.text(ru: "Доступно", en: "Available"),
                detail: manifest.version,
                state: .complete
            )
            updateStep(
                title: UpdateLocalization.text(ru: "Загрузка", en: "Download"),
                detail: model.updateDownloadStage == .downloading
                    ? "\(Int(model.updateDownloadProgress * 100))%"
                    : nil,
                state: downloadStepState
            )
            updateStep(
                title: UpdateLocalization.text(ru: "Проверка", en: "Verification"),
                detail: model.updateDownloadStage == .verifying
                    ? "SHA-256"
                    : nil,
                state: verificationStepState
            )
            updateStep(
                title: UpdateLocalization.text(ru: "Готово к установке", en: "Ready to install"),
                detail: model.downloadedUpdateDMGURL?.lastPathComponent,
                state: readyStepState
            )
            updateStep(
                title: UpdateLocalization.text(ru: "Установка", en: "Installation"),
                detail: model.updateDownloadStage == .installing
                    ? UpdateLocalization.text(ru: "Перезапуск приложения…", en: "Restarting application…")
                    : nil,
                state: model.updateDownloadStage == .installing ? .active : .pending
            )

            if model.updateDownloadStage == .downloading {
                ProgressView(value: model.updateDownloadProgress)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private enum StepState {
        case pending
        case active
        case complete
    }

    private func updateStep(
        title: String,
        detail: String?,
        state: StepState
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: stepIcon(state))
                .foregroundStyle(stepColor(state))
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(state == .active ? .semibold : .regular))
            Spacer()
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func stepIcon(_ state: StepState) -> String {
        switch state {
        case .pending: "circle"
        case .active: "arrow.triangle.2.circlepath.circle.fill"
        case .complete: "checkmark.circle.fill"
        }
    }

    private func stepColor(_ state: StepState) -> Color {
        switch state {
        case .pending: .secondary
        case .active: .orange
        case .complete: .green
        }
    }

    private var downloadStepState: StepState {
        switch model.updateDownloadStage {
        case .idle:
            .pending
        case .downloading:
            .active
        case .verifying, .ready, .installing:
            .complete
        }
    }

    private var verificationStepState: StepState {
        switch model.updateDownloadStage {
        case .idle, .downloading:
            .pending
        case .verifying:
            .active
        case .ready, .installing:
            .complete
        }
    }

    private var readyStepState: StepState {
        switch model.updateDownloadStage {
        case .ready, .installing:
            .complete
        case .idle, .downloading, .verifying:
            .pending
        }
    }

    private var lastCheckText: String {
        guard let date = model.lastSuccessfulUpdateCheckDate else {
            return UpdateLocalization.text(
                ru: "Последняя проверка: ещё не выполнялась",
                en: "Last checked: not yet"
            )
        }
        let formatted: String
        if Calendar.current.isDateInToday(date) {
            formatted = date.formatted(date: .omitted, time: .shortened)
        } else {
            formatted = date.formatted(date: .abbreviated, time: .shortened)
        }
        return UpdateLocalization.text(
            ru: "Последняя проверка: \(formatted)",
            en: "Last checked: \(formatted)"
        )
    }
}
