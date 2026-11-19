import CryptoKit
import SwiftUI

@MainActor
enum SelectiveRemoteCloudSessionTransition {
    static func notify() {
        NotificationCenter.default.post(name: .selectiveRemoteCloudSessionChanged, object: nil)
    }
}

struct CloudSettingsView: View {
    @ObservedObject var model: AppModel

    @AppStorage("SelectiveRemote.cloud.endpoint.v1")
    private var endpoint = SelectiveRemoteCloudEndpoint.production
    @AppStorage("SelectiveRemote.cloud.device-id.v1")
    private var storedDeviceID = ""
    @AppStorage("SelectiveRemote.cloud.personal-vault-sync-enabled.v1")
    private var personalVaultSyncEnabled = true
    @AppStorage(SelectiveRemotePersonalVaultSyncStatus.lastSuccessKey)
    private var personalVaultLastSuccess = 0.0
    @AppStorage(SelectiveRemotePersonalVaultSyncStatus.revisionKey)
    private var personalVaultSyncedRevision = 0
    @AppStorage(SelectiveRemotePersonalVaultSyncStatus.errorKey)
    private var personalVaultSyncError = ""
    @AppStorage(SelectiveRemotePersonalVaultSyncStatus.isSyncingKey)
    private var personalVaultIsSyncing = false

    @State private var phase = Phase.idle
    @State private var metadata: SelectiveRemoteCloudMetadata?
    @State private var errorMessage: String?
    @State private var accountPhase = AccountPhase.signedOut
    @State private var accountUser: SelectiveRemoteCloudUser?
    @State private var accountSession: SelectiveRemoteCloudSessionBinding?
    @State private var accountPresentationGeneration = UUID()
    @State private var signInPriorSessionLoss: SelectiveRemoteCloudSessionLoss?
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
    @State private var showsInitialVaultDifferences = false
    @State private var initialVaultDifferences: [InitialVaultDifference] = []

    private struct InitialVaultDifference: Identifiable {
        let id: UUID
        let title: String
        let mayContainDifferentPassword: Bool
        let deletedInCloud: Bool
    }
    @State private var conflictReviewMessage: String?
    @State private var personalVaultRevision: Int?
    @State private var personalVaultMessage: String?
    @State private var personalVaultMessageIsError = false
    @State private var personalVaultUploading = false
    @State private var showsPersonalVaultUpload = false
    @State private var showsPersonalVaultUnlock = false
    @State private var personalVaultUnlockError: String?
    @State private var showsTeamManagement = false
    @State private var showsDeviceTrust = false
    @State private var personalVaultRecoveryPhrase = ""
    @State private var personalVaultRecoveryConfirmation = ""
    @State private var includePersonalVaultCredentials = false
    @State private var personalVaultSetup = PersonalVaultSetup.checking

    private var personalVaultAutoSyncConfigured: Bool { personalVaultSetup == .connected }

    private let client = SelectiveRemoteCloudAPIClient()
    private let identityManager = SelectiveRemoteTeamDeviceIdentityManager()
    private let personalVaultKeyStore = SelectiveRemotePersonalVaultKeychainStore()

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

