import SwiftUI

struct CloudSettingsView: View {
    @ObservedObject var model: AppModel

    @AppStorage("SelectiveRemote.cloud.endpoint.v1")
    private var endpoint = SelectiveRemoteCloudEndpoint.production
    @AppStorage("SelectiveRemote.cloud.device-id.v1")
    private var storedDeviceID = ""

    @State private var phase = Phase.idle
    @State private var metadata: SelectiveRemoteCloudMetadata?
    @State private var errorMessage: String?
    @State private var accountPhase = AccountPhase.signedOut
    @State private var accountUser: SelectiveRemoteCloudUser?
    @State private var teams: [SelectiveRemoteCloudTeam] = []
    @State private var vaultsByTeam: [UUID: [SelectiveRemoteCloudSharedVault]] = [:]
    @State private var accountErrorMessage: String?
    @State private var registrationErrorMessage: String?
    @State private var registeredEmail: String?
    @State private var inventoryErrorMessage: String?
    @State private var personalVaultLoadErrorMessage: String?
    @State private var accountEndpoint: String?
    @State private var showsAccountSheet = false
    @State private var accountSheetMode = AccountSheetMode.signIn
    @State private var showsConflictReview = false
    @State private var conflictReviewMessage: String?
    @State private var personalVaultRevision: Int?
    @State private var personalVaultMessage: String?
    @State private var personalVaultMessageIsError = false
    @State private var personalVaultUploading = false
    @State private var showsPersonalVaultUpload = false
    @State private var personalVaultRecoveryPhrase = ""
    @State private var personalVaultRecoveryConfirmation = ""
    @State private var includePersonalVaultCredentials = false

