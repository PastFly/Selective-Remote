import Foundation
import SwiftUI

struct SSHKnownHostEndpoint: Identifiable, Hashable, Sendable {
    let host: String
    let port: Int
    var id: String { "\(SSHKnownHostProfileMatcher.normalizedHost(host))|\(port)" }
    var displayText: String {
        if host.contains(":") { return port == 22 ? host : "[\(host)]:\(port)" }
        return port == 22 ? host : "\(host):\(port)"
    }
}

extension SSHKnownHostsService {
    static func profileEndpoints(for entry: SSHKnownHostEntry) -> [SSHKnownHostEndpoint] {
        guard !entry.isHashed, entry.marker == nil else { return [] }
        let rawHosts = entry.directHosts
        guard !rawHosts.isEmpty, rawHosts.allSatisfy(isConcreteProfileHost) else { return [] }
        var seen = Set<String>()
        var result: [SSHKnownHostEndpoint] = []
        for raw in rawHosts {
            guard let endpoint = profileEndpoint(from: raw) else { return [] }
            if seen.insert(endpoint.id).inserted { result.append(endpoint) }
        }
        return result
    }

    static func profileConversionUnavailableReason(for entry: SSHKnownHostEntry) -> String? {
        if entry.isHashed { return "Нельзя создать профиль из хешированной записи: исходное имя хоста неизвестно." }
        if let marker = entry.marker { return "Запись \(marker) не является обычным конкретным SSH host key." }
        if entry.directHosts.contains(where: { !isConcreteProfileHost($0) }) {
            return "Запись содержит wildcard, отрицательный шаблон или другой host pattern."
        }
        return profileEndpoints(for: entry).isEmpty ? "Из записи не удалось получить конкретный SSH endpoint." : nil
    }

    private static func isConcreteProfileHost(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.hasPrefix("!") && !value.contains("*") && !value.contains("?") && !value.hasPrefix("|")
    }

    private static func profileEndpoint(from raw: String) -> SSHKnownHostEndpoint? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let suffix = String(value[value.index(after: close)...])
            if suffix.isEmpty { return SSHKnownHostEndpoint(host: host, port: 22) }
            guard suffix.hasPrefix(":"), let port = Int(suffix.dropFirst()), (1...65_535).contains(port) else { return nil }
            return SSHKnownHostEndpoint(host: host, port: port)
        }
        return SSHKnownHostEndpoint(host: value, port: 22)
    }
}

enum SSHKnownHostProfileMatcher {
    static func normalizedHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2 { host.removeFirst(); host.removeLast() }
        return host.lowercased()
    }

    static func exactDuplicate(in profiles: [ConnectionProfile], endpoint: SSHKnownHostEndpoint, username: String) -> ConnectionProfile? {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return endpointProfiles(in: profiles, endpoint: endpoint).first {
            $0.username.trimmingCharacters(in: .whitespacesAndNewlines) == user
        }
    }

    static func endpointProfiles(in profiles: [ConnectionProfile], endpoint: SSHKnownHostEndpoint) -> [ConnectionProfile] {
        let host = normalizedHost(endpoint.host)
        return profiles.filter {
            $0.connectionType == .ssh && normalizedHost($0.host) == host && $0.sshPort == endpoint.port
        }
    }
}

enum SSHKnownHostProfileCreationResult: Equatable { case created(UUID), duplicate(UUID) }

extension AppModel {
    @discardableResult
    func createSSHProfile(
        fromKnownHost endpoint: SSHKnownHostEndpoint,
        friendlyName: String,
        username: String,
        authenticationMode: SSHAuthenticationMode,
        identityID: UUID?
    ) -> SSHKnownHostProfileCreationResult {
        let name = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let duplicate = SSHKnownHostProfileMatcher.exactDuplicate(in: profiles, endpoint: endpoint, username: user) {
            selectedProfileID = duplicate.id
            statusMessage = "Открыт существующий SSH-профиль «\(duplicate.friendlyName)»"
            return .duplicate(duplicate.id)
        }
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.friendlyName = name.isEmpty ? endpoint.host : name
        profile.host = endpoint.host
        profile.username = user
        profile.sshPort = endpoint.port
        profile.sshAuthenticationMode = authenticationMode
        profile.sshIdentityID = authenticationMode == .key || authenticationMode == .touchIDKey ? identityID : nil
        profiles.append(profile)
        selectedProfileID = profile.id
        statusMessage = "Создан SSH-профиль «\(profile.friendlyName)» из Known Hosts"
        errorMessage = nil
        return .created(profile.id)
    }
}