                    Button(UpdateLocalization.text(ru: "Доверие устройств…", en: "Device Trust…"),
                           systemImage: "checkmark.shield") {
                        showsDeviceTrust = true
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
                    LabeledContent(UpdateLocalization.text(ru: "Автосинхронизация", en: "Automatic sync")) {
                        Text(personalVaultSetupTitle)
                            .foregroundStyle(personalVaultAutoSyncConfigured && personalVaultSyncEnabled
                                             ? Color.green : Color.secondary)
                    }

                    if personalVaultSetup != .connected, personalVaultSetup != .checking {
                        Button(
                            personalVaultSetupAction,
                            systemImage: "key.fill"
                        ) {
                            personalVaultLoadErrorMessage = nil
                            switch personalVaultSetup {
                            case .needsUnlock:
                                personalVaultUnlockError = nil
                                showsPersonalVaultUnlock = true
                            case .initialDownload:
                                connectPersonalVault()
                            case .empty:
                                showsPersonalVaultUpload = true
                            case .checking, .connected:
                                break
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(accountPhase.isBusy)
                    }

                    Toggle(
                        UpdateLocalization.text(
                            ru: "Синхронизировать Personal Vault",
                            en: "Sync Personal Vault"
                        ),
                        isOn: $personalVaultSyncEnabled
                    )

                    LabeledContent(UpdateLocalization.text(
                        ru: "Последняя синхронизация",
                        en: "Last synchronization"
                    )) {
                        Text(personalVaultLastSuccessText)
                            .foregroundStyle(.secondary)
                    }

                    if personalVaultSyncedRevision > 0 {
                        LabeledContent(UpdateLocalization.text(
                            ru: "Применённая ревизия",
                            en: "Applied revision"
                        )) {
                            Text("r\(personalVaultSyncedRevision)")
                                .monospacedDigit()
                        }
                    }

                    Button(
                        UpdateLocalization.text(
                            ru: "Синхронизировать сейчас",
                            en: "Synchronize Now"
                        ),
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        NotificationCenter.default.post(
                            name: .selectiveRemotePersonalVaultSyncNow,
                            object: nil
                        )
                    }
                    .disabled(
                        !personalVaultSyncEnabled
                            || !personalVaultAutoSyncConfigured
                            || personalVaultIsSyncing
                    )

                    if personalVaultIsSyncing {
                        Label(
                            UpdateLocalization.text(ru: "Синхронизация…", en: "Synchronizing…"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .foregroundStyle(.secondary)
                    } else if !personalVaultSyncError.isEmpty {
                        Label(
                            SelectiveRemotePersonalVaultSyncStatus.message(for: personalVaultSyncError),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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

                    if !initialVaultDifferences.isEmpty {
                        Button(UpdateLocalization.text(ru: "Посмотреть расхождения…", en: "View differences…"),
                               systemImage: "list.bullet") {
                            showsInitialVaultDifferences = true
                        }
                    }

                    Text(UpdateLocalization.text(
                        ru: "После входа Hosts, Snippets, Forwarding и сохранённые пароли синхронизируются автоматически. macOS может запросить доступ к Keychain. В Cloud хранятся только зашифрованные данные.",
                        en: "After sign-in, Hosts, Snippets, Forwarding, and saved passwords sync automatically. macOS may ask for Keychain access. Cloud stores only end-to-end encrypted data."
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
                    onRefresh: refreshInventory,
                    onManage: { showsTeamManagement = true }
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
        .onReceive(NotificationCenter.default.publisher(for: .selectiveRemoteCloudSessionLost)) { notification in
            guard let loss = notification.object as? SelectiveRemoteCloudSessionLoss,
                  let session = accountSession, loss.matches(session) else { return }
            let priorSessionLost = accountPhase == .signingIn && signInPriorSessionLoss == loss
            resetAccountPresentation(endpoint: session.endpoint, preservingSignIn: priorSessionLost)
            if !priorSessionLost { accountErrorMessage = SelectiveRemoteCloudError.authenticationRequired.localizedDescription }
        }
        .onChange(of: accountUser?.id) { _, _ in
            showsTeamManagement = false
            SelectiveRemoteCloudSessionTransition.notify()
        }
        .onChange(of: endpoint) { _, _ in showsTeamManagement = false }
        .onChange(of: personalVaultSyncEnabled) { _, _ in
            NotificationCenter.default.post(name: .selectiveRemotePersonalVaultSyncNow, object: nil)
        }
        .sheet(isPresented: $showsAccountSheet) {
            accountSheet
        }
        .sheet(isPresented: $showsPersonalVaultUnlock) {
            PersonalVaultUnlockView(
                isUnlocking: accountPhase == .connectingPersonalVault,
                errorMessage: personalVaultUnlockError,
                onCancel: { showsPersonalVaultUnlock = false },
                onUnlock: { secret, method in connectPersonalVault(unlock: (secret, method)) }
            )
        }
        .sheet(isPresented: $showsPersonalVaultUpload) {
            personalVaultUploadSheet
                .interactiveDismissDisabled(personalVaultUploading)
        }
        .sheet(isPresented: $showsInitialVaultDifferences) {
            initialVaultDifferencesSheet
        }
        .sheet(isPresented: $showsConflictReview) {
            conflictReviewSheet
        }
        .sheet(isPresented: $showsTeamManagement) {
            if let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) {
                SelectiveRemoteCloudTeamManagementView(
                    endpoint: url,
                    client: client,
                    onInventoryChanged: refreshInventory
                )
            }
        }
        .sheet(isPresented: $showsDeviceTrust) {
            if let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) {
                SelectiveRemoteCloudDeviceTrustView(endpoint: url, client: client)
            }
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
        case .signedIn, .connectingPersonalVault:
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
        let generation = accountPresentationGeneration
        guard let url = await refreshCloudMetadata() else { return }
        guard accountPresentationGeneration == generation, !accountPhase.isBusy else { return }
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
                        onCheckUsername: { username in
                            try await client.registrationUsernameAvailable(
                                endpoint: url,
                                username: username
                            )
                        },
                        onRegister: { displayName, username, email, password in
                            register(
                                displayName: displayName,
                                username: username,
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
        let generation = accountPresentationGeneration
        accountPhase = .restoring
        do {
            let session = try await client.sessionBinding(endpoint: url)
            guard accountPresentationGeneration == generation else { return }
            let user = try await client.currentUser(endpoint: url)
            try await client.checkSession(session)
            guard accountPresentationGeneration == generation else { return }
            accountSession = session
            accountUser = user
            SyncPresentationStore.shared.invalidateSession()
            accountPhase = .signedIn
            await loadInventory(endpoint: url)
            guard isCurrentPresentation(generation, session: session) else { return }
            NotificationCenter.default.post(
                name: .selectiveRemoteTeamVaultSyncNow,
                object: nil
            )
        } catch {
            guard accountPresentationGeneration == generation else { return }
            resetAccountPresentation(endpoint: url)
            if error is CancellationError || error as? SelectiveRemoteCloudError == .authenticationRequired { return }
            accountErrorMessage = error.localizedDescription
        }
    }

    private func signIn(email: String, password: String, endpoint url: URL) {
        SelectiveRemoteCloudSessionTransition.notify()
        signInPriorSessionLoss = accountSession.map { .init(endpoint: $0.endpoint, epoch: $0.epoch) }
        accountPresentationGeneration = UUID()
        let generation = accountPresentationGeneration
        accountEndpoint = url.absoluteString
        accountPhase = .signingIn
        accountErrorMessage = nil
        inventoryErrorMessage = nil
        Task { @MainActor in
            do {
                let deviceID = resolvedDeviceID()
                let identity = try await identityManager.identity(endpoint: url, deviceID: deviceID)
                guard accountPresentationGeneration == generation else { return }
                let signedIn = try await client.loginWithSession(
                    endpoint: url,
                    email: email,
                    password: password,
                    device: .thisMac(id: deviceID, publicKey: identity.publicKey)
                )
                guard accountPresentationGeneration == generation else { return }
                accountUser = signedIn.user
                accountSession = signedIn.session
                SyncPresentationStore.shared.invalidateSession()
                accountEndpoint = url.absoluteString
                var enrollmentError: String?
                let enrollment = SelectiveRemotePersonalVaultAccountEnrollment(
                    client: client,
                    keyStore: personalVaultKeyStore
                )
                do {
                    let credentials = personalVaultSyncEnabled
                        ? try await SelectiveRemotePersonalVaultCredentialCollector.shared.collect(
                            profiles: model.profiles,
                            forwarding: model.independentPortForwards
                        )
                        : []
                    let sshKeys = personalVaultSyncEnabled
                        ? try await SelectiveRemotePersonalVaultCredentialCollector.shared.collectSSHKeys(model.sshKeys)
                        : []
                    _ = try await enrollment.enrollOrCreate(
                        endpoint: url,
                        deviceID: deviceID,
                        session: signedIn.session,
                        password: password,
                        profiles: model.profiles,
                        snippets: TerminalCommandHistoryStore.shared.templates(),
                        forwarding: model.independentPortForwards,
                        credentials: credentials,
                        sshKeys: sshKeys
                    )
                } catch {
                    enrollmentError = error.localizedDescription
                }
                try await client.checkSession(signedIn.session)
                guard isCurrentPresentation(generation, session: signedIn.session) else { return }
                accountPhase = .signedIn
                signInPriorSessionLoss = nil
                showsAccountSheet = false
                await loadInventory(endpoint: url)
                guard isCurrentPresentation(generation, session: signedIn.session) else { return }
                NotificationCenter.default.post(
                    name: .selectiveRemoteTeamVaultSyncNow,
                    object: nil
                )
                if enrollmentError == nil {
                    do {
                        try await applyInitialPersonalVaultDownload(endpoint: url, deviceID: deviceID, session: signedIn.session)
                        guard isCurrentPresentation(generation, session: signedIn.session) else { return }
                        await loadInventory(endpoint: url)
                    } catch {
                        enrollmentError = error.localizedDescription
                    }
                }
                guard isCurrentPresentation(generation, session: signedIn.session) else { return }
                if let enrollmentError {
                    personalVaultLoadErrorMessage = UpdateLocalization.text(
                        ru: "Вход выполнен, но Personal Vault не подключён автоматически: \(enrollmentError)",
                        en: "Sign-in succeeded, but Personal Vault was not enrolled automatically: \(enrollmentError)"
                    )
                }
            } catch {
                guard accountPresentationGeneration == generation else { return }
                let interrupted = UpdateLocalization.text(
                    ru: "Вход не завершён: сеанс изменился. Повторите попытку.",
                    en: "Sign-in did not complete because the session changed. Please try again."
                )
                if let session = accountSession, isCurrentPresentation(generation, session: session) {
                    await recoverCancelledPresentation(generation, session: session,
                                                       message: error is CancellationError ? interrupted : error.localizedDescription)
                    return
                }
                if error is CancellationError {
                    resetAccountPresentation(endpoint: url)
                    accountErrorMessage = interrupted
                    return
                }
                accountPhase = .signedOut
                accountErrorMessage = error.localizedDescription
            }
        }
    }

    private func register(displayName: String, username: String, email: String, password: String, endpoint url: URL) {
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
                    username: username,
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
              let originalSession = accountSession,
              let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint)
        else { return }
        let generation = accountPresentationGeneration
        Task { @MainActor in
            do {
                let refreshedUser = try await client.currentUser(endpoint: url)
                try await client.checkSession(originalSession)
                guard isCurrentPresentation(generation, session: originalSession) else { return }
                if refreshedUser.id != accountUser.id {
                    SyncPresentationStore.shared.invalidateSession()
                }
                self.accountUser = refreshedUser
                await loadInventory(endpoint: url)
            } catch {
                guard isCurrentPresentation(generation, session: originalSession) else { return }
                if error is CancellationError {
                    await recoverCancelledPresentation(generation, session: originalSession)
                    return
                }
                if (error as? SelectiveRemoteCloudError)?.isAuthenticationLoss == true {
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
        guard let session = accountSession else { return }
        let generation = accountPresentationGeneration
        accountPhase = .refreshing
        inventoryErrorMessage = nil
        personalVaultLoadErrorMessage = nil
        do {
            let personalVault = try await client.personalVault(endpoint: url, session: session)
            try await client.checkSession(session)
            guard isCurrentPresentation(generation, session: session) else { return }
            personalVaultRevision = personalVault.revision
            personalVaultSetup = .checking
            if personalVault.revision == 0 {
                personalVaultSetup = .empty
            } else {
                let deviceID = resolvedDeviceID()
                let material = try await Task.detached { [personalVaultKeyStore] in
                    try personalVaultKeyStore.material(endpoint: url, deviceID: deviceID)
                }.value
                try await client.checkSession(session)
                guard isCurrentPresentation(generation, session: session) else { return }
                if let material, material.vaultID == personalVault.id {
                    if material.allowsUpload {
                        personalVaultSetup = .connected
                    } else {
                        personalVaultSetup = material.wrappedKey == personalVault.envelope?.wrappedKey
                            ? .initialDownload : .needsUnlock
                    }
                } else {
                    personalVaultSetup = .needsUnlock
                }
            }
        } catch {
            guard isCurrentPresentation(generation, session: session) else { return }
            if error is CancellationError {
                await recoverCancelledPresentation(generation, session: session)
                return
            }
            if (error as? SelectiveRemoteCloudError)?.isAuthenticationLoss == true {
                resetAccountPresentation(endpoint: url)
                accountErrorMessage = error.localizedDescription
                return
            }
            personalVaultRevision = nil
            personalVaultSetup = .checking
            personalVaultLoadErrorMessage = error.localizedDescription
        }

        do {
            let loadedTeams = try await client.teams(endpoint: url)
            try await client.checkSession(session)
            guard isCurrentPresentation(generation, session: session) else { return }
            var loadedVaults: [UUID: [SelectiveRemoteCloudSharedVault]] = [:]
            for team in loadedTeams {
                loadedVaults[team.id] = try await client.sharedVaults(endpoint: url, teamID: team.id)
                try await client.checkSession(session)
                guard isCurrentPresentation(generation, session: session) else { return }
            }
            teams = loadedTeams.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            vaultsByTeam = loadedVaults.mapValues {
                $0.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        } catch {
            guard isCurrentPresentation(generation, session: session) else { return }
            if error is CancellationError {
                await recoverCancelledPresentation(generation, session: session)
                return
            }
            if (error as? SelectiveRemoteCloudError)?.isAuthenticationLoss == true {
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
        guard let session = accountSession else { return }
        let url = session.endpoint
        let generation = accountPresentationGeneration
        accountPhase = .signingOut
        accountErrorMessage = nil
        Task { @MainActor in
            do {
                try await client.logout(endpoint: url, session: session)
                guard isCurrentPresentation(generation, session: session) else { return }
                resetAccountPresentation(endpoint: url)
                NotificationCenter.default.post(
                    name: .selectiveRemoteTeamVaultSyncNow,
                    object: nil
                )
            } catch {
                guard isCurrentPresentation(generation, session: session) else { return }
                if error is CancellationError {
                    await recoverCancelledPresentation(generation, session: session)
                    return
                }
                resetAccountPresentation(endpoint: url)
                NotificationCenter.default.post(
                    name: .selectiveRemoteTeamVaultSyncNow,
                    object: nil
                )
                accountErrorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func connectPersonalVault(
        unlock: (String, SelectiveRemotePersonalVaultAccountEnrollment.UnlockMethod)? = nil
    ) {
        guard !accountPhase.isBusy, let session = accountSession,
              (try? SelectiveRemoteCloudEndpoint.normalized(endpoint)) == session.endpoint
        else { return }
        let generation = accountPresentationGeneration
        let deviceID = resolvedDeviceID()
        accountPhase = .connectingPersonalVault
        personalVaultUnlockError = nil
        personalVaultLoadErrorMessage = nil
        Task { @MainActor in
            do {
                if let (secret, method) = unlock {
                    let enrollment = SelectiveRemotePersonalVaultAccountEnrollment(
                        client: client, keyStore: personalVaultKeyStore
                    )
                    try await enrollment.unlockExistingVault(
                        session: session, deviceID: deviceID, secret: secret, method: method
                    )
                    guard isCurrentPresentation(generation, session: session) else { return }
                    personalVaultSetup = .initialDownload
                    showsPersonalVaultUnlock = false
                }
                try await applyInitialPersonalVaultDownload(
                    endpoint: session.endpoint, deviceID: deviceID, session: session
                )
                try await client.checkSession(session)
                guard isCurrentPresentation(generation, session: session) else { return }
                accountPhase = .signedIn
                await loadInventory(endpoint: session.endpoint)
                guard isCurrentPresentation(generation, session: session) else { return }
                NotificationCenter.default.post(name: .selectiveRemotePersonalVaultSyncNow, object: nil)
            } catch {
                guard isCurrentPresentation(generation, session: session) else { return }
                accountPhase = .signedIn
                if error is CancellationError {
                    await recoverCancelledPresentation(generation, session: session)
                    return
                }
                if (error as? SelectiveRemoteCloudError)?.isAuthenticationLoss == true {
                    resetAccountPresentation(endpoint: session.endpoint)
                    accountErrorMessage = error.localizedDescription
                    return
                }
                if showsPersonalVaultUnlock { personalVaultUnlockError = error.localizedDescription }
                else { personalVaultLoadErrorMessage = error.localizedDescription }
            }
        }
    }

    @MainActor
    private func applyInitialPersonalVaultDownload(endpoint url: URL, deviceID: UUID, session: SelectiveRemoteCloudSessionBinding) async throws {
        guard let material = try personalVaultKeyStore.material(endpoint: url, deviceID: deviceID),
              material.requiresInitialDownload == true
        else { return }
        let remote = try await client.personalVault(endpoint: url, session: session)
        guard remote.id == material.vaultID, remote.revision >= material.revision,
              let envelope = remote.envelope, envelope.wrappedKey == material.wrappedKey
        else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
        let generation = accountPresentationGeneration
        let document = try SelectiveRemotePersonalVaultCrypto.open(envelope, vaultKey: material.vaultKey)
        let snapshot = try SelectiveRemotePersonalVaultImporter.decode(document)
        let credentialSources = Set(model.profiles.map(\.id) + model.independentPortForwards.map(\.id))
        var existingSecrets: [String: String] = [:]
        if snapshot.credentials.contains(where: { credentialSources.contains($0.sourceID) }) {
            // Read the unified Vault once. An unavailable password remains a conflict.
            existingSecrets = await Task.detached {
                (try? UnifiedCredentialVault.shared.exportedSecrets()) ?? [:]
            }.value
        }
        try await client.checkSession(session)
        guard isCurrentPresentation(generation, session: session) else { throw CancellationError() }
        let history = TerminalCommandHistoryStore.shared
        let localSnippets = history.templates()
        let plan = SelectiveRemotePersonalVaultImporter.plan(
            snapshot: snapshot,
            localProfiles: model.profiles,
            localSnippets: localSnippets,
            localForwarding: model.independentPortForwards,
            localSSHKeys: model.sshKeys,
            existingPassword: { id, kind in
                let reference = KeychainService.credentialReference(profileID: id, kind: kind)
                return existingSecrets[UnifiedCredentialVault.entryKey(for: reference)]
            }
        )
        initialVaultDifferences = []
        guard plan.canApply else {
            let labels = Dictionary(
                model.profiles.map { ($0.id, $0.friendlyName) }
                    + localSnippets.map { ($0.id, $0.title) }
                    + model.independentPortForwards.map { ($0.id, $0.rule.displayName) }
                    + model.sshKeys.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            initialVaultDifferences = plan.conflictIDs.compactMap { id in
                guard let title = labels[id] else { return nil }
                return InitialVaultDifference(
                    id: id, title: title,
                    mayContainDifferentPassword: plan.credentialConflictIDs.contains(id),
                    deletedInCloud: snapshot.tombstoneIDs.contains(id)
                )
            }
            throw SelectiveRemotePersonalVaultImportError.conflicts(plan.conflictIDs)
        }
        let applied = try SelectiveRemotePersonalVaultKeyMaterial(
            vaultID: remote.id, vaultKey: material.vaultKey, wrappedKey: envelope.wrappedKey,
            revision: remote.revision, documentHash: Data(SHA256.hash(data: document.encoded())),
            includesCredentials: document.records.contains { $0.type == .credential }
        )
        let committed = try session.commitPersonalVault(
            tokenStore: client.tokenStore, keyStore: personalVaultKeyStore, deviceID: deviceID,
            expected: material, material: applied
        ) {
            if !plan.credentials.isEmpty { try KeychainService.savePasswords(plan.credentials) }
            model.sshKeys.append(contentsOf: try SelectiveRemotePersonalVaultSSHKeyStore.install(plan.sshKeys))
            model.profiles.append(contentsOf: plan.profiles)
            model.independentPortForwards.append(contentsOf: plan.forwarding)
            history.importTemplates(plan.snippets)
            return true
        }
        guard committed else { throw CancellationError() }
    }

    @MainActor
    private func resetAccountPresentation(endpoint url: URL, preservingSignIn: Bool = false) {
        if !preservingSignIn { accountPresentationGeneration = UUID() }
        SyncPresentationStore.shared.invalidateSession()
        if !preservingSignIn {
            accountEndpoint = url.absoluteString
            accountPhase = .signedOut
            signInPriorSessionLoss = nil
        }
        accountUser = nil
        accountSession = nil
        teams = []
        vaultsByTeam = [:]
        personalVaultRevision = nil
        personalVaultMessage = nil
        personalVaultMessageIsError = false
        personalVaultSetup = .checking
        initialVaultDifferences = []
        showsInitialVaultDifferences = false
        showsPersonalVaultUnlock = false
        showsPersonalVaultUpload = false
        personalVaultUnlockError = nil
        personalVaultUploading = false
        personalVaultRecoveryPhrase = ""
        personalVaultRecoveryConfirmation = ""
        includePersonalVaultCredentials = false
        accountErrorMessage = nil
        inventoryErrorMessage = nil
        personalVaultLoadErrorMessage = nil
    }

    @MainActor
    private func isCurrentPresentation(_ generation: UUID, session: SelectiveRemoteCloudSessionBinding) -> Bool {
        accountPresentationGeneration == generation && accountSession?.endpoint == session.endpoint
            && accountSession?.epoch == session.epoch
    }

    @MainActor
    private func recoverCancelledPresentation(_ generation: UUID, session: SelectiveRemoteCloudSessionBinding,
                                              message: String? = nil) async {
        guard isCurrentPresentation(generation, session: session) else { return }
        do {
            try await client.checkSessionAuthorization(session)
            guard isCurrentPresentation(generation, session: session) else { return }
            accountPhase = .signedIn
            accountErrorMessage = message
        } catch {
            guard isCurrentPresentation(generation, session: session) else { return }
            if error is CancellationError {
                resetAccountPresentation(endpoint: session.endpoint)
                accountErrorMessage = message
            } else {
                accountPhase = .signedIn
                accountErrorMessage = UpdateLocalization.text(
                    ru: "Не удалось проверить текущий сеанс Cloud. Повторите попытку.",
                    en: "The current Cloud session could not be checked. Please try again."
                )
            }
        }
    }

    private var registrationURL: URL? {
        guard let base = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) else { return nil }
        return SelectiveRemoteCloudPortalURL.registration(endpoint: base)
    }

    private var personalVaultSetupTitle: String {
        switch personalVaultSetup {
        case .checking:
            UpdateLocalization.text(ru: "Ожидает проверки", en: "Awaiting check")
        case .empty:
            UpdateLocalization.text(ru: "Нужна первоначальная настройка", en: "Initial setup needed")
        case .needsUnlock:
            UpdateLocalization.text(ru: "Нужно разблокировать Vault", en: "Vault needs unlocking")
        case .initialDownload:
            UpdateLocalization.text(ru: "Нужно завершить подключение", en: "Finish connecting")
        case .connected:
            personalVaultSyncEnabled
                ? UpdateLocalization.text(ru: "Включена", en: "Enabled")
                : UpdateLocalization.text(ru: "Выключена", en: "Disabled")
        }
    }

    private var personalVaultSetupAction: String {
        switch personalVaultSetup {
        case .empty:
            UpdateLocalization.text(ru: "Настроить личный Vault…", en: "Set Up Personal Vault…")
        case .initialDownload:
            UpdateLocalization.text(ru: "Завершить подключение", en: "Finish Connecting")
        default:
            UpdateLocalization.text(ru: "Разблокировать личный Vault…", en: "Unlock Personal Vault…")
        }
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

    @MainActor
    private var personalVaultLastSuccessText: String {
        guard personalVaultLastSuccess > 0 else {
            return UpdateLocalization.text(ru: "Ещё не выполнялась", en: "Not yet synchronized")
        }
        return UpdateLocalization.dateTimeShort(Date(timeIntervalSince1970: personalVaultLastSuccess))
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
              accountUser != nil,
              let session = accountSession,
              session.endpoint == url
        else {
            personalVaultMessage = SelectiveRemotePersonalVaultError.invalidRecoveryPhrase.localizedDescription
            personalVaultMessageIsError = true
            return
        }

        personalVaultUploading = true
        accountPhase = .connectingPersonalVault
        let generation = accountPresentationGeneration
        personalVaultMessage = nil
        personalVaultMessageIsError = false
        Task { @MainActor in
            do {
                let deviceID = resolvedDeviceID()
                let expectedMaterial = try personalVaultKeyStore.material(endpoint: url, deviceID: deviceID)
                let remote = try await client.personalVault(endpoint: url, session: session)
                guard remote.revision == 0 else {
                    throw SelectiveRemotePersonalVaultError.remoteVaultNotEmpty(remote.revision)
                }
                let credentials = try await personalVaultCredentialsIfRequested()
                let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
                    profiles: model.profiles,
                    credentials: credentials,
                    snippets: TerminalCommandHistoryStore.shared.templates(),
                    forwarding: model.independentPortForwards,
                    deviceID: deviceID
                )
                let setup = try await Task.detached(priority: .userInitiated) {
                    try SelectiveRemotePersonalVaultCrypto.createSetup(
                        exported.document,
                        recoveryPhrase: recoveryPhrase,
                        baseRevision: 0
                    )
                }.value
                guard isCurrentPresentation(generation, session: session) else { return }
                let result = try await client.putPersonalVault(endpoint: url, envelope: setup.envelope, session: session)
                guard !result.conflict else {
                    throw SelectiveRemotePersonalVaultError.uploadConflict(result.revision)
                }
                let documentHash = Data(SHA256.hash(data: try exported.document.encoded()))
                let material = try SelectiveRemotePersonalVaultKeyMaterial(
                    vaultID: remote.id,
                    vaultKey: setup.vaultKey,
                    wrappedKey: setup.envelope.wrappedKey,
                    revision: result.revision,
                    documentHash: documentHash,
                    includesCredentials: !credentials.isEmpty
                )
                try await client.savePersonalVaultMaterial(material, session: session, deviceID: deviceID, keyStore: personalVaultKeyStore, replacing: expectedMaterial)
                guard isCurrentPresentation(generation, session: session) else { return }
                personalVaultSetup = .connected
                personalVaultRevision = result.revision
                personalVaultMessage = UpdateLocalization.text(
                    ru: "Защищённая автосинхронизация включена. Первая ревизия r\(result.revision) отправлена; сохранённые credential-записи будут сохраняться при фоновых обновлениях.",
                    en: "Secure automatic sync is enabled. Initial revision r\(result.revision) was uploaded; stored credential records will be preserved during background updates."
                )
                personalVaultMessageIsError = false
                personalVaultUploading = false
                accountPhase = .signedIn
                closePersonalVaultUploadSheet()
                NotificationCenter.default.post(name: .selectiveRemotePersonalVaultSyncNow, object: nil)
            } catch {
                guard isCurrentPresentation(generation, session: session) else { return }
                personalVaultUploading = false
                accountPhase = .signedIn
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

    private var initialVaultDifferencesSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(UpdateLocalization.text(ru: "Расхождения в Personal Vault", en: "Personal Vault differences"))
                .font(.title2.weight(.semibold))
            Text(UpdateLocalization.text(
                ru: "Сверьте отмеченные записи на Mac и в Cloud. После этого снова нажмите «Завершить подключение».",
                en: "Review the listed records on this Mac and in Cloud, then choose Finish Connecting again."
            ))
            .foregroundStyle(.secondary)
            List(initialVaultDifferences) { difference in
                VStack(alignment: .leading, spacing: 4) {
                    Text(difference.title).font(.headline)
                    if difference.deletedInCloud {
                        Text(UpdateLocalization.text(ru: "Запись удалена в Cloud", en: "Deleted in Cloud"))
                    } else if difference.mayContainDifferentPassword {
                        Text(UpdateLocalization.text(
                            ru: "Проверьте настройки и учётные данные",
                            en: "Check the settings and credentials"
                        ))
                    } else {
                        Text(UpdateLocalization.text(ru: "Настройки различаются", en: "Settings differ"))
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button(UpdateLocalization.text(ru: "Готово", en: "Done")) {
                    showsInitialVaultDifferences = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 480, minHeight: 325)
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

    private enum PersonalVaultSetup {
        case checking, empty, needsUnlock, initialDownload, connected
    }

    private enum AccountPhase: Equatable {
        case signedOut
        case restoring
        case signingIn
        case registering
        case signedIn
        case connectingPersonalVault
        case refreshing
        case signingOut

        var isBusy: Bool {
            switch self {
            case .restoring, .signingIn, .registering, .connectingPersonalVault, .refreshing, .signingOut: true
            case .signedOut, .signedIn: false
            }
        }
    }
}
