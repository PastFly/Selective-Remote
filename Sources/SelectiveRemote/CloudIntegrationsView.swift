import SwiftUI

struct CloudIntegrationsView: View {
    @ObservedObject var store: CloudIntegrationStore
    @EnvironmentObject private var model: AppModel

    let onOpenProfile: (UUID, QuickConnectAction) -> Void

    @State private var editorRequest: CloudAccountEditorRequest?
    @State private var searchText = ""
    @State private var showsDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                accountSidebar
                    .frame(minWidth: 220, idealWidth: 245, maxWidth: 300)
                inventoryContent
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editorRequest) { request in
            CloudAccountEditorView(
                account: request.account,
                secret: request.secret,
                onSave: { account, secret in
                    do {
                        try store.save(account: account, secret: secret)
                        editorRequest = nil
                        Task { await refresh(account) }
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                },
                onCancel: { editorRequest = nil }
            )
        }
        .alert(
            UpdateLocalization.text(ru: "Удалить облачный аккаунт?", en: "Remove Cloud Account?"),
            isPresented: $showsDeleteConfirmation
        ) {
            Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), role: .cancel) { }
            Button(UpdateLocalization.text(ru: "Удалить", en: "Remove"), role: .destructive) {
                if let account = store.selectedAccount { store.remove(account) }
            }
        } message: {
            Text(
                UpdateLocalization.text(
                    ru: "Будут удалены настройки аккаунта и его секрет из Keychain. Уже импортированные SSH-профили сохранятся.",
                    en: "The account settings and its Keychain secret will be removed. Existing imported SSH profiles will remain."
                )
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("Cloud")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(
                    UpdateLocalization.text(
                        ru: "AWS, Microsoft Azure и DigitalOcean · импорт VM в обычные SSH-профили",
                        en: "AWS, Microsoft Azure, and DigitalOcean · import VMs into regular SSH profiles"
                    )
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(CloudProvider.allCases) { provider in
                    Button(provider.title, systemImage: provider.systemImage) {
                        editorRequest = CloudAccountEditorRequest(
                            account: CloudAccount(provider: provider),
                            secret: CloudAccountSecret()
                        )
                    }
                }
            } label: {
                Label(
                    UpdateLocalization.text(ru: "Добавить аккаунт", en: "Add Account"),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var accountSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UpdateLocalization.text(ru: "АККАУНТЫ", en: "ACCOUNTS"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if store.accounts.isEmpty {
                ContentUnavailableView {
                    Label(
                        UpdateLocalization.text(ru: "Нет аккаунтов", en: "No Accounts"),
                        systemImage: "cloud"
                    )
                } description: {
                    Text(
                        UpdateLocalization.text(
                            ru: "Добавьте облачный аккаунт. Секрет будет храниться только в Keychain.",
                            en: "Add a cloud account. Its secret will be stored only in Keychain."
                        )
                    )
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.accounts) { account in
                            accountRow(account)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    private func accountRow(_ account: CloudAccount) -> some View {
        Button {
            store.selectedAccountID = account.id
            if store.instances(for: account.id).isEmpty {
                Task { await refresh(account) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: account.provider.systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(account.provider.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.refreshingAccountIDs.contains(account.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(store.instances(for: account.id).count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            store.selectedAccountID == account.id
                ? Color.accentColor.opacity(0.16)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if let account = store.selectedAccount {
            VStack(spacing: 0) {
                inventoryToolbar(account)
                if let error = store.errorMessage {
                    errorBanner(error)
                }
                let instances = filteredInstances(account)
                if store.refreshingAccountIDs.contains(account.id) && instances.isEmpty {
                    ProgressView(UpdateLocalization.text(ru: "Получаем список VM…", en: "Loading VMs…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if instances.isEmpty {
                    ContentUnavailableView {
                        Label(
                            UpdateLocalization.text(ru: "VM не найдены", en: "No VMs Found"),
                            systemImage: "server.rack"
                        )
                    } description: {
                        Text(
                            UpdateLocalization.text(
                                ru: "Обновите аккаунт или измените строку поиска.",
                                en: "Refresh the account or change the search."
                            )
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    instanceList(instances, account: account)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Cloud", systemImage: "cloud")
            } description: {
                Text(
                    UpdateLocalization.text(
                        ru: "Выберите или добавьте облачный аккаунт.",
                        en: "Select or add a cloud account."
                    )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func inventoryToolbar(_ account: CloudAccount) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.title3.bold())
                if let date = account.lastRefreshedAt {
                    Text(
                        UpdateLocalization.text(
                            ru: "Обновлено \(date.formatted(date: .abbreviated, time: .shortened))",
                            en: "Updated \(date.formatted(date: .abbreviated, time: .shortened))"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField(
                UpdateLocalization.text(ru: "Поиск VM", en: "Search VMs"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)

            Picker("", selection: groupingBinding(account)) {
                ForEach(CloudGroupingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 145)

            Button {
                Task { await refresh(account) }
            } label: {
                if store.refreshingAccountIDs.contains(account.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        UpdateLocalization.text(ru: "Обновить", en: "Refresh"),
                        systemImage: "arrow.clockwise"
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(store.refreshingAccountIDs.contains(account.id))

            Menu {
                Button(UpdateLocalization.text(ru: "Изменить аккаунт", en: "Edit Account"), systemImage: "pencil") {
                    editorRequest = CloudAccountEditorRequest(
                        account: account,
                        secret: store.secret(for: account.id)
                    )
                }
                Divider()
                Button(
                    UpdateLocalization.text(ru: "Удалить аккаунт", en: "Remove Account"),
                    systemImage: "trash",
                    role: .destructive
                ) {
                    showsDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(3)
            Spacer()
            Button(UpdateLocalization.text(ru: "Закрыть", en: "Dismiss")) {
                store.errorMessage = nil
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.08))
    }

    private func instanceList(_ instances: [CloudInstance], account: CloudAccount) -> some View {
        let grouped = Dictionary(grouping: instances) { store.groupName(for: $0, account: account) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(grouped.keys.sorted(), id: \.self) { group in
                    Section {
                        ForEach(grouped[group] ?? []) { instance in
                            instanceRow(instance, account: account)
                        }
                    } header: {
                        HStack {
                            Text(group).font(.headline)
                            Text("\(grouped[group]?.count ?? 0)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func instanceRow(_ instance: CloudInstance, account: CloudAccount) -> some View {
        let profileID = importedProfileID(instance, account: account)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(stateColor(instance.state).opacity(0.12))
                Image(systemName: instance.state.canConnect ? "server.rack" : "power")
                    .foregroundStyle(stateColor(instance.state))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(instance.name).font(.body.weight(.semibold))
                    Text(instance.state.title)
                        .font(.caption2.bold())
                        .foregroundStyle(stateColor(instance.state))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateColor(instance.state).opacity(0.10), in: Capsule())
                    if profileID != nil {
                        Label(
                            UpdateLocalization.text(ru: "Импортирована", en: "Imported"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.green)
                    }
                }
                HStack(spacing: 10) {
                    Text(instance.preferredAddress.isEmpty ? "—" : instance.preferredAddress)
                    Text(instance.region)
                    if !instance.networkName.isEmpty { Text(instance.networkName) }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                if !instance.sortedTags.isEmpty {
                    Text(instance.sortedTags.prefix(4).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            if let profileID {
                Button(
                    UpdateLocalization.text(ru: "Открыть SSH", en: "Open SSH"),
                    systemImage: "terminal"
                ) {
                    onOpenProfile(profileID, .terminal)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!instance.state.canConnect || instance.preferredAddress.isEmpty)
                Button(
                    UpdateLocalization.text(ru: "Открыть SFTP", en: "Open SFTP"),
                    systemImage: "folder.badge.gearshape"
                ) {
                    onOpenProfile(profileID, .sftp)
                }
                .buttonStyle(.bordered)
                .disabled(!instance.state.canConnect || instance.preferredAddress.isEmpty)
            } else {
                Button(
                    UpdateLocalization.text(ru: "Импортировать", en: "Import"),
                    systemImage: "square.and.arrow.down"
                ) {
                    _ = model.importCloudInstance(
                        instance,
                        account: account,
                        group: store.groupName(for: instance, account: account)
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(instance.preferredAddress.isEmpty)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private func groupingBinding(_ account: CloudAccount) -> Binding<CloudGroupingMode> {
        Binding(
            get: { store.accounts.first(where: { $0.id == account.id })?.groupingMode ?? .region },
            set: { value in
                var updated = account
                updated.groupingMode = value
                try? store.save(account: updated, secret: CloudAccountSecret())
            }
        )
    }

    private func filteredInstances(_ account: CloudAccount) -> [CloudInstance] {
        let values = store.instances(for: account.id)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return values }
        return values.filter { instance in
            instance.name.localizedCaseInsensitiveContains(needle)
                || instance.preferredAddress.localizedCaseInsensitiveContains(needle)
                || instance.region.localizedCaseInsensitiveContains(needle)
                || instance.sortedTags.contains(where: { $0.localizedCaseInsensitiveContains(needle) })
        }
    }

    private func importedProfileID(_ instance: CloudInstance, account: CloudAccount) -> UUID? {
        model.profiles.first(where: {
            $0.cloudAccountID == account.id && $0.cloudResourceID == instance.resourceID
        })?.id
    }

    private func stateColor(_ state: CloudInstanceState) -> Color {
        switch state {
        case .running: .green
        case .pending, .stopping: .orange
        case .terminated: .red
        case .stopped, .unknown: .secondary
        }
    }

    private func refresh(_ account: CloudAccount) async {
        await store.refresh(account)
        model.refreshCloudMetadata(store.instances(for: account.id), account: account)
    }
}

private struct CloudAccountEditorRequest: Identifiable {
    let account: CloudAccount
    let secret: CloudAccountSecret
    var id: UUID { account.id }
}

private struct CloudAccountEditorView: View {
    @State private var account: CloudAccount
    @State private var secret: CloudAccountSecret

    let onSave: (CloudAccount, CloudAccountSecret) -> Void
    let onCancel: () -> Void

    init(
        account: CloudAccount,
        secret: CloudAccountSecret,
        onSave: @escaping (CloudAccount, CloudAccountSecret) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _account = State(initialValue: account)
        _secret = State(initialValue: secret)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: account.provider.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.provider.title).font(.title3.bold())
                    Text(
                        UpdateLocalization.text(
                            ru: "Секреты сохраняются только в Keychain",
                            en: "Secrets are stored only in Keychain"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Form {
                Section(UpdateLocalization.text(ru: "Аккаунт", en: "Account")) {
                    TextField(UpdateLocalization.text(ru: "Название", en: "Name"), text: $account.name)
                    TextField(
                        UpdateLocalization.text(ru: "SSH-пользователь по умолчанию", en: "Default SSH Username"),
                        text: $account.defaultUsername
                    )
                    Picker(UpdateLocalization.text(ru: "Группировать по", en: "Group By"), selection: $account.groupingMode) {
                        ForEach(CloudGroupingMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }

                providerFields
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), action: onCancel)
                Spacer()
                Button(UpdateLocalization.text(ru: "Сохранить и обновить", en: "Save and Refresh")) {
                    onSave(account, secret)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 560, height: editorHeight)
    }

    @ViewBuilder
    private var providerFields: some View {
        switch account.provider {
        case .aws:
            Section("AWS") {
                TextField(UpdateLocalization.text(ru: "Регион", en: "Region"), text: $account.region)
                TextField("Access Key ID", text: $secret.accessKeyID)
                SecureField("Secret Access Key", text: $secret.secretAccessKey)
                SecureField(
                    UpdateLocalization.text(ru: "Session Token — необязательно", en: "Session Token — Optional"),
                    text: $secret.sessionToken
                )
            }
        case .azure:
            Section("Microsoft Azure") {
                TextField("Tenant ID", text: $account.tenantID)
                TextField("Client ID", text: $account.clientID)
                SecureField("Client Secret", text: $secret.clientSecret)
                TextField("Subscription ID", text: $account.subscriptionID)
            }
        case .digitalOcean:
            Section("DigitalOcean") {
                SecureField("Personal Access Token", text: $secret.apiToken)
                TextField(
                    UpdateLocalization.text(ru: "Project ID — необязательно", en: "Project ID — Optional"),
                    text: $account.projectID
                )
            }
        }
    }

    private var isValid: Bool {
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              secret.isValid(for: account.provider) else { return false }
        switch account.provider {
        case .aws:
            return !account.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .azure:
            return !account.tenantID.isEmpty && !account.clientID.isEmpty && !account.subscriptionID.isEmpty
        case .digitalOcean:
            return true
        }
    }

    private var editorHeight: CGFloat {
        account.provider == .azure ? 590 : 535
    }
}
