import SwiftUI

enum SelectiveRemoteCloudProfileShareError: LocalizedError {
    case signInRequired
    case noWritableTeam
    case noVault
    case initializationRequiresManager
    case conflict

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
        }
    }
}

struct SelectiveRemoteCloudProfileShareView: View {
    let profile: ConnectionProfile

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
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

    private let client = SelectiveRemoteCloudAPIClient()
    private let identityManager = SelectiveRemoteTeamDeviceIdentityManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(UpdateLocalization.text(ru: "Поделиться Host с командой", en: "Share Host with a Team"))
                .font(.title2.bold())
            LabeledContent(UpdateLocalization.text(ru: "Host", en: "Host")) {
                Text(profile.friendlyName).lineLimit(1)
            }

            if isLoading {
                HStack { ProgressView().controlSize(.small); Text("Cloud…") }
            } else {
                Picker("Team", selection: $selectedTeamID) {
                    ForEach(teams) { team in Text("\(team.name) · \(team.role.rawValue)").tag(Optional(team.id)) }
                }
                Picker("Shared Vault", selection: $selectedVaultID) {
                    ForEach(vaults) { vault in Text(vault.name).tag(Optional(vault.id)) }
                }
                .disabled(selectedTeamID == nil)
            }

            Text(UpdateLocalization.text(
                ru: "В Team Vault отправляется только выбранный профиль без сохранённого пароля. Данные шифруются на этом Mac.",
                en: "Only this profile is sent to the Team Vault, without its saved password. Data is encrypted on this Mac."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

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
        .frame(width: 520)
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
            teams = try await client.teams(endpoint: url).filter { $0.role != .viewer }
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
                let host = try SelectiveRemotePersonalVaultExporter.makeExport(
                    profiles: [profile], credentials: [], snippets: [], forwarding: [], deviceID: deviceID
                ).document.records[0]

                let outcome: SelectiveRemoteTeamVaultPushOutcome
                switch refreshed {
                case .empty:
                    guard team.role == .owner || team.role == .admin else {
                        throw SelectiveRemoteCloudProfileShareError.initializationRequiresManager
                    }
                    let devices = try await client.teamKeyDevices(endpoint: url, teamID: team.id, vaultID: vaultID)
                    let document = try SelectiveRemoteVaultDocument(records: [host])
                    outcome = try await coordinator.initialize(
                        payload: document.encoded(), teamID: team.id, vaultID: vaultID,
                        identity: identity, keyDevices: devices
                    )
                case let .synchronized(snapshot), let .localChanges(snapshot):
                    let current = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
                    let priorVersion = current.records.first(where: { $0.id == host.id })?.version
                        ?? current.tombstones.first(where: { $0.id == host.id })?.version
                    let record = try SelectiveRemoteVaultRecord(
                        id: host.id, type: .host,
                        version: try priorVersion?.incrementing(deviceID) ?? SelectiveRemoteVaultVersion([deviceID: 1]),
                        modifiedAt: host.modifiedAt, data: host.data
                    )
                    let document = try SelectiveRemoteVaultDocument(
                        records: current.records.filter { $0.id != host.id } + [record],
                        tombstones: current.tombstones.filter { $0.id != host.id }
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
