import AppKit
import SwiftUI

struct SelectiveRemoteCloudTeamManagementView: View {
    let endpoint: URL
    let client: SelectiveRemoteCloudAPIClient
    let onInventoryChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var teams: [SelectiveRemoteCloudTeam] = []
    @State private var selectedTeamID: UUID?
    @State private var members: [SelectiveRemoteCloudTeamMember] = []
    @State private var memberSearch = ""
    @State private var memberRoleFilter = ""
    @State private var memberNextCursor: UUID?
    @State private var memberTotal = 0
    @State private var isLoadingMembers = false
    @State private var memberRequestID = UUID()
    @State private var vaults: [SelectiveRemoteCloudSharedVault] = []
    @State private var invitations: [SelectiveRemoteCloudTeamInvitation] = []
    @State private var pendingInvitations: [SelectiveRemoteCloudTeamInvitation] = []
    @State private var newTeamName = ""
    @State private var invitationUsername = ""
    @State private var invitationEmail = ""
    @State private var invitationRole = SelectiveRemoteCloudTeamRole.viewer
    @State private var latestInvitationURL: String?
    @State private var newVaultName = ""
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var synchronizingVaultID: UUID?
    @State private var renamingVaultID: UUID?
    @State private var vaultNameDraft = ""
    @AppStorage("SelectiveRemote.cloud.device-id.v1") private var storedDeviceID = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTeamID) {
                Section(UpdateLocalization.text(ru: "Команды", en: "Teams")) {
                    ForEach(teams) { team in
                        Label(team.name, systemImage: "person.3.fill")
                            .tag(team.id)
                    }
                }

                if !pendingInvitations.isEmpty {
                    Section(UpdateLocalization.text(ru: "Приглашения", en: "Invitations")) {
                        ForEach(pendingInvitations) { invitation in
                            Button {
                                accept(invitation)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(invitation.teamName ?? "Team")
                                    Text(roleTitle(invitation.role))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(isBusy)
                        }
                    }
                }

                Section(UpdateLocalization.text(ru: "Новая команда", en: "New Team")) {
                    TextField(UpdateLocalization.text(ru: "Название", en: "Name"), text: $newTeamName)
                    Button(UpdateLocalization.text(ru: "Создать Team", en: "Create Team"), systemImage: "plus") {
                        createTeam()
                    }
                    .disabled(isBusy || normalized(newTeamName).isEmpty)
                }
            }
            .navigationTitle(UpdateLocalization.text(ru: "Cloud Workspace", en: "Cloud Workspace"))
        } detail: {
            if let team = selectedTeam {
                teamDetail(team)
            } else {
                ContentUnavailableView(
                    UpdateLocalization.text(ru: "Выберите команду", en: "Select a Team"),
                    systemImage: "person.3"
                )
            }
        }
        .frame(
            minWidth: 1_020,
            idealWidth: 1_160,
            minHeight: 700,
            idealHeight: 800
        )
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(UpdateLocalization.text(ru: "Обновить", en: "Refresh"), systemImage: "arrow.clockwise") {
                    reload()
                }
                .disabled(isBusy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(UpdateLocalization.text(ru: "Готово", en: "Done")) { dismiss() }
            }
        }
        .task { await loadTeams() }
        .onChange(of: selectedTeamID) { _, _ in
            latestInvitationURL = nil
            renamingVaultID = nil
            vaultNameDraft = ""
            if selectedTeam?.role != .owner, invitationRole == .admin {
                invitationRole = .viewer
            }
            Task { await loadSelectedTeam() }
        }
    }

    private var selectedTeam: SelectiveRemoteCloudTeam? {
        teams.first { $0.id == selectedTeamID }
    }

    @ViewBuilder
    private func teamDetail(_ team: SelectiveRemoteCloudTeam) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(team.name).font(.title2.bold())
                    Text(roleTitle(team.role)).foregroundStyle(.secondary)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            .padding()

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.horizontal)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            TabView {
                membersView(team)
                    .tabItem { Label(UpdateLocalization.text(ru: "Участники", en: "Members"), systemImage: "person.2") }
                vaultsView(team)
                    .tabItem { Label("Team Vaults", systemImage: "lock.square.stack") }
                hostsView
                    .tabItem {
                        Label(UpdateLocalization.text(ru: "Хосты", en: "Hosts"), systemImage: "server.rack")
                    }
            }
            .padding()
        }
    }

    private func membersView(_ team: SelectiveRemoteCloudTeam) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    UpdateLocalization.text(ru: "Участники", en: "Members"),
                    systemImage: "person.2.fill"
                )
                .font(.headline)

                HStack(spacing: 10) {
                    Picker(UpdateLocalization.text(ru: "Роль", en: "Role"), selection: $memberRoleFilter) {
                        Text(UpdateLocalization.text(ru: "Все роли", en: "All Roles")).tag("")
                        Text(roleTitle(.owner)).tag(SelectiveRemoteCloudTeamRole.owner.rawValue)
                        Text(roleTitle(.admin)).tag(SelectiveRemoteCloudTeamRole.admin.rawValue)
                        Text(roleTitle(.editor)).tag(SelectiveRemoteCloudTeamRole.editor.rawValue)
                        Text(roleTitle(.viewer)).tag(SelectiveRemoteCloudTeamRole.viewer.rawValue)
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Text("\(members.count) / \(memberTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                List(members) { member in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.displayName).font(.headline)
                            Text("@\(member.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(roleTitle(member.role))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
                .searchable(
                    text: $memberSearch,
                    prompt: UpdateLocalization.text(ru: "Имя или @username", en: "Name or @username")
                )
                .task(id: memberSearch) {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    await loadMembers(team, reset: true)
                }
                .onChange(of: memberRoleFilter) { _, _ in
                    Task { await loadMembers(team, reset: true) }
                }

                if memberNextCursor != nil {
                    Button(UpdateLocalization.text(ru: "Показать ещё", en: "Load More")) {
                        Task { await loadMembers(team, reset: false) }
                    }
                    .disabled(isLoadingMembers)
                }
            }
            .padding(16)
            .frame(minWidth: 360, idealWidth: 430, maxWidth: 520)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if team.role == .owner || team.role == .admin {
                        usernameInvitationCard(team)
                        alternativeInvitationCard(team)
                        activeInvitationsCard
                    } else {
                        ContentUnavailableView(
                            UpdateLocalization.text(
                                ru: "Управление участниками недоступно",
                                en: "Member Management Unavailable"
                            ),
                            systemImage: "person.badge.shield.checkmark",
                            description: Text(UpdateLocalization.text(
                                ru: "Приглашения доступны владельцу и администраторам команды.",
                                en: "Invitations are available to the Team owner and administrators."
                            ))
                        )
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 480, maxWidth: .infinity)
        }
    }

    private func usernameInvitationCard(_ team: SelectiveRemoteCloudTeam) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextField("@username", text: $invitationUsername)
                    .textFieldStyle(.roundedBorder)
                Picker(UpdateLocalization.text(ru: "Роль", en: "Role"), selection: $invitationRole) {
                    Text(roleTitle(.viewer)).tag(SelectiveRemoteCloudTeamRole.viewer)
                    Text(roleTitle(.editor)).tag(SelectiveRemoteCloudTeamRole.editor)
                    if team.role == .owner {
                        Text(roleTitle(.admin)).tag(SelectiveRemoteCloudTeamRole.admin)
                    }
                }
                .pickerStyle(.segmented)
                Button(UpdateLocalization.text(ru: "Отправить приглашение", en: "Send Invitation")) {
                    invite(team)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy || normalized(invitationUsername).isEmpty)
            }
            .padding(4)
        } label: {
            Label(
                UpdateLocalization.text(ru: "Пригласить по username", en: "Invite by Username"),
                systemImage: "at"
            )
        }
    }

    private func alternativeInvitationCard(_ team: SelectiveRemoteCloudTeam) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("Email", text: $invitationEmail)
                        .textFieldStyle(.roundedBorder)
                    Button(UpdateLocalization.text(ru: "Пригласить", en: "Invite")) {
                        inviteByEmail(team)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || normalized(invitationEmail).isEmpty)
                }

                Divider()

                HStack {
                    Button(
                        UpdateLocalization.text(ru: "Создать одноразовую ссылку", en: "Create Single-Use Link"),
                        systemImage: "link.badge.plus"
                    ) {
                        createInvitationLink(team)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    Spacer()
                    if let latestInvitationURL {
                        Button(
                            UpdateLocalization.text(ru: "Скопировать", en: "Copy"),
                            systemImage: "doc.on.doc"
                        ) {
                            copyInvitationLink(latestInvitationURL)
                        }
                    }
                }

                if let latestInvitationURL {
                    Text(latestInvitationURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(4)
        } label: {
            Label(
                UpdateLocalization.text(ru: "Другие способы", en: "Other Methods"),
                systemImage: "paperplane"
            )
        }
    }

    private var activeInvitationsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if invitations.isEmpty {
                    Text(UpdateLocalization.text(
                        ru: "Активных приглашений нет.",
                        en: "There are no active invitations."
                    ))
                    .foregroundStyle(.secondary)
                }
                ForEach(invitations) { invitation in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(invitationTitle(invitation))
                            Text("\(roleTitle(invitation.role)) · \(invitation.expiresAt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(
                            UpdateLocalization.text(ru: "Отозвать", en: "Revoke"),
                            role: .destructive
                        ) {
                            cancel(invitation)
                        }
                        .disabled(isBusy)
                    }
                }
            }
            .padding(4)
        } label: {
            Label(
                UpdateLocalization.text(ru: "Активные приглашения", en: "Active Invitations"),
                systemImage: "clock.badge"
            )
        }
    }

    private func vaultsView(_ team: SelectiveRemoteCloudTeam) -> some View {
        Form {
            Section("Team Vaults") {
                ForEach(vaults) { vault in
                    HStack {
                        if renamingVaultID == vault.id {
                            TextField(
                                UpdateLocalization.text(ru: "Название Vault", en: "Vault Name"),
                                text: $vaultNameDraft
                            )
                            .textFieldStyle(.roundedBorder)
                        } else {
                            Label(vault.name, systemImage: "lock.square.stack.fill")
                        }
                        Spacer()
                        Text("r\(vault.revision) · k\(vault.keyGeneration)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button(UpdateLocalization.text(ru: "Открыть хосты", en: "Open Hosts")) {
                            NotificationCenter.default.post(
                                name: .selectiveRemoteOpenTeamHosts,
                                object: nil
                            )
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        Button(
                            UpdateLocalization.text(ru: "Синхронизировать", en: "Synchronize"),
                            systemImage: "arrow.triangle.2.circlepath"
                        ) {
                            synchronizeVault(vault)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || synchronizingVaultID != nil)
                        if team.role == .owner || team.role == .admin {
                            if renamingVaultID == vault.id {
                                Button(UpdateLocalization.text(ru: "Сохранить", en: "Save")) {
                                    renameVault(vault, team: team)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(normalized(vaultNameDraft).isEmpty || isBusy)
                                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) {
                                    renamingVaultID = nil
                                    vaultNameDraft = ""
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button(
                                    UpdateLocalization.text(ru: "Переименовать", en: "Rename"),
                                    systemImage: "pencil"
                                ) {
                                    renamingVaultID = vault.id
                                    vaultNameDraft = vault.name
                                }
                                .buttonStyle(.bordered)
                                .disabled(isBusy)
                            }
                        }
                    }
                }
            }

            if team.role == .owner || team.role == .admin {
                Section(UpdateLocalization.text(ru: "Новое хранилище", en: "New Shared Vault")) {
                    TextField(UpdateLocalization.text(ru: "Название Vault", en: "Vault Name"), text: $newVaultName)
                    Button(UpdateLocalization.text(ru: "Создать Vault", en: "Create Vault")) {
                        createVault(team)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || normalized(newVaultName).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hostsView: some View {
        ContentUnavailableView {
            Label(UpdateLocalization.text(ru: "Командные хосты", en: "Team Hosts"), systemImage: "server.rack")
        } description: {
            Text(UpdateLocalization.text(
                ru: "Просмотр, подключение, редактирование, папки и drag-and-drop доступны в разделе «Хосты» главного окна — переключите область на «Командные».",
                en: "Browse, connect, edit, organize, and drag Team Hosts in the main Hosts area by switching the scope to Team."
            ))
        }
    }

    private func reload() {
        Task { await loadTeams(preferredID: selectedTeamID) }
    }

    @MainActor
    private func loadTeams(preferredID: UUID? = nil) async {
        isBusy = true
        errorMessage = nil
        do {
            async let loadedTeams = client.teams(endpoint: endpoint)
            async let loadedInvitations = client.pendingTeamInvitations(endpoint: endpoint)
            let (teamResult, invitationResult) = try await (loadedTeams, loadedInvitations)
            teams = teamResult
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            pendingInvitations = invitationResult.sorted {
                ($0.teamName ?? "").localizedCaseInsensitiveCompare($1.teamName ?? "") == .orderedAscending
            }
            selectedTeamID = preferredID.flatMap { id in teams.contains { $0.id == id } ? id : nil }
                ?? teams.first?.id
            await loadSelectedTeam()
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    @MainActor
    private func loadSelectedTeam() async {
        guard let team = selectedTeam else {
            members = []
            memberNextCursor = nil
            memberTotal = 0
            vaults = []
            invitations = []
            return
        }
        isBusy = true
        errorMessage = nil
        let requestedMemberSearch = memberSearch
        let requestedMemberRole = memberRoleFilter
        let memberLoadID = UUID()
        memberRequestID = memberLoadID
        do {
            async let loadedMemberPage = client.teamMembersPage(
                endpoint: endpoint,
                teamID: team.id,
                search: requestedMemberSearch,
                role: SelectiveRemoteCloudTeamRole(rawValue: requestedMemberRole),
                limit: 50
            )
            async let loadedVaults = client.sharedVaults(endpoint: endpoint, teamID: team.id)
            let (memberPage, vaultResult) = try await (loadedMemberPage, loadedVaults)
            let invitationResult: [SelectiveRemoteCloudTeamInvitation]
            if team.role == .owner || team.role == .admin {
                invitationResult = try await client.teamInvitations(endpoint: endpoint, teamID: team.id)
            } else {
                invitationResult = []
            }
            if selectedTeamID == team.id,
               memberRequestID == memberLoadID,
               memberSearch == requestedMemberSearch,
               memberRoleFilter == requestedMemberRole {
                members = memberPage.members
                memberNextCursor = memberPage.nextCursor
                memberTotal = memberPage.total
            }
            vaults = vaultResult.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            invitations = invitationResult
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    @MainActor
    private func loadMembers(_ team: SelectiveRemoteCloudTeam, reset: Bool) async {
        guard selectedTeamID == team.id else { return }
        let requestedSearch = memberSearch
        let requestedRole = memberRoleFilter
        let requestedCursor = reset ? nil : memberNextCursor
        let requestID = UUID()
        memberRequestID = requestID
        isLoadingMembers = true
        errorMessage = nil
        do {
            let page = try await client.teamMembersPage(
                endpoint: endpoint,
                teamID: team.id,
                search: requestedSearch,
                role: SelectiveRemoteCloudTeamRole(rawValue: requestedRole),
                limit: 50,
                cursor: requestedCursor
            )
            if selectedTeamID == team.id,
               memberSearch == requestedSearch,
               memberRoleFilter == requestedRole {
                members = reset ? page.members : members + page.members
                memberNextCursor = page.nextCursor
                memberTotal = page.total
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if memberRequestID == requestID { isLoadingMembers = false }
    }

    private func createTeam() {
        let name = normalized(newTeamName)
        guard !name.isEmpty else { return }
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                let team = try await client.createTeam(endpoint: endpoint, name: name)
                newTeamName = ""
                statusMessage = UpdateLocalization.text(ru: "Team создана.", en: "Team created.")
                onInventoryChanged()
                await loadTeams(preferredID: team.id)
            } catch {
                errorMessage = error.localizedDescription
                isBusy = false
            }
        }
    }

    private func invite(_ team: SelectiveRemoteCloudTeam) {
        let username = normalized(invitationUsername)
        guard !username.isEmpty else { return }
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                _ = try await client.inviteTeamMember(
                    endpoint: endpoint,
                    teamID: team.id,
                    username: username,
                    role: invitationRole
                )
                invitationUsername = ""
                latestInvitationURL = nil
                statusMessage = UpdateLocalization.text(
                    ru: "Приглашение по @username создано на 48 часов.",
                    en: "The @username invitation is active for 48 hours."
                )
                await loadSelectedTeam()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func createInvitationLink(_ team: SelectiveRemoteCloudTeam) {
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                let invitation = try await client.createTeamInvitationLink(
                    endpoint: endpoint,
                    teamID: team.id,
                    role: invitationRole
                )
                guard let url = invitation.acceptanceURL else {
                    throw SelectiveRemoteCloudError.invalidResponse
                }
                latestInvitationURL = url
                statusMessage = UpdateLocalization.text(
                    ru: "Одноразовая ссылка создана на 48 часов.",
                    en: "A 48-hour single-use link was created."
                )
                await loadSelectedTeam()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func inviteByEmail(_ team: SelectiveRemoteCloudTeam) {
        let email = normalized(invitationEmail).lowercased()
        guard !email.isEmpty else { return }
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                _ = try await client.inviteTeamMember(endpoint: endpoint, teamID: team.id, email: email, role: invitationRole)
                invitationEmail = ""
                statusMessage = UpdateLocalization.text(ru: "Приглашение отправлено по email и действует 48 часов.", en: "The email invitation was sent and is active for 48 hours.")
                await loadSelectedTeam()
            } catch { errorMessage = error.localizedDescription }
            isBusy = false
        }
    }

    private func accept(_ invitation: SelectiveRemoteCloudTeamInvitation) {
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                _ = try await client.acceptTeamInvitation(endpoint: endpoint, invitationID: invitation.id)
                statusMessage = UpdateLocalization.text(ru: "Приглашение принято.", en: "Invitation accepted.")
                onInventoryChanged()
                await loadTeams(preferredID: invitation.teamID)
            } catch {
                errorMessage = error.localizedDescription
                isBusy = false
            }
        }
    }

    private func cancel(_ invitation: SelectiveRemoteCloudTeamInvitation) {
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                try await client.cancelTeamInvitation(
                    endpoint: endpoint,
                    teamID: invitation.teamID,
                    invitationID: invitation.id
                )
                if invitation.type == .link { latestInvitationURL = nil }
                statusMessage = UpdateLocalization.text(ru: "Приглашение отозвано.", en: "Invitation revoked.")
                await loadSelectedTeam()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func copyInvitationLink(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func invitationTitle(_ invitation: SelectiveRemoteCloudTeamInvitation) -> String {
        switch invitation.type {
        case .username:
            "@\(invitation.targetUsername ?? "")"
        case .link:
            UpdateLocalization.text(ru: "Одноразовая ссылка", en: "Single-use link")
        case .email:
            UpdateLocalization.text(ru: "Прежнее email-приглашение", en: "Legacy email invitation")
        }
    }

    private func createVault(_ team: SelectiveRemoteCloudTeam) {
        let name = normalized(newVaultName)
        guard !name.isEmpty else { return }
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                _ = try await client.createSharedVault(endpoint: endpoint, teamID: team.id, name: name)
                newVaultName = ""
                statusMessage = UpdateLocalization.text(ru: "Shared Vault создан.", en: "Shared Vault created.")
                onInventoryChanged()
                await loadSelectedTeam()
            } catch {
                errorMessage = error.localizedDescription
                isBusy = false
            }
        }
    }

    private func synchronizeVault(_ vault: SelectiveRemoteCloudSharedVault) {
        guard let deviceID = UUID(uuidString: storedDeviceID),
              deviceID.isSelectiveRemoteCloudUUID
        else {
            errorMessage = UpdateLocalization.text(
                ru: "Сначала войдите в Cloud на этом Mac и зарегистрируйте устройство.",
                en: "Sign in to Cloud on this Mac and register the device first."
            )
            return
        }
        Task { @MainActor in
            isBusy = true
            synchronizingVaultID = vault.id
            errorMessage = nil
            defer {
                synchronizingVaultID = nil
                isBusy = false
            }
            do {
                let report = try await SelectiveRemoteTeamVaultAutoSync.shared.synchronizeOnce(
                    endpoint: endpoint,
                    deviceID: deviceID
                )
                if report.failures > 0 || report.pendingWrappers > 0 || report.rotations > 0 {
                    let detail = report.lastFailure.map { " \($0)" } ?? ""
                    errorMessage = UpdateLocalization.text(
                        ru: "Синхронизация завершена не полностью: ошибок \(report.failures), ожидают wrapper \(report.pendingWrappers), требуют ротации \(report.rotations).",
                        en: "Synchronization was incomplete: \(report.failures) failures, \(report.pendingWrappers) pending wrappers, \(report.rotations) rotations required."
                    ) + detail
                } else {
                    statusMessage = UpdateLocalization.text(
                        ru: "Team Vaults синхронизированы: получено \(report.synchronizedVaults), отправлено \(report.uploadedVaults), выдано wrappers \(report.wrappersGranted).",
                        en: "Team Vaults synchronized: \(report.synchronizedVaults) received, \(report.uploadedVaults) uploaded, \(report.wrappersGranted) wrappers granted."
                    )
                }
                await loadSelectedTeam()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func renameVault(
        _ vault: SelectiveRemoteCloudSharedVault,
        team: SelectiveRemoteCloudTeam
    ) {
        let name = normalized(vaultNameDraft)
        guard !name.isEmpty else { return }
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                _ = try await client.renameSharedVault(
                    endpoint: endpoint,
                    teamID: team.id,
                    vaultID: vault.id,
                    name: name
                )
                renamingVaultID = nil
                vaultNameDraft = ""
                statusMessage = UpdateLocalization.text(
                    ru: "Team Vault переименован.",
                    en: "The Team Vault was renamed."
                )
                onInventoryChanged()
                await loadSelectedTeam()
            } catch {
                errorMessage = error.localizedDescription
                isBusy = false
            }
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func roleTitle(_ role: SelectiveRemoteCloudTeamRole) -> String {
        switch role {
        case .owner: UpdateLocalization.text(ru: "Владелец", en: "Owner")
        case .admin: UpdateLocalization.text(ru: "Администратор", en: "Admin")
        case .editor: UpdateLocalization.text(ru: "Редактор", en: "Editor")
        case .viewer: UpdateLocalization.text(ru: "Читатель", en: "Viewer")
        }
    }
}
