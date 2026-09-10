import SwiftUI

struct SelectiveRemoteCloudTeamManagementView: View {
    let endpoint: URL
    let client: SelectiveRemoteCloudAPIClient
    let onInventoryChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var teams: [SelectiveRemoteCloudTeam] = []
    @State private var selectedTeamID: UUID?
    @State private var members: [SelectiveRemoteCloudTeamMember] = []
    @State private var vaults: [SelectiveRemoteCloudSharedVault] = []
    @State private var newTeamName = ""
    @State private var invitationEmail = ""
    @State private var invitationRole = SelectiveRemoteCloudTeamRole.viewer
    @State private var newVaultName = ""
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTeamID) {
                Section(UpdateLocalization.text(ru: "Команды", en: "Teams")) {
                    ForEach(teams) { team in
                        Label(team.name, systemImage: "person.3.fill")
                            .tag(team.id)
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
        .frame(minWidth: 820, minHeight: 600)
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
                    .tabItem { Label("Team Hosts", systemImage: "server.rack") }
            }
            .padding()
        }
    }

    private func membersView(_ team: SelectiveRemoteCloudTeam) -> some View {
        Form {
            Section(UpdateLocalization.text(ru: "Участники", en: "Members")) {
                ForEach(members) { member in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(member.displayName).font(.headline)
                            Text("@\(member.username)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(roleTitle(member.role)).foregroundStyle(.secondary)
                    }
                }
            }

            if team.role == .owner || team.role == .admin {
                Section(UpdateLocalization.text(ru: "Пригласить на 48 часов", en: "Invite for 48 Hours")) {
                    TextField("Email", text: $invitationEmail)
                    Picker(UpdateLocalization.text(ru: "Роль", en: "Role"), selection: $invitationRole) {
                        Text(roleTitle(.viewer)).tag(SelectiveRemoteCloudTeamRole.viewer)
                        Text(roleTitle(.editor)).tag(SelectiveRemoteCloudTeamRole.editor)
                        if team.role == .owner {
                            Text(roleTitle(.admin)).tag(SelectiveRemoteCloudTeamRole.admin)
                        }
                    }
                    Button(UpdateLocalization.text(ru: "Отправить приглашение", en: "Send Invitation")) {
                        invite(team)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || normalized(invitationEmail).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func vaultsView(_ team: SelectiveRemoteCloudTeam) -> some View {
        Form {
            Section("Team Vaults") {
                ForEach(vaults) { vault in
                    HStack {
                        Label(vault.name, systemImage: "lock.square.stack.fill")
                        Spacer()
                        Text("r\(vault.revision) · k\(vault.keyGeneration)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
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
            Label("Team Hosts", systemImage: "server.rack")
        } description: {
            Text(UpdateLocalization.text(
                ru: "Хосты добавляются из контекстного меню основного списка: «Поделиться с командой…». Просмотр и редактирование Team Hosts появятся здесь следующим этапом.",
                en: "Add hosts from the main list context menu using Share with Team. Team Host browsing and editing will be added here next."
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
            teams = try await client.teams(endpoint: endpoint)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
            vaults = []
            return
        }
        isBusy = true
        errorMessage = nil
        do {
            async let loadedMembers = client.teamMembers(endpoint: endpoint, teamID: team.id)
            async let loadedVaults = client.sharedVaults(endpoint: endpoint, teamID: team.id)
            let (memberResult, vaultResult) = try await (loadedMembers, loadedVaults)
            members = memberResult.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            vaults = vaultResult.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
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
        let email = normalized(invitationEmail)
        guard !email.isEmpty else { return }
        Task { @MainActor in
            isBusy = true
            errorMessage = nil
            do {
                _ = try await client.inviteTeamMember(
                    endpoint: endpoint,
                    teamID: team.id,
                    email: email,
                    role: invitationRole
                )
                invitationEmail = ""
                statusMessage = UpdateLocalization.text(
                    ru: "Приглашение отправлено на 48 часов.",
                    en: "Invitation sent for 48 hours."
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
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
