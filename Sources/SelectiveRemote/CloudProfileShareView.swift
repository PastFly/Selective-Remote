import SwiftUI

enum SelectiveRemoteCloudProfileShareError: LocalizedError {
    case signInRequired
    case noWritableTeam
    case noVault
    case initializationRequiresManager
    case conflict
    case savedPasswordUnavailable

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            UpdateLocalization.text(ru: "Сначала войдите в Cloud.", en: "Sign in to Cloud first.")
        case .noWritableTeam:
            UpdateLocalization.text(ru: "Нет Team с правом записи.", en: "No Team allows you to write.")
        case .noVault:
            UpdateLocalization.text(ru: "В выбранной Team нет Shared Vault.", en: "The selected Team has no Shared Vault.")
        case .initializationRequiresManager:
            UpdateLocalization.text(
                ru: "Пустую Team Vault сначала должен инициализировать Owner или Admin.",
                en: "An Owner or Admin must initialize the empty Team Vault first."
            )
        case .conflict:
            UpdateLocalization.text(
                ru: "Team Vault изменилась параллельно. Откройте её в Cloud и разрешите конфликт.",
                en: "The Team Vault changed concurrently. Open it in Cloud and resolve the conflict."
            )
        case .savedPasswordUnavailable:
            UpdateLocalization.text(
                ru: "Выбранный сохранённый пароль не удалось прочитать из Keychain.",
                en: "The selected saved password could not be read from Keychain."
            )
        }
    }
}

struct SelectiveRemoteCloudProfileShareView: View {
    let profile: ConnectionProfile

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var teamHostStore = SelectiveRemoteTeamHostStore.shared
    @AppStorage("SelectiveRemote.cloud.endpoint.v1") private var endpoint = SelectiveRemoteCloudEndpoint.production
    @AppStorage("SelectiveRemote.cloud.device-id.v1") private var storedDeviceID = ""
    @State private var teams: [SelectiveRemoteCloudTeam] = []
    @State private var vaults: [SelectiveRemoteCloudSharedVault] = []
    @State private var selectedTeamID: UUID?
    @State private var selectedVaultID: UUID?
    @State private var isLoading = true
    @State private var isSharing = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var needsDeviceWrapper = false
    @State private var teamSearch = ""
    @State private var includeUsername = true
    @State private var includePassword = false
    @State private var includeGatewayPassword = false
    @State private var includeFolder = true
    @State private var sharedFolder: String

    private let client = SelectiveRemoteCloudAPIClient()
    private let identityManager = SelectiveRemoteTeamDeviceIdentityManager()

    init(profile: ConnectionProfile) {
        self.profile = profile
        _sharedFolder = State(initialValue: profile.group)
    }

    private var visibleTeams: [SelectiveRemoteCloudTeam] {
        let query = teamSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return teams }
        return teams.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var primaryCredentialKind: KeychainCredentialKind? {
        switch profile.connectionType {
        case .rdp: .rdp
        case .ssh, .telnet: .ssh
        case .serial: nil
        }
    }

    private var hasSavedPrimaryPassword: Bool {
        guard let kind = primaryCredentialKind else { return false }
        return KeychainService.passwordExists(
            reference: KeychainService.credentialReference(profileID: profile.id, kind: kind)
        )
    }

    private var hasSavedGatewayPassword: Bool {
        !profile.gatewayHost.isEmpty && KeychainService.passwordExists(
            reference: KeychainService.credentialReference(profileID: profile.id, kind: .gateway)
        )
    }

