import SwiftUI

struct CloudSettingsView: View {
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
    @State private var accountEndpoint: String?
    @State private var showsAccountSheet = false
    @State private var accountSheetMode = AccountSheetMode.signIn
    @State private var showsConflictReview = false
    @State private var conflictReviewMessage: String?

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
            await loadCloudState(force: true)
        }
    }

    @MainActor
    private func loadCloudStateIfNeeded() async {
        guard phase == .idle else { return }
        await loadCloudState(force: false)
    }

    @MainActor
    private func loadCloudState(force: Bool) async {
        phase = .checking
        metadata = nil
        errorMessage = nil
        do {
            let url = try SelectiveRemoteCloudEndpoint.normalized(endpoint)
            endpoint = url.absoluteString
            metadata = try await client.metadata(endpoint: url)
            phase = .available
            await restoreStoredSession(at: url, force: force)
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
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
    private func restoreStoredSession(at url: URL, force: Bool) async {
        if !force, accountEndpoint == url.absoluteString { return }
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
        accountPhase = .signedIn
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
        accountErrorMessage = nil
        inventoryErrorMessage = nil
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
