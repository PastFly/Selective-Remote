import SwiftUI

enum CredentialVaultPresentation {
    case sheet
    case embedded
}

struct CredentialVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let presentation: CredentialVaultPresentation
    let onOpenProfile: ((UUID) -> Void)?

    @State private var selectedKeyID: UUID?
    @State private var showsKeyGenerator = false
    @State private var installTargetProfileID: UUID?
    @State private var agentLoadedKeyIDs: Set<UUID> = []
    @State private var agentCheckError: String?
    @State private var checkingAgent = false

    init(
        presentation: CredentialVaultPresentation = .sheet,
        onOpenProfile: ((UUID) -> Void)? = nil
    ) {
        self.presentation = presentation
        self.onOpenProfile = onOpenProfile
    }

    private var sshProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending
            }
    }

    private var selectedKey: SSHKeyRecord? {
        guard let selectedKeyID else { return model.sshKeys.first }
        return model.sshKeys.first(where: { $0.id == selectedKeyID })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                keyList
                    .frame(minWidth: 300, idealWidth: 330)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        agentCard
                        credentialEntriesCard
                        if let key = selectedKey {
                            keyDetails(key)
                        } else {
                            ContentUnavailableView(
                                "SSH-ключи не добавлены",
                                systemImage: "key.slash",
                                description: Text(
                                    "Импортируйте существующий приватный ключ или создайте новый. "
                                        + "Приватные ключи остаются файлами в ~/.ssh."
                                )
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 560)
            }
        }
        .frame(minWidth: presentation == .sheet ? 920 : nil, minHeight: presentation == .sheet ? 640 : nil)
        .onAppear {
            if selectedKeyID == nil {
                selectedKeyID = model.selectedSSHKey?.id ?? model.sshKeys.first?.id
            }
            if installTargetProfileID == nil {
                installTargetProfileID = model.selectedProfile.connectionType == .ssh
                    ? model.selectedProfile.id
                    : sshProfiles.first?.id
            }
            refreshAgentState()
        }
        .onChange(of: model.sshKeys) { _, keys in
            if let selectedKeyID,
               !keys.contains(where: { $0.id == selectedKeyID }) {
                self.selectedKeyID = keys.first?.id
            }
            refreshAgentState()
        }
        .sheet(isPresented: $showsKeyGenerator) {
            SSHKeyGenerationView { request, session in
                model.generateSSHKeyGlobally(request, session: session)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Keychain")
                    .font(.system(size: presentation == .embedded ? 30 : 24, weight: .bold, design: .rounded))
                Text("SSH-ключи, Touch ID и сохранённые SSH-реквизиты")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Импортировать", systemImage: "square.and.arrow.down") {
                model.importSSHKey(assignToProfileID: nil)
            }
            Button("Создать SSH ID", systemImage: "plus") {
                showsKeyGenerator = true
            }
            .buttonStyle(.borderedProminent)

            if presentation == .sheet {
                Button("Готово") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var keyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SSH ID")
                    .font(.headline)
                Spacer()
                Text("\(model.sshKeys.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            List(selection: $selectedKeyID) {
                ForEach(model.sshKeys) { key in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Image(systemName: isTouchIDKey(key) ? "touchid" : "key.horizontal")
                                .foregroundStyle(Color.accentColor)
                            Text(key.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            if agentLoadedKeyIDs.contains(key.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .help("Ключ загружен в ssh-agent")
                            }
                        }
                        Text("\(key.algorithm) · \(key.fingerprint)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        let usageCount = profilesUsing(key).count
                        if usageCount > 0 {
                            Text("Профилей: \(usageCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    .tag(key.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                Button("Добавить", systemImage: "plus") {
                    model.importSSHKey(assignToProfileID: nil)
                }
                Button("Создать", systemImage: "key.horizontal") {
                    showsKeyGenerator = true
                }
                Spacer()
                Button(role: .destructive) {
                    guard let id = selectedKey?.id else { return }
                    model.removeSSHKey(id)
                    selectedKeyID = model.sshKeys.first?.id
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedKey == nil)
                .help("Удалить регистрацию ключа из Selective Remote; файл приватного ключа останется на диске")
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }

    private var agentCard: some View {
        GroupBox("ssh-agent") {
            HStack(spacing: 12) {
                Image(systemName: agentCheckError == nil ? "memorychip" : "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(agentCheckError == nil ? Color.accentColor : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    if checkingAgent {
                        Text("Проверяем состояние…")
                            .font(.headline)
                    } else if let agentCheckError {
                        Text("Состояние не удалось получить")
                            .font(.headline)
                        Text(agentCheckError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Готов · загружено ключей: \(agentLoadedKeyIDs.count)")
                            .font(.headline)
                        Text("Обычные ключи могут быть загружены в память ssh-agent; Touch ID Key не требует постоянного хранения приватного ключа в Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise") {
                    refreshAgentState()
                }
                .disabled(checkingAgent)
            }
            .padding(8)
        }
    }

    private var credentialEntriesCard: some View {
        GroupBox("Сохранённые SSH-реквизиты") {
            VStack(alignment: .leading, spacing: 10) {
                if savedCredentialProfiles.isEmpty {
                    Text("Сохранённых SSH-паролей нет")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(savedCredentialProfiles) { profile in
                        credentialRow(profile)
                        if profile.id != savedCredentialProfiles.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func credentialRow(_ profile: ConnectionProfile) -> some View {
        let marker = model.hasSavedSSHPassword(profileID: profile.id)
        let available = KeychainService.passwordExists(
            reference: KeychainService.credentialReference(profileID: profile.id, kind: .ssh)
        )
        let protected = model.sshPasswordRequiresUserPresence(profileID: profile.id)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: available ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(available ? .green : .orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.friendlyName)
                    .font(.subheadline.weight(.semibold))
                Text("\(profile.username.isEmpty ? "SSH" : profile.username)@\(profile.host):\(profile.sshPort)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(
                    available
                        ? (protected ? "Пароль сохранён · доступ по Touch ID" : "Пароль сохранён в macOS Keychain")
                        : (marker ? "Запись требует восстановления" : "Запись Keychain не найдена")
                )
                .font(.caption)
                .foregroundStyle(available ? Color.secondary : Color.orange)
            }
            Spacer()
            if marker && !available {
                Button("Исправить", systemImage: "wrench.and.screwdriver") {
                    model.repairSSHCredentialAccess(profileID: profile.id)
                }
            }
            if let onOpenProfile {
                Button("Профиль", systemImage: "arrow.right.circle") {
                    onOpenProfile(profile.id)
                }
            }
        }
    }

    @ViewBuilder
    private func keyDetails(_ key: SSHKeyRecord) -> some View {
        GroupBox("Параметры ключа") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                        Image(systemName: isTouchIDKey(key) ? "touchid" : "key.horizontal.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 50, height: 50)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Название ключа",
                            text: Binding(
                                get: { key.name },
                                set: { value in
                                    var updated = key
                                    updated.name = value
                                    model.updateSSHKey(updated)
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Text(isTouchIDKey(key) ? "Touch ID · \(key.algorithm)" : key.algorithm)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if agentLoadedKeyIDs.contains(key.id) {
                        Label("В ssh-agent", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Fingerprint")
                            .foregroundStyle(.secondary)
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Приватный ключ")
                            .foregroundStyle(.secondary)
                        Text(key.privateKeyPath)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Используется")
                            .foregroundStyle(.secondary)
                        Text(profileUsageText(key))
                            .font(.caption)
                    }
                }
            }
            .padding(8)
        }

        GroupBox("Действия") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("Добавить в ssh-agent", systemImage: "plus.circle") {
                        model.addSSHKeyToAgent(key.id)
                        refreshAgentState(after: .milliseconds(250))
                    }
                    Button("Убрать из ssh-agent", systemImage: "minus.circle") {
                        model.removeSSHKeyFromAgent(key.id)
                        refreshAgentState(after: .milliseconds(250))
                    }
                    .disabled(!agentLoadedKeyIDs.contains(key.id))
                    Button("Забыть passphrase", systemImage: "key.slash", role: .destructive) {
                        model.removeSSHKeyFromAgentAndKeychain(key.id)
                        refreshAgentState(after: .milliseconds(250))
                    }
                    Spacer()
                    Button("Показать в Finder") {
                        model.revealSSHKey(key.id)
                    }
                    Button("Копировать .pub") {
                        model.copySSHPublicKey(key.id)
                    }
                    .disabled(key.publicKeyPath == nil)
                }

                Divider()

                HStack(spacing: 10) {
                    Picker("Сервер", selection: Binding(
                        get: { installTargetProfileID ?? sshProfiles.first?.id },
                        set: { installTargetProfileID = $0 }
                    )) {
                        ForEach(sshProfiles) { profile in
                            Text(profile.friendlyName).tag(Optional(profile.id))
                        }
                    }
                    .frame(maxWidth: 300)
                    .disabled(sshProfiles.isEmpty)

                    Button("Установить public key на сервер", systemImage: "arrow.up.to.line") {
                        guard let profileID = installTargetProfileID ?? sshProfiles.first?.id else { return }
                        model.installSSHPublicKey(keyID: key.id, profileID: profileID)
                    }
                    .disabled(key.publicKeyPath == nil || sshProfiles.isEmpty)
                }
            }
            .padding(8)
        }

        touchIDCard(key)

        GroupBox("Хранение") {
            VStack(alignment: .leading, spacing: 7) {
                Label("Приватный SSH-ключ остаётся файлом в ~/.ssh или в выбранном вами пути.", systemImage: "doc")
                Label("Keychain хранит SSH-пароли, proxy-пароли и passphrase, но не копии приватных SSH-ключей.", systemImage: "lock.shield")
                Label("Удаление SSH ID из Selective Remote не удаляет исходный файл приватного ключа.", systemImage: "externaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        }
    }

    @ViewBuilder
    private func touchIDCard(_ key: SSHKeyRecord) -> some View {
        let usage = profilesUsing(key)
        GroupBox("Touch ID") {
            VStack(alignment: .leading, spacing: 10) {
                if usage.isEmpty {
                    Text("Назначьте этот SSH ID профилю, чтобы включить Touch ID перед его использованием.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usage) { profile in
                        let forced = profile.sshAuthenticationMode == .touchIDKey
                        Toggle(isOn: Binding(
                            get: {
                                forced || model.sshKeyRequiresUserPresence(profileID: profile.id)
                            },
                            set: { enabled in
                                guard !forced else { return }
                                model.setSSHKeyUserPresenceForProfile(enabled, profileID: profile.id)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.friendlyName)
                                Text(forced ? "Touch ID Key — подтверждение обязательно" : "Требовать Touch ID перед использованием ключа")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(forced)
                    }
                }
            }
            .padding(8)
        }
    }

    private var savedCredentialProfiles: [ConnectionProfile] {
        sshProfiles.filter { profile in
            model.hasSavedSSHPassword(profileID: profile.id)
                || KeychainService.passwordExists(
                    reference: KeychainService.credentialReference(
                        profileID: profile.id,
                        kind: .ssh
                    )
                )
        }
    }

    private func profilesUsing(_ key: SSHKeyRecord) -> [ConnectionProfile] {
        sshProfiles.filter { $0.sshIdentityID == key.id }
    }

    private func profileUsageText(_ key: SSHKeyRecord) -> String {
        let names = profilesUsing(key).map(\.friendlyName)
        return names.isEmpty ? "Не назначен профилям" : names.joined(separator: ", ")
    }

    private func isTouchIDKey(_ key: SSHKeyRecord) -> Bool {
        profilesUsing(key).contains { profile in
            profile.sshAuthenticationMode == .touchIDKey
                || model.sshKeyRequiresUserPresence(profileID: profile.id)
        }
    }

    private func refreshAgentState(after delay: Duration? = nil) {
        let keys = model.sshKeys
        checkingAgent = true
        agentCheckError = nil
        Task {
            if let delay {
                try? await Task.sleep(for: delay)
            }
            let result = await Task.detached(priority: .utility) {
                var loaded = Set<UUID>()
                do {
                    for key in keys {
                        if try SSHKeyService.isLoadedInAgent(key) {
                            loaded.insert(key.id)
                        }
                    }
                    return (loaded, Optional<String>.none)
                } catch {
                    return (Set<UUID>(), Optional(error.localizedDescription))
                }
            }.value

            agentLoadedKeyIDs = result.0
            agentCheckError = result.1
            checkingAgent = false
        }
    }
}