    private var availableTeamFolders: [String] {
        Array(Set(teamHostStore.hosts.filter {
            $0.teamID == selectedTeamID && $0.vaultID == selectedVaultID
        }.map { $0.profile.group }.filter { !$0.isEmpty }))
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(UpdateLocalization.text(ru: "Поделиться Host с командой", en: "Share Host with a Team"))
                .font(.title2.bold())
            LabeledContent(UpdateLocalization.text(ru: "Host", en: "Host")) {
                Text(profile.friendlyName).lineLimit(1)
            }

            if isLoading {
                HStack { ProgressView().controlSize(.small); Text("Cloud…") }
            } else {
                GroupBox(UpdateLocalization.text(ru: "Команда", en: "Team")) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(
                                UpdateLocalization.text(ru: "Найти среди команд", en: "Search Teams"),
                                text: $teamSearch
                            )
                            .textFieldStyle(.plain)
                            Text("\(visibleTeams.count) / \(teams.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))

                        List(visibleTeams, selection: $selectedTeamID) { team in
                            HStack {
                                Label(team.name, systemImage: "person.3.fill")
                                Spacer()
                                Text(team.role.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(team.id))
                        }
                        .listStyle(.inset)
                        .frame(height: min(CGFloat(max(visibleTeams.count, 1)) * 34, 150))
                    }
                    .padding(4)
                }

                Picker("Team Vault", selection: $selectedVaultID) {
                    ForEach(vaults) { vault in Text(vault.name).tag(Optional(vault.id)) }
                }
                .disabled(selectedTeamID == nil)
            }

            GroupBox(UpdateLocalization.text(ru: "Что передать", en: "Share Contents")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        UpdateLocalization.text(ru: "Логин и параметры подключения", en: "Username and connection settings"),
                        isOn: $includeUsername
                    )

                    HStack {
                        Toggle(UpdateLocalization.text(ru: "Папка", en: "Folder"), isOn: $includeFolder)
                        TextField(
                            UpdateLocalization.text(ru: "Без папки", en: "No Folder"),
                            text: $sharedFolder
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(!includeFolder)
                        if !availableTeamFolders.isEmpty {
                            Menu(UpdateLocalization.text(ru: "Выбрать", en: "Choose")) {
                                Button(UpdateLocalization.text(ru: "Без папки", en: "No Folder")) {
                                    includeFolder = true
                                    sharedFolder = ""
                                }
                                ForEach(availableTeamFolders, id: \.self) { folder in
                                    Button(folder) {
                                        includeFolder = true
                                        sharedFolder = folder
                                    }
                                }
                            }
                        }
                    }

                    if hasSavedPrimaryPassword {
                        Toggle(
                            UpdateLocalization.text(ru: "Сохранённый пароль", en: "Saved Password"),
                            isOn: $includePassword
                        )
                    }
                    if hasSavedGatewayPassword {
                        Toggle(
                            UpdateLocalization.text(ru: "Сохранённый пароль Gateway", en: "Saved Gateway Password"),
                            isOn: $includeGatewayPassword
                        )
                    }
                    if !profile.portForwards.isEmpty {
                        Label(
                            UpdateLocalization.text(
                                ru: "Правила Forwarding (\(profile.portForwards.count)) пока останутся локальными: для них будет отдельный командный объект с явным запуском участником.",
                                en: "Forwarding rules (\(profile.portForwards.count)) remain local for now; they will use a separate Team object that each member starts explicitly."
                            ),
                            systemImage: "arrow.left.arrow.right"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Label(
                        UpdateLocalization.text(
                            ru: "Пароли добавляются только по явному выбору и после подтверждения владельца Mac. В Cloud уходит только E2EE-шифротекст.",
                            en: "Passwords are added only by explicit choice and after Mac owner authentication. Cloud receives E2EE ciphertext only."
                        ),
                        systemImage: "lock.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            if let message {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(messageIsError ? Color.orange : Color.green)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if needsDeviceWrapper {
                        Button(
                            UpdateLocalization.text(
                                ru: "Открыть Team Vaults в браузере…",
                                en: "Open Team Vaults in Browser…"
                            ),
                            systemImage: "safari"
                        ) {
                            openCloudWorkspace()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(UpdateLocalization.text(ru: "Закрыть", en: "Close")) { dismiss() }
                    .disabled(isSharing)
                Button(UpdateLocalization.text(ru: "Зашифровать и поделиться", en: "Encrypt and Share")) {
                    share()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || isSharing || selectedVaultID == nil)
            }
        }
        .padding(24)
        .frame(width: 640)
        .task { await load() }
        .onChange(of: selectedTeamID) { _, _ in Task { await loadVaults() } }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try SelectiveRemoteCloudEndpoint.normalized(endpoint)
            guard await client.hasStoredSession(endpoint: url) else {
                throw SelectiveRemoteCloudProfileShareError.signInRequired
            }
            _ = try await client.currentUser(endpoint: url)
            teams = try await client.teams(endpoint: url)
                .filter { $0.role != .viewer }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !teams.isEmpty else { throw SelectiveRemoteCloudProfileShareError.noWritableTeam }
            selectedTeamID = teams[0].id
            await loadVaults()
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }

    @MainActor
    private func loadVaults() async {
        guard let teamID = selectedTeamID,
              let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint)
        else { return }
        do {
            vaults = try await client.sharedVaults(endpoint: url, teamID: teamID)
            selectedVaultID = vaults.first?.id
            if vaults.isEmpty { throw SelectiveRemoteCloudProfileShareError.noVault }
        } catch {
            vaults = []
            selectedVaultID = nil
            message = error.localizedDescription
            messageIsError = true
        }
    }

    @MainActor
    private func share() {
        guard let team = teams.first(where: { $0.id == selectedTeamID }),
              let vaultID = selectedVaultID,
              let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint)
        else { return }
        isSharing = true
        message = nil
        needsDeviceWrapper = false
        Task { @MainActor in
            defer { isSharing = false }
            do {
                let deviceID = try resolvedDeviceID()
                let identity = try await identityManager.identity(endpoint: url, deviceID: deviceID)
                let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
                    endpoint: url,
                    remote: client,
                    snapshots: SelectiveRemoteTeamVaultFileSnapshotStore()
                )
                let refreshed = try await coordinator.refresh(teamID: team.id, vaultID: vaultID, identity: identity)
                var sharedProfile = profile
                sharedProfile.group = includeFolder
                    ? SelectiveRemoteHostFolderPath.normalize(sharedFolder)
                    : ""
                if !includeUsername {
                    sharedProfile.username = ""
                    sharedProfile.gatewayUsername = ""
                }
                let credentials = try await credentialsForShare()
                let sharedRecords = try SelectiveRemotePersonalVaultExporter.makeExport(
                    profiles: [sharedProfile], credentials: credentials,
                    snippets: [], forwarding: [], deviceID: deviceID
                ).document.records

                let outcome: SelectiveRemoteTeamVaultPushOutcome
                switch refreshed {
                case .empty:
                    guard team.role == .owner || team.role == .admin else {
                        throw SelectiveRemoteCloudProfileShareError.initializationRequiresManager
                    }
                    let devices = try await client.teamKeyDevices(endpoint: url, teamID: team.id, vaultID: vaultID)
                    let document = try SelectiveRemoteVaultDocument(records: sharedRecords)
                    outcome = try await coordinator.initialize(
                        payload: document.encoded(), teamID: team.id, vaultID: vaultID,
                        identity: identity, keyDevices: devices
                    )
                case let .synchronized(snapshot), let .localChanges(snapshot):
                    let current = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
                    let sharedIDs = Set(sharedRecords.map(\.id))
                    let records = try sharedRecords.map { shared in
                        let priorVersion = current.records.first(where: { $0.id == shared.id })?.version
                            ?? current.tombstones.first(where: { $0.id == shared.id })?.version
                        return try SelectiveRemoteVaultRecord(
                            id: shared.id, type: shared.type,
                            version: try priorVersion?.incrementing(deviceID)
                                ?? SelectiveRemoteVaultVersion([deviceID: 1]),
                            modifiedAt: shared.modifiedAt, data: shared.data
                        )
                    }
                    let document = try SelectiveRemoteVaultDocument(
                        records: current.records.filter { !sharedIDs.contains($0.id) } + records,
                        tombstones: current.tombstones.filter { !sharedIDs.contains($0.id) }
                    )
                    _ = try await coordinator.stage(
                        document.encoded(), teamID: team.id, vaultID: vaultID, identity: identity
                    )
                    outcome = try await coordinator.push(teamID: team.id, vaultID: vaultID, identity: identity)
                case .conflict:
                    throw SelectiveRemoteCloudProfileShareError.conflict
                }
                guard case .uploaded = outcome else { throw SelectiveRemoteCloudProfileShareError.conflict }
                message = UpdateLocalization.text(ru: "Host зашифрован и добавлен в Team Vault.", en: "The Host was encrypted and added to the Team Vault.")
                messageIsError = false
            } catch SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper {
                message = SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper.localizedDescription
                messageIsError = true
                needsDeviceWrapper = true
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
        }
    }

    @MainActor
    private func credentialsForShare() async throws
        -> [SelectiveRemotePersonalVaultCredentialInput]
    {
        guard includePassword || includeGatewayPassword else { return [] }
        try await KeychainService.authenticateDeviceOwner(reason: UpdateLocalization.text(
            ru: "Разрешить добавить выбранные пароли в зашифрованный Team Vault",
            en: "Allow selected passwords to be added to the encrypted Team Vault"
        ))
        var result: [SelectiveRemotePersonalVaultCredentialInput] = []
        if includePassword, let kind = primaryCredentialKind {
            guard let secret = try KeychainService.readPassword(profileID: profile.id, kind: kind),
                  !secret.isEmpty
            else { throw SelectiveRemoteCloudProfileShareError.savedPasswordUnavailable }
            result.append(.init(
                sourceID: profile.id,
                kind: kind,
                title: "\(profile.friendlyName) · \(profile.connectionType.title)",
                username: includeUsername ? profile.username : "",
                secret: secret
            ))
        }
        if includeGatewayPassword {
            guard let secret = try KeychainService.readPassword(profileID: profile.id, kind: .gateway),
                  !secret.isEmpty
            else { throw SelectiveRemoteCloudProfileShareError.savedPasswordUnavailable }
            result.append(.init(
                sourceID: profile.id,
                kind: .gateway,
                title: "\(profile.friendlyName) · Gateway",
                username: includeUsername ? profile.gatewayUsername : "",
                secret: secret
            ))
        }
        return result
    }

    @MainActor
    private func openCloudWorkspace() {
        guard let url = try? SelectiveRemoteCloudEndpoint.normalized(endpoint) else { return }
        openURL(url)
    }

    @MainActor
    private func resolvedDeviceID() throws -> UUID {
        if let value = UUID(uuidString: storedDeviceID), value.isSelectiveRemoteCloudUUID { return value }
        let value = UUID()
        storedDeviceID = value.canonicalCloudString
        return value
    }
}