    private let client = SelectiveRemoteCloudAPIClient()
    private let identityManager = SelectiveRemoteTeamDeviceIdentityManager()

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
                    accountStatus
                }
                LabeledContent("API") {
                    Text(metadata.map { "v\($0.apiVersion)" } ?? "—")
                        .monospacedDigit()
                }
                LabeledContent(UpdateLocalization.text(ru: "Схема Vault", en: "Vault Schema")) {
                    Text(metadata.map { "v\($0.vaultSchemaVersion)" } ?? "—")
                        .monospacedDigit()
                }

                if let accountUser {
                    LabeledContent(UpdateLocalization.text(ru: "Пользователь", en: "User")) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(accountUser.displayName)
                            Text(accountUser.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    Button(
                        UpdateLocalization.text(ru: "Выйти из Cloud", en: "Sign Out of Cloud"),
                        systemImage: "rectangle.portrait.and.arrow.right",
                        role: .destructive
                    ) {
                        signOut()
                    }
                    .disabled(accountPhase.isBusy)
                } else {
                    Button(
                        UpdateLocalization.text(
                            ru: "Войти в Selective Remote Cloud…",
                            en: "Sign In to Selective Remote Cloud…"
                        ),
                        systemImage: "person.crop.circle.badge.checkmark"
                    ) {
                        accountErrorMessage = nil
                        registrationErrorMessage = nil
                        registeredEmail = nil
                        accountSheetMode = .signIn
                        showsAccountSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accountPhase.isBusy)

                    if let registrationURL {
                        Link(
                            UpdateLocalization.text(
                                ru: "Регистрация на сайте…",
                                en: "Register on the Website…"
                            ),
                            destination: registrationURL
                        )
                    }

                    if metadata?.registrationEnabled == true {
                        Button(
                            UpdateLocalization.text(ru: "Создать аккаунт…", en: "Create Account…"),
                            systemImage: "person.crop.circle.badge.plus"
                        ) {
                            registrationErrorMessage = nil
                            registeredEmail = nil
                            accountSheetMode = .registration
                            showsAccountSheet = true
                        }
                        .disabled(accountPhase.isBusy)
                    } else if metadata?.registrationEnabled == false {
                        Label(
                            UpdateLocalization.text(
                                ru: "Регистрация новых аккаунтов на этом сервере отключена. Войти можно только с уже созданным и подтверждённым аккаунтом.",
                                en: "New-account registration is disabled on this server. You can only sign in with an existing verified account."
                            ),
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let accountErrorMessage {
                    Label(accountErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(UpdateLocalization.text(
                    ru: "Токен сессии и закрытый ключ устройства хранятся в Keychain только на этом Mac. Пароль аккаунта не сохраняется и не используется как ключ Vault.",
                    en: "The session token and device private key are stored in Keychain on this Mac only. The account password is not saved and is not used as the Vault key."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if accountUser != nil {
                Section("Personal Vault") {
                    LabeledContent(UpdateLocalization.text(ru: "Ревизия в Cloud", en: "Cloud revision")) {
                        Text(personalVaultRevision.map { "r\($0)" } ?? "—")
                            .monospacedDigit()
                    }
                    LabeledContent(UpdateLocalization.text(ru: "Локальные данные", en: "Local data")) {
                        Text(localPersonalVaultSummary)
                            .foregroundStyle(.secondary)
                    }

                    Button(
                        UpdateLocalization.text(
                            ru: "Зашифровать и отправить локальные данные…",
                            en: "Encrypt and Upload Local Data…"
                        ),
                        systemImage: "lock.doc.fill"
                    ) {
                        personalVaultMessage = nil
                        personalVaultMessageIsError = false
                        showsPersonalVaultUpload = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(personalVaultUploading || personalVaultRevision != 0)

                    if let personalVaultMessage {
                        Label(
                            personalVaultMessage,
                            systemImage: personalVaultMessageIsError
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(personalVaultMessageIsError ? Color.orange : Color.green)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let personalVaultLoadErrorMessage {
                        Label(personalVaultLoadErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(UpdateLocalization.text(
                        ru: "Первая отправка доступна только для пустого Cloud Vault. Recovery-фраза и открытые данные не сохраняются на сервере; существующая ревизия никогда не перезаписывается этим действием.",
                        en: "The first upload is available only for an empty Cloud Vault. The recovery phrase and plaintext are never stored on the server; this action never replaces an existing revision."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SelectiveRemoteCloudTeamInventoryView(
                    teams: teams,
                    vaultsByTeam: vaultsByTeam,
                    isRefreshing: accountPhase == .refreshing,
                    errorMessage: inventoryErrorMessage,
                    onRefresh: refreshInventory
                )
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

            Section(UpdateLocalization.text(ru: "Ручная проверка", en: "Manual Test")) {
                Button(
                    UpdateLocalization.text(
                        ru: "Открыть тестовый конфликт…",
                        en: "Open Test Conflict…"
                    ),
                    systemImage: "arrow.triangle.branch"
                ) {
                    conflictReviewMessage = nil
                    showsConflictReview = true
                }

                if let conflictReviewMessage {
                    Label(conflictReviewMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Text(UpdateLocalization.text(
                    ru: "Офлайн-сценарий использует только синтетические записи. Он проверяет полный выбор версий, скрытие секретов и итоговое объединение, но ничего не отправляет в Cloud.",
                    en: "This offline scenario uses synthetic records only. It checks complete choices, secret redaction and the final merge, but sends nothing to Cloud."
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            await loadCloudStateIfNeeded()
        }
        .sheet(isPresented: $showsAccountSheet) {
            accountSheet
        }
        .sheet(isPresented: $showsConflictReview) {
            conflictReviewSheet
        }
        .sheet(isPresented: $showsPersonalVaultUpload) {
            personalVaultUploadSheet
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        switch accountPhase {
        case .signedOut:
            Text(UpdateLocalization.text(ru: "Не подключён", en: "Not connected"))
                .foregroundStyle(.secondary)
        case .restoring:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(UpdateLocalization.text(ru: "Восстановление сессии…", en: "Restoring session…"))
            }
            .foregroundStyle(.secondary)
        case .signingIn:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(UpdateLocalization.text(ru: "Вход…", en: "Signing in…"))
            }
            .foregroundStyle(.secondary)
        case .registering:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(UpdateLocalization.text(ru: "Создание аккаунта…", en: "Creating account…"))
            }
            .foregroundStyle(.secondary)
        case .signedIn:
            Label(UpdateLocalization.text(ru: "Подключён", en: "Connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .refreshing:
            Label(UpdateLocalization.text(ru: "Обновление…", en: "Refreshing…"), systemImage: "arrow.clockwise")
                .foregroundStyle(.secondary)
        case .signingOut:
            Text(UpdateLocalization.text(ru: "Выход…", en: "Signing out…"))
                .foregroundStyle(.secondary)
        }
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
        Task { @MainActor in
            _ = await refreshCloudMetadata()
        }
    }

    @MainActor
    private func loadCloudStateIfNeeded() async {
        guard phase == .idle else { return }
        guard let url = await refreshCloudMetadata() else { return }
        await restoreStoredSession(at: url)
    }

    @MainActor
    private func refreshCloudMetadata() async -> URL? {
        phase = .checking
        errorMessage = nil
        do {
            let url = try SelectiveRemoteCloudEndpoint.normalized(endpoint)
            endpoint = url.absoluteString
            metadata = try await client.metadata(endpoint: url)
            phase = .available
            return url
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            return nil
        }
    }

    @ViewBuilder
    private var accountSheet: some View {
        if let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) {
            switch accountSheetMode {
            case .signIn:
                SelectiveRemoteCloudSignInView(
                    endpoint: url,
                    registrationEnabled: metadata?.registrationEnabled,
                    isSigningIn: accountPhase == .signingIn,
                    errorMessage: accountErrorMessage,
                    onCancel: closeAccountSheet,
                    onCreateAccount: {
                        registrationErrorMessage = nil
                        registeredEmail = nil
                        accountSheetMode = .registration
                    },
                    onSignIn: { email, password in
                        signIn(email: email, password: password, endpoint: url)
                    }
                )
            case .registration:
                if let registeredEmail {
                    SelectiveRemoteCloudRegistrationConfirmationView(
                        email: registeredEmail,
                        onDone: closeAccountSheet
                    )
                } else {
                    SelectiveRemoteCloudRegistrationView(
                        endpoint: url,
                        isRegistering: accountPhase == .registering,
                        errorMessage: registrationErrorMessage,
                        onBack: {
                            guard accountPhase != .registering else { return }
                            registrationErrorMessage = nil
                            accountSheetMode = .signIn
                        },
                        onCancel: closeAccountSheet,
                        onRegister: { displayName, email, password in
                            register(
                                displayName: displayName,
                                email: email,
                                password: password,
                                endpoint: url
                            )
                        }
                    )
                }
            }
        } else {
            ContentUnavailableView(
                UpdateLocalization.text(ru: "Некорректный адрес Cloud", en: "Invalid Cloud Address"),
                systemImage: "exclamationmark.triangle"
            )
            .frame(width: 500, height: 300)
        }
    }

    private func closeAccountSheet() {
        guard !accountPhase.isBusy else { return }
        showsAccountSheet = false
        accountErrorMessage = nil
        registrationErrorMessage = nil
        registeredEmail = nil
    }

    @MainActor
    private func restoreStoredSession(at url: URL) async {
        if accountEndpoint == url.absoluteString, accountUser != nil { return }
        resetAccountPresentation(endpoint: url)
        guard await client.hasStoredSession(endpoint: url) else { return }
        accountPhase = .restoring
        do {
            accountUser = try await client.currentUser(endpoint: url)
            accountPhase = .signedIn
            await loadInventory(endpoint: url)
        } catch {
            resetAccountPresentation(endpoint: url)
            accountErrorMessage = error.localizedDescription
        }
    }

    private func signIn(email: String, password: String, endpoint url: URL) {
        accountPhase = .signingIn
        accountErrorMessage = nil
        inventoryErrorMessage = nil
        Task { @MainActor in
            do {
                let deviceID = resolvedDeviceID()
                let identity = try await identityManager.identity(endpoint: url, deviceID: deviceID)
                accountUser = try await client.login(
                    endpoint: url,
                    email: email,
                    password: password,
                    device: .thisMac(id: deviceID, publicKey: identity.publicKey)
                )
                accountEndpoint = url.absoluteString
                accountPhase = .signedIn
                showsAccountSheet = false
                await loadInventory(endpoint: url)
            } catch {
                accountPhase = .signedOut
                accountErrorMessage = error.localizedDescription
            }
        }
    }

    private func register(displayName: String, email: String, password: String, endpoint url: URL) {
        guard metadata?.registrationEnabled == true else {
            registrationErrorMessage = UpdateLocalization.text(
                ru: "Регистрация новых аккаунтов отключена на этом сервере.",
                en: "New-account registration is disabled on this server."
            )
            return
        }
        accountPhase = .registering
        registrationErrorMessage = nil
        Task { @MainActor in
            do {
                let deviceID = resolvedDeviceID()
                let identity = try await identityManager.identity(endpoint: url, deviceID: deviceID)
                try await client.register(
                    endpoint: url,
                    displayName: displayName,
                    email: email,
                    password: password,
                    device: .thisMac(id: deviceID, publicKey: identity.publicKey)
                )
                registeredEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                accountPhase = .signedOut
            } catch {
                accountPhase = .signedOut
                registrationErrorMessage = error.localizedDescription
            }
        }
    }

    private func refreshInventory() {
        guard let accountUser,
              let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint)
        else { return }
        Task { @MainActor in
            do {
                self.accountUser = try await client.currentUser(endpoint: url)
                await loadInventory(endpoint: url)
            } catch {
                if error as? SelectiveRemoteCloudError == .authenticationRequired {
                    resetAccountPresentation(endpoint: url)
                } else {
                    self.accountUser = accountUser
                    accountPhase = .signedIn
                }
                accountErrorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadInventory(endpoint url: URL) async {
        accountPhase = .refreshing
        inventoryErrorMessage = nil
        personalVaultLoadErrorMessage = nil
        do {
            let personalVault = try await client.personalVault(endpoint: url)
            personalVaultRevision = personalVault.revision
        } catch {
            if error as? SelectiveRemoteCloudError == .authenticationRequired {
                resetAccountPresentation(endpoint: url)
                accountErrorMessage = error.localizedDescription
                return
            }
            personalVaultRevision = nil
            personalVaultLoadErrorMessage = error.localizedDescription
        }

        do {
            let loadedTeams = try await client.teams(endpoint: url)
            var loadedVaults: [UUID: [SelectiveRemoteCloudSharedVault]] = [:]
            for team in loadedTeams {
                loadedVaults[team.id] = try await client.sharedVaults(endpoint: url, teamID: team.id)
            }
            teams = loadedTeams.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            vaultsByTeam = loadedVaults.mapValues {
                $0.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        } catch {
            if error as? SelectiveRemoteCloudError == .authenticationRequired {
                resetAccountPresentation(endpoint: url)
                accountErrorMessage = error.localizedDescription
                return
            }
            teams = []
            vaultsByTeam = [:]
            inventoryErrorMessage = error.localizedDescription
        }
        if accountUser != nil {
            accountPhase = .signedIn
        }
    }

    private func signOut() {
        guard let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) else { return }
        accountPhase = .signingOut
        accountErrorMessage = nil
        Task { @MainActor in
            do {
                try await client.logout(endpoint: url)
                resetAccountPresentation(endpoint: url)
            } catch {
                resetAccountPresentation(endpoint: url)
                accountErrorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func resetAccountPresentation(endpoint url: URL) {
        accountEndpoint = url.absoluteString
        accountPhase = .signedOut
        accountUser = nil
        teams = []
        vaultsByTeam = [:]
        personalVaultRevision = nil
        personalVaultMessage = nil
        personalVaultMessageIsError = false
        accountErrorMessage = nil
        inventoryErrorMessage = nil
        personalVaultLoadErrorMessage = nil
    }

    private var registrationURL: URL? {
        guard let base = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) else { return nil }
        return base.appending(path: "login")
    }

    @MainActor
    private func resolvedDeviceID() -> UUID {
        if let existing = UUID(uuidString: storedDeviceID), existing.isSelectiveRemoteCloudUUID {
            return existing
        }
        let generated = UUID()
        storedDeviceID = generated.canonicalCloudString
        return generated
    }

    @MainActor
    private var localPersonalVaultSummary: String {
        let hosts = model.profiles.filter {
            !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.serialDevicePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let snippets = TerminalCommandHistoryStore.shared.templates().count
        let forwarding = model.independentPortForwards.count
        return UpdateLocalization.text(
            ru: "Hosts: \(hosts) · Snippets: \(snippets) · Forwarding: \(forwarding)",
            en: "Hosts: \(hosts) · Snippets: \(snippets) · Forwarding: \(forwarding)"
        )
    }

    @MainActor @ViewBuilder
    private var personalVaultUploadSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(UpdateLocalization.text(ru: "Первая отправка Personal Vault", en: "First Personal Vault Upload"))
                .font(.title2.bold())
            Text(UpdateLocalization.text(
                ru: "Придумайте отдельную recovery-фразу длиной не менее 16 символов. Она шифрует ключ Vault на этом Mac и не отправляется в Cloud. Сохраните её в надёжном месте: восстановить её на сервере нельзя.",
                en: "Create a separate recovery phrase of at least 16 characters. It protects the Vault key on this Mac and is never sent to Cloud. Keep it somewhere safe: the server cannot recover it."
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            SecureField(
                UpdateLocalization.text(ru: "Recovery-фраза", en: "Recovery phrase"),
                text: $personalVaultRecoveryPhrase
            )
            .textFieldStyle(.roundedBorder)
            SecureField(
                UpdateLocalization.text(ru: "Повторите recovery-фразу", en: "Confirm recovery phrase"),
                text: $personalVaultRecoveryConfirmation
            )
            .textFieldStyle(.roundedBorder)

            Toggle(
                UpdateLocalization.text(
                    ru: "Добавить сохранённые пароли (потребуется Touch ID или пароль Mac)",
                    en: "Include saved passwords (Touch ID or Mac password required)"
                ),
                isOn: $includePersonalVaultCredentials
            )

            if personalVaultUploading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(UpdateLocalization.text(ru: "Шифрование и отправка…", en: "Encrypting and uploading…"))
                }
                .foregroundStyle(.secondary)
            }

            if let personalVaultMessage, personalVaultMessageIsError {
                Label(personalVaultMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) {
                    closePersonalVaultUploadSheet()
                }
                .disabled(personalVaultUploading)
                Button(UpdateLocalization.text(ru: "Зашифровать и отправить", en: "Encrypt and Upload")) {
                    uploadPersonalVault()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    personalVaultUploading
                        || personalVaultRecoveryPhrase.utf8.count < 16
                        || personalVaultRecoveryPhrase != personalVaultRecoveryConfirmation
                )
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    @MainActor
    private func closePersonalVaultUploadSheet() {
        guard !personalVaultUploading else { return }
        personalVaultRecoveryPhrase = ""
        personalVaultRecoveryConfirmation = ""
        includePersonalVaultCredentials = false
        showsPersonalVaultUpload = false
    }

    @MainActor
    private func uploadPersonalVault() {
        let recoveryPhrase = personalVaultRecoveryPhrase
        guard recoveryPhrase == personalVaultRecoveryConfirmation,
              (16...1_024).contains(recoveryPhrase.precomposedStringWithCanonicalMapping.utf8.count),
              let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint),
              accountUser != nil
        else {
            personalVaultMessage = SelectiveRemotePersonalVaultError.invalidRecoveryPhrase.localizedDescription
            personalVaultMessageIsError = true
            return
        }

        personalVaultUploading = true
        personalVaultMessage = nil
        personalVaultMessageIsError = false
        Task { @MainActor in
            do {
                let remote = try await client.personalVault(endpoint: url)
                guard remote.revision == 0 else {
                    throw SelectiveRemotePersonalVaultError.remoteVaultNotEmpty(remote.revision)
                }
                let credentials = try await personalVaultCredentialsIfRequested()
                let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
                    profiles: model.profiles,
                    credentials: credentials,
                    snippets: TerminalCommandHistoryStore.shared.templates(),
                    forwarding: model.independentPortForwards,
                    deviceID: resolvedDeviceID()
                )
                let document = exported.document
                let envelope = try await Task.detached(priority: .userInitiated) {
                    try SelectiveRemotePersonalVaultCrypto.seal(
                        document,
                        recoveryPhrase: recoveryPhrase,
                        baseRevision: 0
                    )
                }.value
                let result = try await client.putPersonalVault(endpoint: url, envelope: envelope)
                guard !result.conflict else {
                    throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
                }
                personalVaultRevision = result.revision
                personalVaultMessage = UpdateLocalization.text(
                    ru: "Personal Vault отправлен: Hosts \(exported.summary.hosts), Credentials \(exported.summary.credentials), Snippets \(exported.summary.snippets), Forwarding \(exported.summary.forwarding). Ревизия r\(result.revision).",
                    en: "Personal Vault uploaded: Hosts \(exported.summary.hosts), Credentials \(exported.summary.credentials), Snippets \(exported.summary.snippets), Forwarding \(exported.summary.forwarding). Revision r\(result.revision)."
                )
                personalVaultMessageIsError = false
                personalVaultUploading = false
                closePersonalVaultUploadSheet()
            } catch {
                personalVaultUploading = false
                personalVaultMessage = error.localizedDescription
                personalVaultMessageIsError = true
            }
        }
    }

    @MainActor
    private func personalVaultCredentialsIfRequested() async throws
        -> [SelectiveRemotePersonalVaultCredentialInput]
    {
        guard includePersonalVaultCredentials else { return [] }
        try await KeychainService.authenticateDeviceOwner(reason: UpdateLocalization.text(
            ru: "Разрешить Selective Remote прочитать сохранённые пароли для шифрования Personal Vault",
            en: "Allow Selective Remote to read saved passwords for Personal Vault encryption"
        ))
        var result: [SelectiveRemotePersonalVaultCredentialInput] = []
        for profile in model.profiles {
            switch profile.connectionType {
            case .rdp:
                try appendPersonalVaultCredential(
                    to: &result,
                    sourceID: profile.id,
                    kind: .rdp,
                    title: "\(profile.friendlyName) · RDP",
                    username: profile.username
                )
                if !profile.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try appendPersonalVaultCredential(
                        to: &result,
                        sourceID: profile.id,
                        kind: .gateway,
                        title: "\(profile.friendlyName) · Gateway",
                        username: profile.gatewayUsername
                    )
                }
            case .ssh, .telnet:
                try appendPersonalVaultCredential(
                    to: &result,
                    sourceID: profile.id,
                    kind: .ssh,
                    title: "\(profile.friendlyName) · \(profile.connectionType.title)",
                    username: profile.username
                )
                if profile.sshProxyMode != .none {
                    try appendPersonalVaultCredential(
                        to: &result,
                        sourceID: profile.id,
                        kind: .proxy,
                        title: "\(profile.friendlyName) · Proxy",
                        username: profile.sshProxyUsername
                    )
                }
            case .serial:
                break
            }
        }
        for forwarding in model.independentPortForwards {
            try appendPersonalVaultCredential(
                to: &result,
                sourceID: forwarding.id,
                kind: .forwarding,
                title: "\(forwarding.rule.displayName) · Forwarding",
                username: forwarding.connection.username
            )
        }
        return result
    }

    @MainActor
    private func appendPersonalVaultCredential(
        to values: inout [SelectiveRemotePersonalVaultCredentialInput],
        sourceID: UUID,
        kind: KeychainCredentialKind,
        title: String,
        username: String
    ) throws {
        guard let secret = try KeychainService.readPassword(profileID: sourceID, kind: kind),
              !secret.isEmpty
        else { return }
        values.append(.init(
            sourceID: sourceID,
            kind: kind,
            title: title,
            username: username,
            secret: secret
        ))
    }

    @ViewBuilder
    private var conflictReviewSheet: some View {
        if let scenario = try? SelectiveRemoteVaultConflictReviewScenario.synthetic() {
            SelectiveRemoteVaultConflictReviewView(
                mergedDocument: scenario.mergedDocument,
                conflicts: scenario.conflicts,
                onCancel: { showsConflictReview = false },
                onResolve: { resolutions in
                    do {
                        let resolved = try scenario.resolve(resolutions)
                        conflictReviewMessage = UpdateLocalization.text(
                            ru: "Проверка пройдена: разрешено \(resolutions.count), итоговых записей \(resolved.records.count), удалений \(resolved.tombstones.count).",
                            en: "Test passed: resolved \(resolutions.count), final records \(resolved.records.count), deletions \(resolved.tombstones.count)."
                        )
                        showsConflictReview = false
                    } catch {
                        conflictReviewMessage = nil
                    }
                }
            )
        } else {
            ContentUnavailableView(
                UpdateLocalization.text(ru: "Тест недоступен", en: "Test Unavailable"),
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private enum Phase {
        case idle
        case checking
        case available
        case failed
    }

    private enum AccountSheetMode {
        case signIn
        case registration
    }

    private enum AccountPhase: Equatable {
        case signedOut
        case restoring
        case signingIn
        case registering
        case signedIn
        case refreshing
        case signingOut

        var isBusy: Bool {
            switch self {
            case .restoring, .signingIn, .registering, .refreshing, .signingOut: true
            case .signedOut, .signedIn: false
            }
        }
    }
}
