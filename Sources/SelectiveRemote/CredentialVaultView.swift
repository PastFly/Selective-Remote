import AppKit
import SwiftUI

enum CredentialVaultPresentation {
    case sheet
    case embedded
}


private struct SSHCertificateSigningRequest: Identifiable {
    let id = UUID()
    let key: SSHKeyRecord
    let authority: SSHCertificateAuthorityRecord
}

private enum VaultFilter: String, CaseIterable, Identifiable {
    case all
    case keys
    case certificates
    case touchID
    case passwords
    case authorities
    case knownHosts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все"
        case .keys: "SSH ID"
        case .certificates: "Сертификаты"
        case .touchID: "Touch ID"
        case .passwords: "Пароли"
        case .authorities: "SSH CA"
        case .knownHosts: "Известные хосты"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .keys: "key.horizontal"
        case .certificates: "checkmark.seal"
        case .touchID: "touchid"
        case .passwords: "ellipsis.rectangle"
        case .authorities: "seal"
        case .knownHosts: "server.rack"
        }
    }
}

private enum VaultSortMode: String, CaseIterable, Identifiable {
    case name
    case type
    case usage
    case fingerprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "По имени"
        case .type: "По типу"
        case .usage: "По использованию"
        case .fingerprint: "По fingerprint"
        }
    }

    var systemImage: String {
        switch self {
        case .name: "textformat"
        case .type: "square.grid.2x2"
        case .usage: "rectangle.stack"
        case .fingerprint: "number"
        }
    }
}

private enum VaultSelection: Hashable {
    case key(UUID)
    case credential(UUID)
    case authority(UUID)
    case knownHost(String)
}

