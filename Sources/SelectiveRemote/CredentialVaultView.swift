import AppKit
import SwiftUI

enum CredentialVaultPresentation {
    case sheet
    case embedded
}

private enum VaultFilter: String, CaseIterable, Identifiable {
    case all
    case keys
    case certificates
    case touchID
    case passwords

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .keys: "SSH Keys"
        case .certificates: "Certificates"
        case .touchID: "Touch ID"
        case .passwords: "Passwords"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .keys: "key.horizontal"
        case .certificates: "checkmark.seal"
        case .touchID: "touchid"
        case .passwords: "ellipsis.rectangle"
        }
    }
}

private enum VaultSelection: Hashable {
    case key(UUID)
    case credential(UUID)
}

struct CredentialVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let presentation: CredentialVaultPresentation
    let onOpenProfile: ((UUID) -> Void)?

    @State private var selection: VaultSelection?
    @State private var filter: VaultFilter = .all
    @State private var showsKeyGenerator = false
    @State private var touchIDGenerator = false
    @State private var installTargetProfileID: UUID?
    @State private var agentLoadedKeyIDs: Set<UUID> = []
    @State private var agentCheckError: String?
    @State private var checkingAgent = false
    @State private var certificateInfo: SSHCertificateInfo?
    @State private var certificateError: String?

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

    private var visibleKeys: [SSHKeyRecord] {
        switch filter {
        case .all, .keys:
            model.sshKeys
        case .certificates:
            model.sshKeys.filter { SSHKeyService.certificateURL(for: $0) != nil }
        case .touchID:
            model.sshKeys.filter(SSHKeyService.isTouchIDCompatible)
        case .passwords:
            []
        }
    }

    private var visibleCredentials: [ConnectionProfile] {
        switch filter {
        case .all, .passwords:
            savedCredentialProfiles
        case .keys, .certificates, .touchID:
            []
        }
    }

    private var selectedKey: SSHKeyRecord? {
        guard case let .key(id) = selection else { return nil }
        return model.sshKeys.first(where: { $0.id == id })
    }

    private var selectedCredential: ConnectionProfile? {
        guard case let .credential(id) = selection else { return nil }
        return sshProfiles.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                vaultList
                    .frame(minWidth: 330, idealWidth: 390, maxWidth: 480)

                inspector
                    .frame(minWidth: 520)
            }
        }
        .frame(
            minWidth: presentation == .sheet ? 980 : nil,
            minHeight: presentation == .sheet ? 660 : nil
        )
        .onAppear {
            if selection == nil {
                if let id = model.selectedSSHKey?.id ?? model.sshKeys.first?.id {
                    selection = .key(id)
                } else if let id = savedCredentialProfiles.first?.id {
                    selection = .credential(id)
                }
            }
            if installTargetProfileID == nil {
                installTargetProfileID = model.selectedProfile.connectionType == .ssh
                    ? model.selectedProfile.id
                    : sshProfiles.first?.id
            }
            refreshAgentState()
            refreshCertificateInfo()
        }
        .onChange(of: selection) { _, _ in
            refreshCertificateInfo()
        }
        .onChange(of: model.sshKeys) { _, keys in
            if case let .key(id) = selection,
               !keys.contains(where: { $0.id == id }) {
                selection = keys.first.map { .key($0.id) }
                    ?? savedCredentialProfiles.first.map { .credential($0.id) }
            }
            refreshAgentState()
            refreshCertificateInfo()
        }
        .sheet(isPresented: $showsKeyGenerator) {
            SSHKeyGenerationView(touchIDPreset: touchIDGenerator) { request, session in
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
                Text("SSH ID, Touch ID, OpenSSH certificates и сохранённые реквизиты")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if presentation == .sheet {
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var vaultList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    Button("Обычный SSH ID", systemImage: "key.horizontal") {
                        touchIDGenerator = false
                        showsKeyGenerator = true
                    }
                    Button("Touch ID Key · ECDSA", systemImage: "touchid") {
                        touchIDGenerator = true
                        showsKeyGenerator = true
                    }
                } label: {
                    Label("Создать", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button("Импортировать", systemImage: "square.and.arrow.down") {
                    model.importSSHKey(assignToProfileID: nil)
                }
                Spacer()
            }
            .padding(12)
            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VaultFilter.allCases) { item in
                        Button {
                            filter = item
                            normalizeSelectionForFilter()
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(filter == item ? Color.accentColor : nil)
                    }
                }
                .padding(12)
            }
            Divider()

            List(selection: $selection) {
                if !visibleKeys.isEmpty {
                    Section("SSH ID") {
                        ForEach(visibleKeys) { key in
                            keyRow(key)
                                .tag(VaultSelection.key(key.id))
                        }
                    }
                }

                if !visibleCredentials.isEmpty {
                    Section("Passwords") {
                        ForEach(visibleCredentials) { profile in
                            credentialRow(profile)
                                .tag(VaultSelection.credential(profile.id))
                        }
                    }
                }

                if visibleKeys.isEmpty && visibleCredentials.isEmpty {
                    ContentUnavailableView(
                        "Ничего не найдено",
                        systemImage: filter.systemImage,
                        description: Text("Для выбранной категории пока нет элементов.")
                    )
                    .frame(minHeight: 260)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu {
                Menu("Создать", systemImage: "plus") {
                    Button("Обычный SSH ID", systemImage: "key.horizontal") {
                        touchIDGenerator = false
                        showsKeyGenerator = true
                    }
                    Button("Touch ID Key · ECDSA", systemImage: "touchid") {
                        touchIDGenerator = true
                        showsKeyGenerator = true
                    }
                }
                Button("Импортировать…", systemImage: "square.and.arrow.down") {
                    model.importSSHKey(assignToProfileID: nil)
                }
            }

            Divider()
            agentStrip
        }
        .background(.ultraThinMaterial)
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        let certificate = SSHKeyService.certificateURL(for: key) != nil
        let touchIDCompatible = SSHKeyService.isTouchIDCompatible(key)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: touchIDCompatible ? "touchid" : "key.horizontal")
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(key.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(key.algorithm)
                    if touchIDCompatible {
                        Text("· Touch ID")
                    }
                    if certificate {
                        Text("· Certificate")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if agentLoadedKeyIDs.contains(key.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Загружен в ssh-agent")
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Копировать public key", systemImage: "doc.on.doc") {
                model.copySSHPublicKey(key.id)
            }
            .disabled(key.publicKeyPath == nil)
            Button("Показать в Finder", systemImage: "folder") {
                model.revealSSHKey(key.id)
            }
            Menu("Установить на сервер", systemImage: "arrow.up.to.line") {
                ForEach(sshProfiles) { profile in
                    Button(profile.friendlyName) {
                        installTargetProfileID = profile.id
                        model.installSSHPublicKey(keyID: key.id, profileID: profile.id)
                    }
                }
            }
            .disabled(key.publicKeyPath == nil || sshProfiles.isEmpty)
            Divider()
            if agentLoadedKeyIDs.contains(key.id) {
                Button("Убрать из ssh-agent", systemImage: "minus.circle") {
                    model.removeSSHKeyFromAgentAndKeychain(key.id)
                    refreshAgentState()
                }
            } else {
                Button("Добавить в ssh-agent", systemImage: "plus.circle") {
                    model.addSSHKeyToAgent(key.id)
                    refreshAgentState()
                }
            }
            Divider()
            Button("Удалить из Selective Remote", systemImage: "trash", role: .destructive) {
                model.removeSSHKey(key.id)
            }
        }
    }

    private func credentialRow(_ profile: ConnectionProfile) -> some View {
        let protected = model.sshPasswordRequiresUserPresence(profileID: profile.id)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: protected ? "touchid" : "ellipsis.rectangle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.friendlyName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(protected ? "SSH password · Touch ID" : "SSH password · Keychain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            if let onOpenProfile {
                Button("Открыть SSH-профиль", systemImage: "arrow.right.circle") {
                    onOpenProfile(profile.id)
                }
            }
            Button("Исправить запись Keychain…", systemImage: "wrench.and.screwdriver") {
                model.repairSSHCredentialAccess(profileID: profile.id)
            }
            Divider()
            Button("Удалить пароль", systemImage: "trash", role: .destructive) {
                model.deleteSavedSSHPassword(profileID: profile.id)
            }
        }
    }

    private var agentStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: agentCheckError == nil ? "memorychip" : "exclamationmark.triangle")
                .foregroundStyle(agentCheckError == nil ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(checkingAgent ? "ssh-agent: проверка…" : "ssh-agent: \(agentLoadedKeyIDs.count) ключей")
                    .font(.caption.weight(.semibold))
                if let agentCheckError {
                    Text(agentCheckError).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                refreshAgentState()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(checkingAgent)
        }
        .padding(12)
    }

    @ViewBuilder
    private var inspector: some View {
        if let key = selectedKey {
            keyInspector(key)
        } else if let profile = selectedCredential {
            credentialInspector(profile)
        } else {
            ContentUnavailableView(
                "Выберите credential",
                systemImage: "key.viewfinder",
                description: Text("Выберите SSH ID, certificate или сохранённый пароль в списке слева.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func keyInspector(_ key: SSHKeyRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.13))
                        Image(systemName: SSHKeyService.isTouchIDCompatible(key) ? "touchid" : "key.horizontal.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 52, height: 52)

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
                        .textFieldStyle(.plain)
                        .font(.title2.bold())
                        Text(keySubtitle(key))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Показать в Finder", systemImage: "folder") { model.revealSSHKey(key.id) }
                        Button("Копировать public key", systemImage: "doc.on.doc") { model.copySSHPublicKey(key.id) }
                            .disabled(key.publicKeyPath == nil)
                        Divider()
                        Button("Удалить из Selective Remote", systemImage: "trash", role: .destructive) {
                            model.removeSSHKey(key.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                detailsCard(key)
                publicKeyCard(key)
                certificateCard(key)
                serverInstallCard(key)
                agentCard(key)
                touchIDCard(key)
                storageCard
            }
            .padding(22)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func detailsCard(_ key: SSHKeyRecord) -> some View {
        inspectorCard("Параметры", systemImage: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow { metadataLabel("Тип"); Text(key.algorithm) }
                GridRow {
                    metadataLabel("Fingerprint")
                    Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                GridRow {
                    metadataLabel("Private key")
                    Text(key.privateKeyPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                GridRow {
                    metadataLabel("Используется")
                    Text(profileUsageText(key)).font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func publicKeyCard(_ key: SSHKeyRecord) -> some View {
        if let value = try? SSHKeyService.publicKeyText(for: key), !value.isEmpty {
            inspectorCard("Public key", systemImage: "doc.plaintext") {
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Spacer()
                    Button("Копировать", systemImage: "doc.on.doc") {
                        model.copySSHPublicKey(key.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func certificateCard(_ key: SSHKeyRecord) -> some View {
        if SSHKeyService.certificateURL(for: key) != nil {
            inspectorCard("OpenSSH Certificate", systemImage: "checkmark.seal.fill") {
                if let certificateInfo {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        if let value = certificateInfo.type { GridRow { metadataLabel("Type"); Text(value) } }
                        if let value = certificateInfo.keyID { GridRow { metadataLabel("Key ID"); Text(value) } }
                        if let value = certificateInfo.serial { GridRow { metadataLabel("Serial"); Text(value) } }
                        if let value = certificateInfo.validFrom { GridRow { metadataLabel("Valid from"); Text(value) } }
                        if let value = certificateInfo.validTo { GridRow { metadataLabel("Valid to"); Text(value) } }
                        if !certificateInfo.principals.isEmpty {
                            GridRow { metadataLabel("Principals"); Text(certificateInfo.principals.joined(separator: ", ")) }
                        }
                        GridRow {
                            metadataLabel("Файл")
                            Text(certificateInfo.path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let signingCA = certificateInfo.signingCA {
                        Divider()
                        Text("Signing CA")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(signingCA)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("Показать вывод ssh-keygen -L") {
                        Text(certificateInfo.rawText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                } else if let certificateError {
                    Label(certificateError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    ProgressView("Читаем certificate…")
                }
            }
        }
    }

    private func serverInstallCard(_ key: SSHKeyRecord) -> some View {
        inspectorCard("Установить на сервер", systemImage: "arrow.up.to.line") {
            HStack(spacing: 10) {
                Picker("Сервер", selection: Binding(
                    get: { installTargetProfileID ?? sshProfiles.first?.id },
                    set: { installTargetProfileID = $0 }
                )) {
                    ForEach(sshProfiles) { profile in
                        Text(profile.friendlyName).tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .disabled(sshProfiles.isEmpty)

                Button("Установить public key") {
                    guard let profileID = installTargetProfileID ?? sshProfiles.first?.id else { return }
                    model.installSSHPublicKey(keyID: key.id, profileID: profileID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.publicKeyPath == nil || sshProfiles.isEmpty)
            }
            Text("На сервер передаётся только публичный ключ. Private key остаётся на этом Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func agentCard(_ key: SSHKeyRecord) -> some View {
        let loaded = agentLoadedKeyIDs.contains(key.id)
        return inspectorCard("ssh-agent", systemImage: "memorychip") {
            HStack {
                Label(loaded ? "Ключ загружен" : "Ключ не загружен", systemImage: loaded ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(loaded ? Color.green : Color.secondary)
                Spacer()
                if loaded {
                    Button("Убрать") {
                        model.removeSSHKeyFromAgent(key.id)
                        refreshAgentState(after: .milliseconds(250))
                    }
                } else {
                    Button("Добавить") {
                        model.addSSHKeyToAgent(key.id)
                        refreshAgentState(after: .milliseconds(250))
                    }
                }
                Button("Забыть passphrase", role: .destructive) {
                    model.removeSSHKeyFromAgentAndKeychain(key.id)
                    refreshAgentState(after: .milliseconds(250))
                }
            }
        }
    }

    private func touchIDCard(_ key: SSHKeyRecord) -> some View {
        inspectorCard("Touch ID", systemImage: "touchid") {
            if SSHKeyService.isTouchIDCompatible(key) {
                Label("ECDSA-ключ совместим с режимом Touch ID Key", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("В режиме Touch ID Key Selective Remote требует биометрию перед каждым использованием этого ECDSA-ключа. Ed25519/RSA в этот режим не подставляются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Обычный SSH ID", systemImage: "key.horizontal")
                Text("Этот ключ остаётся обычным SSH ID. Для отдельного Touch ID Key создайте ECDSA P-256 ключ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storageCard: some View {
        inspectorCard("Хранение", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Private key хранится только файлом в ~/.ssh или выбранном пути.")
                Text("Keychain хранит пароли/passphrase и связанные секреты, но не копию private key.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func credentialInspector(_ profile: ConnectionProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.13))
                        Image(systemName: model.sshPasswordRequiresUserPresence(profileID: profile.id) ? "touchid" : "ellipsis.rectangle.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.friendlyName).font(.title2.bold())
                        Text("SSH password · macOS Keychain").foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                inspectorCard("Состояние", systemImage: "lock.shield") {
                    Label("Пароль сохранён", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if model.sshPasswordRequiresUserPresence(profileID: profile.id) {
                        Label("Доступ защищён Touch ID", systemImage: "touchid")
                            .foregroundStyle(Color.accentColor)
                    }
                    HStack {
                        if let onOpenProfile {
                            Button("Открыть профиль", systemImage: "arrow.up.right.square") {
                                onOpenProfile(profile.id)
                            }
                        }
                        Spacer()
                        Button("Исправить запись…", systemImage: "wrench.and.screwdriver") {
                            model.repairSSHCredentialAccess(profileID: profile.id)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func inspectorCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func metadataLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .leading)
    }

    private func keySubtitle(_ key: SSHKeyRecord) -> String {
        var parts = [key.algorithm]
        if SSHKeyService.isTouchIDCompatible(key) { parts.append("Touch ID compatible") }
        if SSHKeyService.certificateURL(for: key) != nil { parts.append("Certificate attached") }
        return parts.joined(separator: " · ")
    }

    private func profilesUsing(_ key: SSHKeyRecord) -> [ConnectionProfile] {
        sshProfiles.filter { $0.sshIdentityID == key.id }
    }

    private func profileUsageText(_ key: SSHKeyRecord) -> String {
        let names = profilesUsing(key).map(\.friendlyName)
        return names.isEmpty ? "Не назначен профилям" : names.joined(separator: ", ")
    }

    private func normalizeSelectionForFilter() {
        if let selectedKey, visibleKeys.contains(where: { $0.id == selectedKey.id }) { return }
        if let selectedCredential, visibleCredentials.contains(where: { $0.id == selectedCredential.id }) { return }
        selection = visibleKeys.first.map { .key($0.id) }
            ?? visibleCredentials.first.map { .credential($0.id) }
    }

    private func refreshCertificateInfo() {
        certificateInfo = nil
        certificateError = nil
        guard let key = selectedKey, SSHKeyService.certificateURL(for: key) != nil else { return }
        Task {
            let result = await Task.detached(priority: .utility) {
                do {
                    return (try SSHKeyService.inspectCertificate(for: key), Optional<String>.none)
                } catch {
                    return (Optional<SSHCertificateInfo>.none, Optional(error.localizedDescription))
                }
            }.value
            certificateInfo = result.0
            certificateError = result.1
        }
    }

    private func refreshAgentState(after delay: Duration? = nil) {
        let keys = model.sshKeys
        checkingAgent = true
        agentCheckError = nil
        Task {
            if let delay { try? await Task.sleep(for: delay) }
            let result = await Task.detached(priority: .utility) {
                var loaded = Set<UUID>()
                do {
                    for key in keys where try SSHKeyService.isLoadedInAgent(key) {
                        loaded.insert(key.id)
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
