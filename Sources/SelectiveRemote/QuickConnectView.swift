import SwiftUI

enum QuickConnectAction {
    case terminal
    case sftp
    case connect
}

struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let onOpenProfile: (UUID, QuickConnectAction) -> Void
    let onOpenSSH: (QuickConnectSSHRequest) -> Void

    @State private var query = ""
    @State private var configHosts: [SSHConfigHost] = []
    @State private var recentTargets: [QuickConnectRecentTarget] = []
    @State private var authenticationMode: SSHAuthenticationMode = .automatic
    @State private var identityID: UUID?
    @State private var jumpHostProfileID: UUID?
    @State private var password = ""
    @State private var saveAsProfile = false
    @State private var profileName = ""

    private var parsedTarget: QuickConnectTarget? {
        QuickConnectParser.parse(query)
    }

    private var sshProfiles: [ConnectionProfile] {
        model.profiles
            .filter { $0.connectionType == .ssh }
            .sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending
            }
    }

    private var matchingProfiles: [ConnectionProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = model.profiles.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            let left = $0.lastConnectedAt ?? .distantPast
            let right = $1.lastConnectedAt ?? .distantPast
            if left != right { return left > right }
            return $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending
        }
        guard !needle.isEmpty else { return Array(source.prefix(12)) }
        return source.filter {
            $0.friendlyName.localizedCaseInsensitiveContains(needle)
                || $0.host.localizedCaseInsensitiveContains(needle)
                || $0.username.localizedCaseInsensitiveContains(needle)
                || $0.group.localizedCaseInsensitiveContains(needle)
        }
    }

    private var matchingConfigHosts: [SSHConfigHost] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedAliases = Set(
            model.profiles
                .filter { $0.connectionType == .ssh }
                .map { $0.host.lowercased() }
        )
        let source = configHosts.filter { !importedAliases.contains($0.alias.lowercased()) }
        guard !needle.isEmpty else { return Array(source.prefix(8)) }
        return source.filter {
            $0.alias.localizedCaseInsensitiveContains(needle)
                || $0.hostName.localizedCaseInsensitiveContains(needle)
                || $0.user.localizedCaseInsensitiveContains(needle)
        }
    }

    private var availableIdentityKeys: [SSHKeyRecord] {
        if authenticationMode == .touchIDKey {
            return model.sshKeys.filter { SSHKeyService.isTouchIDCompatible($0) }
        }
        return model.sshKeys
    }

    private var showsIdentityPicker: Bool {
        authenticationMode == .automatic
            || authenticationMode == .key
            || authenticationMode == .touchIDKey
    }

    private var requiresIdentity: Bool {
        authenticationMode == .key || authenticationMode == .touchIDKey
    }

    private var canDirectConnect: Bool {
        parsedTarget != nil && (!requiresIdentity || identityID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()

            List {
                if let target = parsedTarget {
                    directConnectionSection(target)
                }

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !recentTargets.isEmpty {
                    recentSection
                }

                if !matchingProfiles.isEmpty {
                    profilesSection
                }

                if !matchingConfigHosts.isEmpty {
                    configSection
                }

                if parsedTarget == nil,
                   matchingProfiles.isEmpty,
                   matchingConfigHosts.isEmpty {
                    ContentUnavailableView(
                        "Ничего не найдено",
                        systemImage: "magnifyingglass",
                        description: Text("Введите user@host, ssh user@host -p 2222, hostname или имя профиля.")
                    )
                    .frame(minHeight: 220)
                }
            }
            .listStyle(.inset)

            footer
        }
        .frame(width: 820, height: 690)
        .onAppear {
            configHosts = SSHConfigService.loadHosts()
            recentTargets = QuickConnectRecentStore.load()
        }
        .onChange(of: authenticationMode) { _, mode in
            if mode == .touchIDKey,
               let identityID,
               let key = model.sshKeys.first(where: { $0.id == identityID }),
               !SSHKeyService.isTouchIDCompatible(key) {
                self.identityID = nil
            }
            if mode != .password && mode != .automatic {
                password = ""
            }
        }
        .onChange(of: parsedTarget?.destination) { _, destination in
            if saveAsProfile && profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profileName = destination ?? ""
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Color.accentColor)
            TextField("user@host · user@host:port · ssh user@host -p 2222", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func directConnectionSection(_ target: QuickConnectTarget) -> some View {
        Section("Быстрое SSH-подключение") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.destination)
                            .font(.headline.monospaced())
                        Text("Временное подключение через системный /usr/bin/ssh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Подключиться") { connectDirect(target) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canDirectConnect)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("Аутентификация").foregroundStyle(.secondary)
                        Picker("Аутентификация", selection: $authenticationMode) {
                            ForEach(SSHAuthenticationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300)
                    }

                    if showsIdentityPicker {
                        GridRow {
                            Text(authenticationMode == .touchIDKey ? "Touch ID Key" : "SSH ID")
                                .foregroundStyle(.secondary)
                            Picker("SSH ID", selection: $identityID) {
                                Text(authenticationMode == .automatic ? "По умолчанию" : "Не выбран")
                                    .tag(Optional<UUID>.none)
                                ForEach(availableIdentityKeys) { key in
                                    Text(key.name).tag(Optional(key.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }
                    }

                    if authenticationMode == .password || authenticationMode == .automatic {
                        GridRow {
                            Text("Пароль").foregroundStyle(.secondary)
                            SecureField(
                                authenticationMode == .automatic ? "Необязательно" : "SSH password",
                                text: $password
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        }
                    }

                    GridRow {
                        Text("Jump Host").foregroundStyle(.secondary)
                        Picker("Jump Host", selection: $jumpHostProfileID) {
                            Text("Прямое подключение").tag(Optional<UUID>.none)
                            ForEach(sshProfiles) { profile in
                                Text(profile.friendlyName).tag(Optional(profile.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300)
                    }
                }

                Divider()

                Toggle("Сохранить как SSH-профиль", isOn: $saveAsProfile)
                if saveAsProfile {
                    TextField("Название профиля", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                } else {
                    Text("Пароль временного подключения хранится только в macOS Keychain на время SSH-сессии и удаляется после её завершения.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if requiresIdentity && identityID == nil {
                    Label("Для выбранного способа входа требуется SSH ID.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var recentSection: some View {
        Section("Недавние адреса") {
            ForEach(recentTargets) { recent in
                Button {
                    query = recent.target.destination
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(recent.target.destination)
                            .font(.body.monospaced())
                        Spacer()
                        Text(recent.lastUsedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var profilesSection: some View {
        Section("Подключения") {
            ForEach(matchingProfiles) { profile in
                HStack(spacing: 12) {
                    Image(systemName: profile.connectionType.systemImage)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(profile.connectionType == .rdp ? Color.blue : Color.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(profile.friendlyName.isEmpty ? profile.host : profile.friendlyName)
                                .font(.body.weight(.semibold))
                            if profile.isFavorite {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                            }
                        }
                        Text(profile.host.isEmpty ? "Hostname не указан" : profile.host)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if profile.connectionType != .rdp {
                        Button("Terminal") { open(profile.id, .terminal) }
                            .buttonStyle(.bordered)
                        if profile.connectionType == .ssh {
                            Button("SFTP") { open(profile.id, .sftp) }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Button("RDP") { open(profile.id, .connect) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    open(profile.id, profile.connectionType == .rdp ? .connect : .terminal)
                }
            }
        }
    }

    private var configSection: some View {
        Section("~/.ssh/config") {
            ForEach(matchingConfigHosts) { host in
                HStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.alias).font(.body.weight(.semibold))
                        Text(host.displayDestination)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let proxyJump = host.proxyJump, !proxyJump.isEmpty {
                            Label(
                                UpdateLocalization.text(
                                    ru: "через \(proxyJump)",
                                    en: "via \(proxyJump)"
                                ),
                                systemImage: "arrow.triangle.branch"
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Импортировать и открыть") {
                        if let id = model.importSSHConfigHost(host) {
                            open(id, .terminal)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 5)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("⌘K · Quick Connect")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text("Пароли не сохраняются в истории")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Закрыть") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private func connectDirect(_ target: QuickConnectTarget) {
        QuickConnectRecentStore.record(target)
        recentTargets = QuickConnectRecentStore.load()
        let request = QuickConnectSSHRequest(
            target: target,
            authenticationMode: authenticationMode,
            identityID: identityID,
            jumpHostProfileID: jumpHostProfileID,
            password: password,
            saveAsProfile: saveAsProfile,
            profileName: profileName
        )
        dismiss()
        onOpenSSH(request)
    }

    private func open(_ id: UUID, _ action: QuickConnectAction) {
        dismiss()
        onOpenProfile(id, action)
    }
}