struct CredentialVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let presentation: CredentialVaultPresentation
    let onOpenProfile: ((UUID) -> Void)?

    @State private var selection: VaultSelection?
    @State private var filter: VaultFilter = .all
    @State private var searchText = ""
    @AppStorage("SelectiveRemote.keychain.sort.v1")
    private var sortModeRaw = VaultSortMode.name.rawValue
    @State private var showsKeyGenerator = false
    @State private var touchIDGenerator = false
    @State private var installTargetProfileID: UUID?
    @State private var agentLoadedKeyIDs: Set<UUID> = []
    @State private var agentCheckError: String?
    @State private var checkingAgent = false
    @State private var certificateInfo: SSHCertificateInfo?
    @State private var certificateError: String?
    @State private var knownHosts: [SSHKnownHostEntry] = []
    @State private var authorities: [SSHCertificateAuthorityRecord] = []
    @State private var signingRequest: SSHCertificateSigningRequest?
    @State private var knownHostsError: String?
    @State private var verifyingKnownHostID: String?
    @State private var knownHostVerification: [String: SSHKnownHostVerification] = [:]
    @State private var knownHostPendingDeletion: SSHKnownHostEntry?
    @State private var knownHostProfileCreationEntry: SSHKnownHostEntry?
    @State private var unifiedVaultMessage: String?
    @State private var compactDetailPresented = false

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

    private var sortMode: VaultSortMode {
        VaultSortMode(rawValue: sortModeRaw) ?? .name
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleKeys: [SSHKeyRecord] {
        let base: [SSHKeyRecord]
        switch filter {
        case .all, .keys:
            base = model.sshKeys
        case .certificates:
            base = model.sshKeys.filter { SSHKeyService.certificateURL(for: $0) != nil }
        case .touchID:
            base = model.sshKeys.filter(SSHKeyService.isTouchIDCompatible)
        case .passwords, .authorities, .knownHosts:
            base = []
        }
        return base
            .filter { key in keyMatchesSearch(key) }
            .sorted { lhs, rhs in keySort(lhs, rhs) }
    }

    private var visibleCredentials: [ConnectionProfile] {
        let base: [ConnectionProfile]
        switch filter {
        case .all, .passwords:
            base = savedCredentialProfiles
        case .keys, .certificates, .touchID, .authorities, .knownHosts:
            base = []
        }
        return base
            .filter { profile in profileMatchesSearch(profile) }
            .sorted { lhs, rhs in profileSort(lhs, rhs) }
    }

    private var visibleKnownHosts: [SSHKnownHostEntry] {
        let base: [SSHKnownHostEntry]
        switch filter {
        case .all, .knownHosts:
            base = knownHosts
        case .keys, .certificates, .touchID, .passwords, .authorities:
            base = []
        }
        return base
            .filter { entry in knownHostMatchesSearch(entry) }
            .sorted { lhs, rhs in knownHostSort(lhs, rhs) }
    }

    private var visibleAuthorities: [SSHCertificateAuthorityRecord] {
        let base: [SSHCertificateAuthorityRecord]
        switch filter {
        case .all, .authorities:
            base = authorities
        case .keys, .certificates, .touchID, .passwords, .knownHosts:
            base = []
        }
        return base
            .filter { authority in authorityMatchesSearch(authority) }
            .sorted { lhs, rhs in authoritySort(lhs, rhs) }
    }

    private var selectedAuthority: SSHCertificateAuthorityRecord? {
        guard case let .authority(id) = selection else { return nil }
        return authorities.first(where: { $0.id == id })
    }

    private var selectedKey: SSHKeyRecord? {
        guard case let .key(id) = selection else { return nil }
        return model.sshKeys.first(where: { $0.id == id })
    }

    private var selectedCredential: ConnectionProfile? {
        guard case let .credential(id) = selection else { return nil }
        return sshProfiles.first(where: { $0.id == id })
    }

    private var selectedKnownHost: SSHKnownHostEntry? {
        guard case let .knownHost(id) = selection else { return nil }
        return knownHosts.first(where: { $0.id == id })
    }

    var body: some View {
        bodyWithKnownHostProfileSheet
    }

    private var baseLayout: some View {
        GeometryReader { proxy in
            let compact = AdaptiveWorkspaceLayout.usesDetailNavigation(
                width: proxy.size.width
            )

            VStack(spacing: 0) {
                header(compact: compact)
                Divider()

                if compact {
                    if compactDetailPresented {
                        compactInspector
                    } else {
                        vaultList(compact: true)
                    }
                } else {
                    HSplitView {
                        vaultList(compact: false)
                            .frame(minWidth: 330, idealWidth: 390, maxWidth: 480)

                        inspector
                            .frame(minWidth: 420)
                    }
                }
            }
        }
        .frame(
            minWidth: presentation == .sheet ? 680 : nil,
            minHeight: presentation == .sheet ? 660 : nil
        )
    }

    private var compactInspector: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Назад к Связке ключей", systemImage: "chevron.left") {
                    compactDetailPresented = false
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
            inspector
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bodyWithLifecycle: some View {
        baseLayout
            .onAppear(perform: handleAppear)
            .alert("Единый Keychain Vault", isPresented: Binding(
                get: { unifiedVaultMessage != nil },
                set: { if !$0 { unifiedVaultMessage = nil } }
            )) {
                Button("OK", role: .cancel) { unifiedVaultMessage = nil }
            } message: {
                Text(unifiedVaultMessage ?? "")
            }
            .onChange(of: selection) { _, _ in
                refreshCertificateInfo()
            }
            .onChange(of: model.sshKeys) { _, keys in
                handleSSHKeysChanged(keys)
            }
    }

    private var bodyWithKnownHostAlert: some View {
        bodyWithLifecycle
            .alert(
                "Удалить Known Host?",
                isPresented: Binding(
                    get: { knownHostPendingDeletion != nil },
                    set: { if !$0 { knownHostPendingDeletion = nil } }
                ),
                presenting: knownHostPendingDeletion
            ) { entry in
                Button("Удалить", role: .destructive) { deleteKnownHost(entry) }
                Button("Отмена", role: .cancel) {}
            } message: { entry in
                Text("Запись «\(entry.displayHost)» будет удалена из ~/.ssh/known_hosts. Перед изменением создаётся резервная копия known_hosts.selectiveremote.bak.")
            }
    }

    private var bodyWithKeyGeneratorSheet: some View {
        bodyWithKnownHostAlert
            .sheet(isPresented: $showsKeyGenerator) {
                SSHKeyGenerationView(touchIDPreset: touchIDGenerator) { request, session in
                    model.generateSSHKeyGlobally(request, session: session)
                }
            }
    }

    private var bodyWithSigningSheet: some View {
        bodyWithKeyGeneratorSheet
            .sheet(item: $signingRequest) { request in
                SSHCertificateSigningView(key: request.key, authority: request.authority) {
                    refreshCertificateInfo()
                }
            }
    }

    private var bodyWithKnownHostProfileSheet: some View {
        bodyWithSigningSheet
            .sheet(item: $knownHostProfileCreationEntry) { entry in
                KnownHostSSHProfileCreationView(entry: entry) { profileID in
                    onOpenProfile?(profileID)
                }
                .environmentObject(model)
            }
    }

    private func migrateCredentialVault() {
        do {
            let report = try KeychainService.migrateCredentialsToUnifiedVault()
            if report.discovered == 0 {
                unifiedVaultMessage = "Старых записей для переноса не найдено. Единый Vault уже готов к работе."
            } else if report.failed > 0 {
                unifiedVaultMessage = "Перенесено: \(report.imported), уже в Vault: \(report.alreadyStored), не удалось прочитать: \(report.failed). Недоступные записи можно перенести позже повторным запуском или при обычном подключении к профилю."
            } else {
                unifiedVaultMessage = "Перенесено: \(report.imported), уже в Vault: \(report.alreadyStored). Теперь сохранённые пароли используют единый Keychain Vault."
            }
        } catch {
            unifiedVaultMessage = "Не удалось объединить пароли: \(error.localizedDescription)"
        }
    }

    private func handleAppear() {
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
        refreshKnownHosts()
        refreshAuthorities()
    }

    private func handleSSHKeysChanged(_ keys: [SSHKeyRecord]) {
        if case let .key(id) = selection,
           !keys.contains(where: { $0.id == id }) {
            selection = keys.first.map { .key($0.id) }
                ?? savedCredentialProfiles.first.map { .credential($0.id) }
        }

        refreshAgentState()
        refreshCertificateInfo()
    }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: compact ? 40 : 48, height: compact ? 40 : 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Связка ключей")
                    .font(.system(size: compact ? 24 : (presentation == .embedded ? 30 : 24), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("SSH ID, Touch ID, OpenSSH-сертификаты и сохранённые реквизиты")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if compact {
                Menu {
                    Button("Объединить пароли", systemImage: "lock.square.stack") {
                        migrateCredentialVault()
                    }
                    if presentation == .sheet {
                        Divider()
                        Button("Готово") { dismiss() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .help("Действия Связки ключей")
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    Button {
                        migrateCredentialVault()
                    } label: {
                        Label("Объединить пароли", systemImage: "lock.square.stack")
                    }
                    .buttonStyle(.bordered)
                    .help("Однократно переносит старые сохранённые пароли в единый Keychain Vault. При первой миграции macOS ещё может запросить доступ к отдельным старым записям; после переноса будущие сборки используют одну Vault-запись.")
                    Text(UpdateLocalization.text(
                        ru: "Единый Vault: \(KeychainService.unifiedVaultEntryCount)",
                        en: "Unified Vault: \(KeychainService.unifiedVaultEntryCount)"
                    ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if presentation == .sheet {
                    Button("Готово") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, compact ? 16 : 22)
        .padding(.vertical, compact ? 12 : 16)
    }

    private func vaultList(compact: Bool) -> some View {
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

                Menu {
                    Button("SSH ID…", systemImage: "key.horizontal") {
                        model.importSSHKey(assignToProfileID: nil)
                    }
                    Button("SSH CA public key…", systemImage: "seal") {
                        importAuthority()
                    }
                } label: {
                    Label("Импортировать", systemImage: "square.and.arrow.down")
                }
                Spacer()
            }
            .padding(12)
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                for url in urls {
                    model.importSSHKey(at: url, assignToProfileID: nil)
                }
                return true
            }
            .help("Можно перетащить сюда приватный SSH-ключ")
            Divider()

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: compact ? 116 : 92), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(VaultFilter.allCases) { item in
                    Button {
                        filter = item
                        normalizeSelectionForFilter()
                    } label: {
                        Label {
                            Text(LocalizedStringKey(item.title))
                        } icon: {
                            Image(systemName: item.systemImage)
                        }
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(filter == item ? Color.accentColor : nil)
                }
            }
            .padding(12)
            keychainSearchToolbar
            Divider()

            List(selection: $selection) {
                if !visibleKeys.isEmpty {
                    Section("SSH ID") {
                        ForEach(visibleKeys) { key in
                            keyRow(key)
                                .tag(VaultSelection.key(key.id))
                                .simultaneousGesture(compactSelectionGesture(.key(key.id), enabled: compact))
                        }
                    }
                }

                if !visibleCredentials.isEmpty {
                    Section("Пароли") {
                        ForEach(visibleCredentials) { profile in
                            credentialRow(profile)
                                .tag(VaultSelection.credential(profile.id))
                                .simultaneousGesture(compactSelectionGesture(.credential(profile.id), enabled: compact))
                        }
                    }
                }

                if !visibleAuthorities.isEmpty {
                    Section("Центры сертификации") {
                        ForEach(visibleAuthorities) { authority in
                            authorityRow(authority)
                                .tag(VaultSelection.authority(authority.id))
                                .simultaneousGesture(compactSelectionGesture(.authority(authority.id), enabled: compact))
                        }
                    }
                }

                if !visibleKnownHosts.isEmpty {
                    Section("Известные хосты") {
                        ForEach(visibleKnownHosts) { entry in
                            knownHostRow(entry)
                                .tag(VaultSelection.knownHost(entry.id))
                                .simultaneousGesture(compactSelectionGesture(.knownHost(entry.id), enabled: compact))
                        }
                    }
                }

                if visibleKeys.isEmpty && visibleCredentials.isEmpty && visibleAuthorities.isEmpty && visibleKnownHosts.isEmpty {
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
                Divider()
                Button("Обновить Known Hosts", systemImage: "arrow.clockwise") {
                    refreshKnownHosts()
                }
            }

            Divider()
            agentStrip
        }
        .background(.ultraThinMaterial)
    }

    private var keychainSearchToolbar: some View {
        HStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск в Связке ключей", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))

            Menu {
                Picker("Сортировка", selection: $sortModeRaw) {
                    ForEach(VaultSortMode.allCases) { mode in
                        Label {
                            Text(LocalizedStringKey(mode.title))
                        } icon: {
                            Image(systemName: mode.systemImage)
                        }
                        .tag(mode.rawValue)
                    }
                }
            } label: {
                Label {
                    Text(LocalizedStringKey(sortMode.title))
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onChange(of: searchText) { _, _ in
            normalizeSelectionForFilter()
        }
    }

    private func matchesSearch(_ values: [String]) -> Bool {
        let query = normalizedSearchText
        guard !query.isEmpty else { return true }
        return values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func keyMatchesSearch(_ key: SSHKeyRecord) -> Bool {
        var values = [key.name, key.algorithm, key.fingerprint, key.privateKeyPath]
        if SSHKeyService.certificateURL(for: key) != nil {
            values += ["certificate", "сертификат"]
        }
        if SSHKeyService.isTouchIDCompatible(key) {
            values += ["Touch ID", "ECDSA"]
        }
        for profile in profilesUsing(key) {
            values += [profile.friendlyName, profile.host, profile.username]
        }
        return matchesSearch(values)
    }

    private func profileMatchesSearch(_ profile: ConnectionProfile) -> Bool {
        matchesSearch([profile.friendlyName, profile.host, profile.username, "password", "пароль"])
    }

    private func knownHostMatchesSearch(_ entry: SSHKnownHostEntry) -> Bool {
        var values = [entry.displayHost, entry.hosts, entry.algorithm, entry.fingerprint]
        values += profilesUsingKnownHost(entry).flatMap { [$0.friendlyName, $0.host] }
        return matchesSearch(values)
    }

    private func authorityMatchesSearch(_ authority: SSHCertificateAuthorityRecord) -> Bool {
        matchesSearch([
            authority.name,
            authority.algorithm,
            authority.fingerprint,
            authority.publicKeyPath,
            authority.privateKeyPath,
            "SSH CA"
        ])
    }

    private func keySort(_ lhs: SSHKeyRecord, _ rhs: SSHKeyRecord) -> Bool {
        switch sortMode {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .type:
            let type = lhs.algorithm.localizedStandardCompare(rhs.algorithm)
            return type == .orderedSame
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : type == .orderedAscending
        case .usage:
            let left = profilesUsing(lhs).count
            let right = profilesUsing(rhs).count
            return left == right
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : left > right
        case .fingerprint:
            return lhs.fingerprint.localizedStandardCompare(rhs.fingerprint) == .orderedAscending
        }
    }

    private func profileSort(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        switch sortMode {
        case .type:
            let left = sshPasswordRequiresTouchID(lhs) ? 0 : 1
            let right = sshPasswordRequiresTouchID(rhs) ? 0 : 1
            return left == right
                ? lhs.friendlyName.localizedStandardCompare(rhs.friendlyName) == .orderedAscending
                : left < right
        default:
            return lhs.friendlyName.localizedStandardCompare(rhs.friendlyName) == .orderedAscending
        }
    }

    private func knownHostSort(_ lhs: SSHKnownHostEntry, _ rhs: SSHKnownHostEntry) -> Bool {
        switch sortMode {
        case .type:
            let result = lhs.algorithm.localizedStandardCompare(rhs.algorithm)
            return result == .orderedSame
                ? lhs.displayHost.localizedStandardCompare(rhs.displayHost) == .orderedAscending
                : result == .orderedAscending
        case .usage:
            let left = profilesUsingKnownHost(lhs).count
            let right = profilesUsingKnownHost(rhs).count
            return left == right
                ? lhs.displayHost.localizedStandardCompare(rhs.displayHost) == .orderedAscending
                : left > right
        case .fingerprint:
            return lhs.fingerprint.localizedStandardCompare(rhs.fingerprint) == .orderedAscending
        case .name:
            return lhs.displayHost.localizedStandardCompare(rhs.displayHost) == .orderedAscending
        }
    }

    private func authoritySort(
        _ lhs: SSHCertificateAuthorityRecord,
        _ rhs: SSHCertificateAuthorityRecord
    ) -> Bool {
        switch sortMode {
        case .type:
            let result = lhs.algorithm.localizedStandardCompare(rhs.algorithm)
            return result == .orderedSame
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : result == .orderedAscending
        case .fingerprint:
            return lhs.fingerprint.localizedStandardCompare(rhs.fingerprint) == .orderedAscending
        case .name, .usage:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func sshPasswordRequiresTouchID(_ profile: ConnectionProfile) -> Bool {
        model.sshPasswordRequiresUserPresence(profileID: profile.id)
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        let certificate = SSHKeyService.certificateURL(for: key) != nil
        let touchIDCompatible = SSHKeyService.isTouchIDCompatible(key)
        let isSelected = selection == .key(key.id)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(vaultRowIconBackground(isSelected))
                Image(systemName: touchIDCompatible ? "touchid" : "key.horizontal")
                    .foregroundStyle(vaultRowIconForeground(isSelected))
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

    private func vaultRowIconBackground(_ isSelected: Bool) -> Color {
        isSelected
            ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.18)
            : Color.accentColor.opacity(0.12)
    }

    private func vaultRowIconForeground(_ isSelected: Bool) -> Color {
        isSelected
            ? Color(nsColor: .alternateSelectedControlTextColor)
            : Color.accentColor
    }

    private func credentialRow(_ profile: ConnectionProfile) -> some View {
        let protected = model.sshPasswordRequiresUserPresence(profileID: profile.id)
        let isSelected = selection == .credential(profile.id)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(vaultRowIconBackground(isSelected))
                Image(systemName: protected ? "touchid" : "ellipsis.rectangle.fill")
                    .foregroundStyle(vaultRowIconForeground(isSelected))
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

    private func knownHostRow(_ entry: SSHKnownHostEntry) -> some View {
        let isSelected = selection == .knownHost(entry.id)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(vaultRowIconBackground(isSelected))
                Image(systemName: entry.isHashed ? "lock.fill" : "server.rack")
                    .foregroundStyle(vaultRowIconForeground(isSelected))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayHost)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(entry.algorithm) · \(entry.fingerprint)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .some(.matches) = knownHostVerification[entry.id] {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else if case .some(.changed) = knownHostVerification[entry.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Копировать fingerprint", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.fingerprint, forType: .string)
            }
            if !entry.isHashed {
                Button("Копировать host", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.displayHost, forType: .string)
                }
                Button("Проверить ключ сервера", systemImage: "checkmark.shield") {
                    verifyKnownHost(entry)
                }
            }
            Divider()
            Button("Создать SSH-профиль…", systemImage: "plus.rectangle") {
                knownHostProfileCreationEntry = entry
            }
            .disabled(SSHKnownHostsService.profileConversionUnavailableReason(for: entry) != nil)
            Divider()
            Button("Удалить из known_hosts", systemImage: "trash", role: .destructive) {
                knownHostPendingDeletion = entry
            }
        }
    }

    private func authorityRow(_ authority: SSHCertificateAuthorityRecord) -> some View {
        let isSelected = selection == .authority(authority.id)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(vaultRowIconBackground(isSelected))
                Image(systemName: "seal.fill")
                    .foregroundStyle(vaultRowIconForeground(isSelected))
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(authority.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(authority.algorithm) · \(authority.fingerprint)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: authority.hasPrivateKey ? "checkmark.shield.fill" : "lock.open")
                .foregroundStyle(authority.hasPrivateKey ? Color.green : Color.secondary)
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Копировать fingerprint", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authority.fingerprint, forType: .string)
            }
            Button("Показать в Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: authority.publicKeyPath)])
            }
            Divider()
            Button("Удалить регистрацию", systemImage: "trash", role: .destructive) {
                SSHCertificateAuthorityService.remove(authority.id)
                refreshAuthorities()
            }
        }
    }

    private func authorityInspector(_ authority: SSHCertificateAuthorityRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.13))
                        Image(systemName: "seal.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(authority.name).font(.title2.bold())
                        Text("SSH Certificate Authority · \(authority.algorithm)").foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                GroupBox("Параметры CA") {
                    VStack(alignment: .leading, spacing: 10) {
                        adaptiveMetadataRow("Fingerprint", value: authority.fingerprint, monospaced: true)
                        adaptiveMetadataRow("Public key", value: authority.publicKeyPath, monospaced: true)
                        adaptiveMetadataRow("Private key", value: authority.privateKeyPath, monospaced: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(
                    authority.hasPrivateKey
                        ? "Private CA key найден рядом с public key. Он остаётся файлом и не копируется в Keychain."
                        : "Зарегистрирован только public CA key. Для выпуска сертификатов private CA key должен находиться рядом без расширения .pub.",
                    systemImage: authority.hasPrivateKey ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(authority.hasPrivateKey ? Color.green : Color.orange)

                GroupBox("Выпустить SSH certificate") {
                    if authority.hasPrivateKey {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Выберите SSH ID. Selective Remote вызовет системный ssh-keygen и создаст стандартный *-cert.pub рядом с public key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(model.sshKeys) { key in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(key.name).font(.subheadline.weight(.semibold))
                                        Text(key.fingerprint).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Подписать…") {
                                        signingRequest = SSHCertificateSigningRequest(key: key, authority: authority)
                                    }
                                    .disabled(key.publicKeyPath == nil)
                                }
                            }
                        }
                    } else {
                        Text("Подписание недоступно без private CA key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func importAuthority() {
        do {
            if let value = try SSHCertificateAuthorityService.chooseAndRegister() {
                refreshAuthorities()
                filter = .authorities
                selection = .authority(value.id)
            }
        } catch {
            knownHostsError = error.localizedDescription
        }
    }

    private func refreshAuthorities() {
        authorities = SSHCertificateAuthorityService.registered()
        if case let .authority(id) = selection, !authorities.contains(where: { $0.id == id }) {
            selection = authorities.first.map { .authority($0.id) }
        }
    }

    private var agentStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: agentCheckError == nil ? "memorychip" : "exclamationmark.triangle")
                .foregroundStyle(agentCheckError == nil ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    checkingAgent
                        ? UpdateLocalization.text(ru: "ssh-agent: проверка…", en: "ssh-agent: checking…")
                        : UpdateLocalization.text(
                            ru: "ssh-agent: \(agentLoadedKeyIDs.count) ключей",
                            en: "ssh-agent: \(agentLoadedKeyIDs.count) keys"
                        )
                )
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
        } else if let authority = selectedAuthority {
            authorityInspector(authority)
        } else if let entry = selectedKnownHost {
            knownHostInspector(entry)
        } else {
            ContentUnavailableView(
                "Выберите реквизиты",
                systemImage: "key.viewfinder",
                description: Text("Выберите SSH ID, сертификат или сохранённый пароль в списке слева.")
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
            VStack(alignment: .leading, spacing: 10) {
                adaptiveMetadataRow("Тип", value: key.algorithm)
                adaptiveMetadataRow("Fingerprint", value: key.fingerprint, monospaced: true)
                adaptiveMetadataRow("Private key", value: key.privateKeyPath, monospaced: true)
                adaptiveMetadataRow("Используется", value: profileUsageText(key))
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
                    if let status = certificateValidityStatus(certificateInfo) {
                        Label(status.text, systemImage: status.systemImage)
                            .foregroundStyle(status.color)
                            .font(.subheadline.weight(.semibold))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if let value = certificateInfo.type { adaptiveMetadataRow("Type", value: value) }
                        if let value = certificateInfo.keyID { adaptiveMetadataRow("Key ID", value: value) }
                        if let value = certificateInfo.serial { adaptiveMetadataRow("Serial", value: value) }
                        if let value = certificateInfo.validFrom { adaptiveMetadataRow("Valid from", value: value) }
                        if let value = certificateInfo.validTo { adaptiveMetadataRow("Valid to", value: value) }
                        if !certificateInfo.principals.isEmpty {
                            adaptiveMetadataRow("Principals", value: certificateInfo.principals.joined(separator: ", "))
                        }
                        adaptiveMetadataRow("Файл", value: certificateInfo.path, monospaced: true)
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
                Label(
                    loaded
                        ? UpdateLocalization.text(ru: "Ключ загружен", en: "Key is loaded")
                        : UpdateLocalization.text(ru: "Ключ не загружен", en: "Key is not loaded"),
                    systemImage: loaded ? "checkmark.circle.fill" : "circle"
                )
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

    private func knownHostInspector(_ entry: SSHKnownHostEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.13))
                        Image(systemName: entry.isHashed ? "lock.shield.fill" : "server.rack")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.displayHost).font(.title2.bold())
                        Text("Known Host · \(entry.algorithm)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { refreshKnownHosts() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Перечитать ~/.ssh/known_hosts")
                }

                inspectorCard("Host key", systemImage: "key.horizontal") {
                    VStack(alignment: .leading, spacing: 10) {
                        adaptiveMetadataRow("Host", value: entry.hosts, monospaced: true)
                        adaptiveMetadataRow("Тип", value: entry.algorithm)
                        adaptiveMetadataRow("Fingerprint", value: entry.fingerprint, monospaced: true)
                        adaptiveMetadataRow("Строка", value: String(entry.lineNumber))
                        if let marker = entry.marker { adaptiveMetadataRow("Marker", value: marker) }
                    }
                    HStack {
                        Button("Копировать fingerprint", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.fingerprint, forType: .string)
                        }
                        Spacer()
                        Button("Удалить запись", systemImage: "trash", role: .destructive) {
                            knownHostPendingDeletion = entry
                        }
                    }
                }

                inspectorCard("SSH-профиль", systemImage: "terminal") {
                    if let reason = SSHKnownHostsService.profileConversionUnavailableReason(for: entry) {
                        Label(reason, systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Создаёт обычный SSH-профиль из host и port этой записи. Файл known_hosts не изменяется.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Создать SSH-профиль…", systemImage: "plus.rectangle") {
                            knownHostProfileCreationEntry = entry
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                inspectorCard("Проверка сервера", systemImage: "checkmark.shield") {
                    if entry.isHashed {
                        Label("Имя хоста скрыто хешированием OpenSSH", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                        Text("Selective Remote не пытается раскрывать хешированную запись. Проверка выполняется штатным OpenSSH при подключении.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if verifyingKnownHostID == entry.id {
                        ProgressView("Получаем текущий host key…")
                    } else {
                        verificationView(for: entry)
                        Button("Проверить сейчас", systemImage: "arrow.triangle.2.circlepath") {
                            verifyKnownHost(entry)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                let profiles = profilesUsingKnownHost(entry)
                inspectorCard("Используется", systemImage: "rectangle.stack") {
                    if profiles.isEmpty {
                Text(
                    entry.isHashed
                        ? UpdateLocalization.text(
                            ru: "Связь с профилями для хешированной записи определить напрямую нельзя.",
                            en: "Profile relationships cannot be determined directly for a hashed entry."
                        )
                        : UpdateLocalization.text(
                            ru: "Сохранённые SSH-профили с этим host не найдены.",
                            en: "No saved SSH profiles use this host."
                        )
                )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profiles) { profile in
                            HStack {
                                Image(systemName: "terminal")
                                Text(profile.friendlyName)
                                Spacer()
                                Text(profile.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                inspectorCard("Файл", systemImage: "doc.text") {
                    Text(entry.sourcePath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("При удалении Selective Remote создаёт рядом резервную копию known_hosts.selectiveremote.bak.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func verificationView(for entry: SSHKnownHostEntry) -> some View {
        switch knownHostVerification[entry.id] {
        case .some(.matches):
            Label("Текущий ключ сервера совпадает с known_hosts", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .some(.changed(currentFingerprint: currentFingerprint)):
            VStack(alignment: .leading, spacing: 8) {
                Label("Host key изменился", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(UpdateLocalization.text(
                    ru: "Сохранённый: \(entry.fingerprint)",
                    en: "Saved: \(entry.fingerprint)"
                ))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(UpdateLocalization.text(
                    ru: "Текущий: \(currentFingerprint)",
                    en: "Current: \(currentFingerprint)"
                ))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Не заменяйте ключ автоматически, пока изменение не подтверждено администратором сервера.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .some(.unavailable(message)):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case .none:
            Text("Можно сравнить сохранённый ключ с ключом, который сервер отдаёт сейчас через ssh-keyscan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func inspectorCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizedStringKey(title), systemImage: systemImage)
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

    private func compactSelectionGesture(
        _ item: VaultSelection,
        enabled: Bool
    ) -> some Gesture {
        TapGesture().onEnded {
            guard enabled else { return }
            selection = item
            compactDetailPresented = true
        }
    }

    private func adaptiveMetadataRow(
        _ label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                metadataLabel(label)
                metadataValue(value, monospaced: monospaced)
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(label))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                metadataValue(value, monospaced: monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataValue(_ value: String, monospaced: Bool) -> some View {
        Text(value)
            .font(monospaced ? .caption.monospaced() : .caption)
            .textSelection(.enabled)
    }

    private func metadataLabel(_ value: String) -> some View {
        Text(LocalizedStringKey(value))
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
        return names.isEmpty
            ? UpdateLocalization.text(ru: "Не назначен профилям", en: "Not assigned to profiles")
            : names.joined(separator: ", ")
    }

    private func normalizeSelectionForFilter() {
        if let selectedKey, visibleKeys.contains(where: { $0.id == selectedKey.id }) { return }
        if let selectedCredential, visibleCredentials.contains(where: { $0.id == selectedCredential.id }) { return }
        if let selectedAuthority, visibleAuthorities.contains(where: { $0.id == selectedAuthority.id }) { return }
        if let selectedKnownHost, visibleKnownHosts.contains(where: { $0.id == selectedKnownHost.id }) { return }
        selection = visibleKeys.first.map { .key($0.id) }
            ?? visibleCredentials.first.map { .credential($0.id) }
            ?? visibleAuthorities.first.map { .authority($0.id) }
            ?? visibleKnownHosts.first.map { .knownHost($0.id) }
    }

    private func certificateValidityStatus(_ info: SSHCertificateInfo) -> (text: String, systemImage: String, color: Color)? {
        guard let raw = info.validTo else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let normalized = raw.contains("Z") || raw.contains("+") ? raw : raw + "Z"
        guard let date = formatter.date(from: normalized) else { return nil }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 {
            return ("Сертификат истёк", "xmark.octagon.fill", .red)
        }
        let days = Int(remaining / 86_400)
        if days <= 7 {
            return ("Истекает через \(max(days, 0)) дн.", "exclamationmark.triangle.fill", .orange)
        }
        return ("Сертификат действителен", "checkmark.seal.fill", .green)
    }

    private func refreshKnownHosts() {
        do {
            knownHosts = try SSHKnownHostsService.load()
            knownHostsError = nil
            if case let .knownHost(id) = selection, !knownHosts.contains(where: { $0.id == id }) {
                selection = knownHosts.first.map { .knownHost($0.id) }
            }
        } catch {
            knownHosts = []
            knownHostsError = error.localizedDescription
        }
    }

    private func profilesUsingKnownHost(_ entry: SSHKnownHostEntry) -> [ConnectionProfile] {
        guard !entry.isHashed else { return [] }
        let candidates = Set(entry.directHosts.map { raw -> String in
            if raw.hasPrefix("[") , let close = raw.firstIndex(of: "]") {
                return String(raw[raw.index(after: raw.startIndex)..<close]).lowercased()
            }
            return raw.lowercased()
        })
        return sshProfiles.filter { candidates.contains($0.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    private func verifyKnownHost(_ entry: SSHKnownHostEntry) {
        verifyingKnownHostID = entry.id
        Task {
            let result = await SSHKnownHostsService.verify(entry)
            knownHostVerification[entry.id] = result
            if verifyingKnownHostID == entry.id { verifyingKnownHostID = nil }
        }
    }

    private func deleteKnownHost(_ entry: SSHKnownHostEntry) {
        knownHostPendingDeletion = nil
        do {
            try SSHKnownHostsService.delete(entry)
            knownHostVerification[entry.id] = nil
            refreshKnownHosts()
        } catch {
            knownHostsError = error.localizedDescription
        }
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