struct KnownHostSSHProfileCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let entry: SSHKnownHostEntry
    let endpoints: [SSHKnownHostEndpoint]
    let onOpenProfile: (UUID) -> Void
    @State private var selectedEndpointID: SSHKnownHostEndpoint.ID
    @State private var friendlyName: String
    @State private var username = ""
    @State private var authenticationMode: SSHAuthenticationMode = .automatic
    @State private var identityID: UUID?

    init(entry: SSHKnownHostEntry, onOpenProfile: @escaping (UUID) -> Void) {
        let endpoints = SSHKnownHostsService.profileEndpoints(for: entry)
        self.entry = entry
        self.endpoints = endpoints
        self.onOpenProfile = onOpenProfile
        _selectedEndpointID = State(initialValue: endpoints.first?.id ?? "")
        _friendlyName = State(initialValue: endpoints.first?.host ?? entry.displayHost)
    }

    private var endpoint: SSHKnownHostEndpoint? { endpoints.first(where: { $0.id == selectedEndpointID }) ?? endpoints.first }
    private var identities: [SSHKeyRecord] {
        switch authenticationMode {
        case .key: model.sshKeys
        case .touchIDKey: model.sshKeys.filter(SSHKeyService.isTouchIDCompatible)
        case .automatic, .password, .agent: []
        }
    }
    private var requiresIdentity: Bool { authenticationMode == .key || authenticationMode == .touchIDKey }
    private var duplicate: ConnectionProfile? {
        guard let endpoint else { return nil }
        return SSHKnownHostProfileMatcher.exactDuplicate(in: model.profiles, endpoint: endpoint, username: username)
    }
    private var sameEndpointProfiles: [ConnectionProfile] {
        guard let endpoint else { return [] }
        return SSHKnownHostProfileMatcher.endpointProfiles(in: model.profiles, endpoint: endpoint).filter { $0.id != duplicate?.id }
    }
    private var canCreate: Bool {
        endpoint != nil && !friendlyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && duplicate == nil && (!requiresIdentity || identityID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.13))
                    Image(systemName: "terminal").font(.system(size: 21, weight: .semibold)).foregroundStyle(Color.accentColor)
                }.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Создать SSH-профиль").font(.title3.bold())
                    Text("На основе записи из ~/.ssh/known_hosts").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18)
            Divider()
            Form {
                if endpoints.count > 1 {
                    Picker("Адрес", selection: $selectedEndpointID) { ForEach(endpoints) { Text($0.displayText).tag($0.id) } }
                }
                TextField("Название профиля", text: $friendlyName)
                if let endpoint {
                    LabeledContent("Host") { Text(endpoint.host).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    LabeledContent("Port") { Text(String(endpoint.port)).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
                TextField("Пользователь", text: $username)
                Picker("Аутентификация", selection: $authenticationMode) {
                    ForEach(SSHAuthenticationMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                if requiresIdentity {
                    Picker("SSH ID", selection: $identityID) {
                        Text("Выберите SSH ID").tag(Optional<UUID>.none)
                        ForEach(identities) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if identities.isEmpty {
                        Label(authenticationMode == .touchIDKey ? "Нет совместимых Touch ID ECDSA-ключей." : "В Selective Remote пока нет SSH ID.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if authenticationMode == .password {
                    Text("Пароль здесь не сохраняется. Selective Remote запросит его при подключении, после чего его можно сохранить в Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let duplicate {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Такой SSH-профиль уже существует: \(duplicate.friendlyName)", systemImage: "rectangle.stack").foregroundStyle(.orange)
                        Button("Открыть существующий", systemImage: "arrow.right.circle") { onOpenProfile(duplicate.id); dismiss() }
                    }
                } else if !sameEndpointProfiles.isEmpty {
                    Text("Для этого host:port уже есть профиль: " + sameEndpointProfiles.map(\.friendlyName).joined(separator: ", ") + ". С другим пользователем можно создать отдельный профиль.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).padding(.horizontal, 8)
            Divider()
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }
                Spacer()
                Button("Создать профиль") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canCreate)
            }.padding(16)
        }
        .frame(width: 480, height: 500)
        .onChange(of: authenticationMode) { _, _ in
            if !identities.contains(where: { $0.id == identityID }) { identityID = identities.first?.id }
        }
    }

    private func create() {
        guard let endpoint else { return }
        let result = model.createSSHProfile(fromKnownHost: endpoint, friendlyName: friendlyName, username: username,
                                            authenticationMode: authenticationMode, identityID: identityID)
        switch result {
        case let .created(id), let .duplicate(id): onOpenProfile(id)
        }
        dismiss()
    }
}
