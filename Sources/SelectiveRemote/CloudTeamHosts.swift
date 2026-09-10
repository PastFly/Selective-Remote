import CryptoKit
import Foundation
import SwiftUI

struct SelectiveRemoteTeamVaultMaterializedSnapshot: Equatable, Sendable {
    let teamID: UUID
    let teamName: String
    let role: SelectiveRemoteCloudTeamRole
    let vaultID: UUID
    let vaultName: String
    let revision: Int
    let keyGeneration: Int
    let payload: Data
}

struct SelectiveRemoteTeamHost: Identifiable, Equatable {
    let id: UUID
    let recordID: UUID
    let teamID: UUID
    let teamName: String
    let role: SelectiveRemoteCloudTeamRole
    let vaultID: UUID
    let vaultName: String
    let revision: Int
    let keyGeneration: Int
    let modifiedAt: String
    let address: String
    let profile: ConnectionProfile
}

enum SelectiveRemoteTeamHostMaterializationError: Error, Equatable {
    case invalidSnapshot
    case invalidHostRecord
}

enum SelectiveRemoteTeamHostMaterializer {
    private static let browserKeys: Set<String> = ["title", "address"]
    private static let macOSKeys: Set<String> = [
        "title", "address", "username", "connectionType", "profile"
    ]
    private static let maximumProfileBytes = 384 * 1024

    static func materialize(
        _ snapshot: SelectiveRemoteTeamVaultMaterializedSnapshot
    ) throws -> [SelectiveRemoteTeamHost] {
        guard snapshot.teamID.isSelectiveRemoteCloudUUID,
              snapshot.vaultID.isSelectiveRemoteCloudUUID,
              snapshot.revision > 0,
              snapshot.keyGeneration > 0,
              validName(snapshot.teamName),
              validName(snapshot.vaultName)
        else { throw SelectiveRemoteTeamHostMaterializationError.invalidSnapshot }

        let document: SelectiveRemoteVaultDocument
        do {
            document = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
        } catch {
            throw SelectiveRemoteTeamHostMaterializationError.invalidSnapshot
        }

        return try document.records.compactMap { record in
            guard record.type == .host else { return nil }
            guard case let .object(data) = record.data,
                  let title = string(data["title"]),
                  let address = string(data["address"]),
                  validTitle(title),
                  validAddress(address)
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }

            let input: ConnectionProfile
            let keys = Set(data.keys)
            if keys == browserKeys {
                input = try browserProfile(
                    recordID: record.id,
                    title: title,
                    address: address
                )
            } else if keys == macOSKeys {
                guard let username = string(data["username"]),
                      let connectionType = string(data["connectionType"]),
                      let encodedProfile = string(data["profile"]),
                      username.count <= 256,
                      !username.contains(where: { $0.isNewline }),
                      encodedProfile.utf8.count <= maximumProfileBytes * 2,
                      let profileData = Data(selectiveRemoteBase64URL: encodedProfile),
                      profileData.count <= maximumProfileBytes
                else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let decoded = try? decoder.decode(ConnectionProfile.self, from: profileData),
                      decoded.id == record.id,
                      decoded.connectionType.rawValue == connectionType,
                      decoded.username == username,
                      exportedAddress(decoded) == address,
                      exportedTitle(decoded, address: address) == title
                else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }
                input = decoded
            } else {
                throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
            }

            return SelectiveRemoteTeamHost(
                id: scopedID(
                    teamID: snapshot.teamID,
                    vaultID: snapshot.vaultID,
                    recordID: record.id
                ),
                recordID: record.id,
                teamID: snapshot.teamID,
                teamName: snapshot.teamName,
                role: snapshot.role,
                vaultID: snapshot.vaultID,
                vaultName: snapshot.vaultName,
                revision: snapshot.revision,
                keyGeneration: snapshot.keyGeneration,
                modifiedAt: record.modifiedAt,
                address: address,
                profile: try sanitized(
                    input,
                    title: title,
                    runtimeID: scopedID(
                        teamID: snapshot.teamID,
                        vaultID: snapshot.vaultID,
                        recordID: record.id
                    )
                )
            )
        }
    }

    static func scopedID(teamID: UUID, vaultID: UUID, recordID: UUID) -> UUID {
        let scope = [
            "selective-remote/team-host/v1",
            teamID.canonicalCloudString,
            vaultID.canonicalCloudString,
            recordID.canonicalCloudString
        ].joined(separator: "\u{0}")
        var bytes = Array(SHA256.hash(data: Data(scope.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func browserProfile(
        recordID: UUID,
        title: String,
        address: String
    ) throws -> ConnectionProfile {
        var profile = ConnectionProfile(connectionType: .rdp)
        profile.id = recordID
        profile.friendlyName = title

        guard address.contains("://") else {
            profile.host = address
            return profile
        }
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }

        switch scheme {
        case "rdp", "ssh", "telnet":
            guard let host = components.host,
                  !host.isEmpty,
                  components.path.isEmpty || components.path == "/"
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }
            let username = components.user ?? ""
            if scheme == "rdp" {
                profile.connectionType = .rdp
                profile.host = addressHost(host, port: components.port)
                profile.username = username
            } else if scheme == "ssh" {
                profile.connectionType = .ssh
                profile.host = host
                profile.username = username
                profile.sshPort = components.port ?? 22
            } else {
                profile.connectionType = .telnet
                profile.host = host
                profile.sshPort = components.port ?? 23
            }
        case "serial":
            guard components.host == nil,
                  components.user == nil,
                  components.port == nil,
                  components.path.hasPrefix("/dev/cu.")
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }
            profile.connectionType = .serial
            profile.serialDevicePath = components.path
        default:
            throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
        }
        return profile
    }

    private static func sanitized(
        _ input: ConnectionProfile,
        title: String,
        runtimeID: UUID
    ) throws -> ConnectionProfile {
        guard input.id.isSelectiveRemoteCloudUUID,
              input.username.count <= 256,
              !input.username.contains(where: { $0.isNewline }),
              input.gatewayHost.utf8.count <= 2_048,
              input.gatewayUsername.utf8.count <= 256,
              !input.gatewayHost.contains(where: { $0.isNewline }),
              !input.gatewayUsername.contains(where: { $0.isNewline })
        else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }

        switch input.connectionType {
        case .rdp:
            guard validEndpoint(input.host) else {
                throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
            }
        case .ssh, .telnet:
            guard validEndpoint(input.host), (1 ... 65_535).contains(input.sshPort) else {
                throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
            }
        case .serial:
            guard input.serialDevicePath.hasPrefix("/dev/cu."),
                  input.serialDevicePath.utf8.count <= 2_048,
                  !input.serialDevicePath.contains(where: { $0.isNewline }),
                  TerminalTransportService.supportedBaudRates.contains(input.serialBaudRate),
                  (5 ... 8).contains(input.serialDataBits),
                  (1 ... 2).contains(input.serialStopBits)
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }
        }

        var safe = ConnectionProfile(connectionType: input.connectionType)
        safe.id = runtimeID
        safe.friendlyName = title
        safe.host = input.host
        safe.username = input.username
        safe.sshPort = input.sshPort
        safe.sshTerminalProtocol = .ssh
        safe.sshAuthenticationMode = .automatic
        safe.sshHostKeyPolicy = input.sshHostKeyPolicy
        safe.sshCompression = input.sshCompression
        safe.sshKeepAliveSeconds = min(max(input.sshKeepAliveSeconds, 0), 3_600)
        safe.serialDevicePath = input.serialDevicePath
        safe.serialBaudRate = input.serialBaudRate
        safe.serialDataBits = input.serialDataBits
        safe.serialParity = input.serialParity
        safe.serialStopBits = input.serialStopBits
        safe.serialFlowControl = input.serialFlowControl
        safe.gatewayHost = input.gatewayHost
        safe.gatewayUsername = input.gatewayUsername
        safe.windowsScale = input.windowsScale
        safe.rdpQuality = input.rdpQuality
        safe.certificatePolicy = input.certificatePolicy == .ignore
            ? .trustOnFirstUse
            : input.certificatePolicy
        safe.clipboardMode = .disabled
        safe.audioMode = .muted
        safe.redirectMicrophone = false
        safe.redirectCamera = false
        safe.redirectPrinters = false
        safe.redirectedFolders = []
        safe.sshIdentityID = nil
        safe.sshProxyMode = .none
        safe.sshProxyHost = ""
        safe.sshProxyUsername = ""
        safe.sshJumpHostProfileID = nil
        safe.sshAgentForwarding = false
        safe.sshStartupSnippetID = nil
        safe.sshStartupSnippetMode = .disabled
        safe.sshStartupSnippetAfterReconnect = false
        safe.terminalVariables = []
        safe.portForwards = []
        safe.selectedDisplayIDs = []
        safe.primaryDisplayID = nil
        safe.displayLayoutMode = .automatic
        safe.virtualDisplayOrigins = [:]
        safe.customKeyMappings = []
        safe.isFavorite = false
        safe.autoReconnect = false
        safe.reconnectAfterWake = false
        safe.adminSession = false
        safe.startFullScreen = false
        safe.rdpWindowMode = .fixedWindow
        safe.windowWidth = min(max(input.windowWidth, 640), 16_384)
        safe.windowHeight = min(max(input.windowHeight, 480), 16_384)
        safe.detectedOperatingSystem = ""
        safe.detectedOperatingSystemID = ""
        safe.detectedOperatingSystemLike = ""
        safe.operatingSystemDetectedAt = nil
        safe.group = ""
        safe.tags = []
        safe.profileDescription = ""
        safe.createdAt = Date(timeIntervalSince1970: 0)
        safe.lastConnectedAt = nil
        return safe
    }

    private static func exportedAddress(_ profile: ConnectionProfile) -> String {
        profile.connectionType == .serial ? profile.serialDevicePath : profile.host
    }

    private static func exportedTitle(_ profile: ConnectionProfile, address: String) -> String {
        let normalized = profile.friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((normalized.isEmpty ? address : normalized).prefix(120))
    }

    private static func addressHost(_ host: String, port: Int?) -> String {
        let value = host.contains(":") ? "[\(host)]" : host
        return port.map { "\(value):\($0)" } ?? value
    }

    private static func string(_ value: SelectiveRemoteJSONValue?) -> String? {
        guard case let .string(result) = value else { return nil }
        return result
    }

    private static func validName(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty
            && normalized == value
            && value.count <= 120
            && !value.contains(where: { $0.isNewline })
    }

    private static func validTitle(_ value: String) -> Bool {
        validName(value)
    }

    private static func validAddress(_ value: String) -> Bool {
        validEndpoint(value)
    }

    private static func validEndpoint(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty
            && normalized == value
            && value.utf8.count <= 2_048
            && !value.contains(where: { $0.isNewline })
    }
}

@MainActor
final class SelectiveRemoteTeamHostStore: ObservableObject {
    static let shared = SelectiveRemoteTeamHostStore()

    @Published private(set) var hosts: [SelectiveRemoteTeamHost] = []
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var synchronizedVaultCount = 0
    @Published private(set) var invalidVaultCount = 0

    init() {}

    func replace(
        with snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot],
        now: Date = Date()
    ) {
        var next: [SelectiveRemoteTeamHost] = []
        var invalid = 0
        for snapshot in snapshots {
            do {
                next += try SelectiveRemoteTeamHostMaterializer.materialize(snapshot)
            } catch {
                invalid += 1
            }
        }
        hosts = next.sorted {
            let left = [$0.teamName, $0.vaultName, $0.profile.friendlyName]
                .map { $0.localizedLowercase }
            let right = [$1.teamName, $1.vaultName, $1.profile.friendlyName]
                .map { $0.localizedLowercase }
            return left == right
                ? $0.recordID.canonicalCloudString < $1.recordID.canonicalCloudString
                : left.lexicographicallyPrecedes(right)
        }
        synchronizedVaultCount = snapshots.count - invalid
        invalidVaultCount = invalid
        lastUpdatedAt = now
    }

    func clear() {
        hosts = []
        synchronizedVaultCount = 0
        invalidVaultCount = 0
        lastUpdatedAt = nil
    }
}

struct SelectiveRemoteTeamHostsView: View {
    @ObservedObject var store: SelectiveRemoteTeamHostStore
    @ObservedObject var model: AppModel
    let onOpenTerminal: (SelectiveRemoteTeamHost, String, String?) -> Void

    @State private var selectedHostID: UUID?
    @State private var username = ""
    @State private var password = ""
    @State private var gatewayPassword = ""

    private var selectedHost: SelectiveRemoteTeamHost? {
        store.hosts.first(where: { $0.id == selectedHostID })
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if store.hosts.isEmpty {
                    ContentUnavailableView(
                        UpdateLocalization.text(
                            ru: "Team Hosts пока не синхронизированы",
                            en: "Team Hosts have not synchronized yet"
                        ),
                        systemImage: "person.2.slash",
                        description: Text(UpdateLocalization.text(
                            ru: "Разблокируйте приложение и дождитесь безопасного Team Vault sync.",
                            en: "Unlock the app and wait for a safe Team Vault sync."
                        ))
                    )
                } else {
                    List(store.hosts, selection: $selectedHostID) { host in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                host.profile.friendlyName,
                                systemImage: host.profile.connectionType.systemImage
                            )
                            .font(.headline)
                            HStack(spacing: 5) {
                                Text(host.teamName)
                                Text("·")
                                Text(host.vaultName)
                                Text("·")
                                Text(host.profile.connectionType.title)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(host.address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .tag(host.id)
                    }
                    .listStyle(.sidebar)
                }

                Divider()
                HStack(spacing: 8) {
                    Label(
                        "\(store.hosts.count)",
                        systemImage: "externaldrive.connected.to.line.below"
                    )
                    if let lastUpdatedAt = store.lastUpdatedAt {
                        Text(lastUpdatedAt, style: .time)
                    }
                    Spacer()
                    if store.invalidVaultCount > 0 {
                        Label(
                            "\(store.invalidVaultCount)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .help(UpdateLocalization.text(
                            ru: "Некорректные Team Vaults скрыты целиком",
                            en: "Invalid Team Vaults are hidden in full"
                        ))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
            }
            .frame(minWidth: 290, idealWidth: 350, maxWidth: 440)

            Group {
                if let host = selectedHost {
                    hostDetail(host)
                } else {
                    ContentUnavailableView(
                        UpdateLocalization.text(ru: "Выберите Team Host", en: "Select a Team Host"),
                        systemImage: "person.2"
                    )
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { normalizeSelection() }
        .onChange(of: store.hosts.map(\.id)) { _, _ in normalizeSelection() }
        .onChange(of: selectedHostID) { _, _ in resetConnectionFields() }
    }

    private func hostDetail(_ host: SelectiveRemoteTeamHost) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: host.profile.connectionType.systemImage)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 54, height: 54)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.profile.friendlyName)
                            .font(.title2.bold())
                        Text(host.address)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text(roleTitle(host.role))
                        .font(.caption.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }

                GroupBox(UpdateLocalization.text(ru: "Общий ресурс", en: "Shared Resource")) {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledContent("Team", value: host.teamName)
                        LabeledContent("Vault", value: host.vaultName)
                        LabeledContent(
                            UpdateLocalization.text(ru: "Ревизия", en: "Revision"),
                            value: "\(host.revision)"
                        )
                        LabeledContent(
                            UpdateLocalization.text(ru: "Поколение ключа", en: "Key Generation"),
                            value: "\(host.keyGeneration)"
                        )
                    }
                    .padding(6)
                }

                GroupBox(UpdateLocalization.text(ru: "Подключение", en: "Connection")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if host.profile.connectionType == .rdp
                            || host.profile.connectionType == .ssh {
                            TextField(
                                UpdateLocalization.text(ru: "Пользователь", en: "Username"),
                                text: $username
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        if host.profile.connectionType == .rdp
                            || host.profile.connectionType == .ssh {
                            SecureField(
                                host.profile.connectionType == .rdp
                                    ? UpdateLocalization.text(
                                        ru: "Пароль RDP (не сохраняется)",
                                        en: "RDP Password (not saved)"
                                    )
                                    : UpdateLocalization.text(
                                        ru: "Пароль SSH, если нужен (не сохраняется)",
                                        en: "SSH Password, if needed (not saved)"
                                    ),
                                text: $password
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        if host.profile.connectionType == .rdp,
                           !host.profile.gatewayHost.isEmpty {
                            SecureField(
                                UpdateLocalization.text(
                                    ru: "Пароль Gateway (не сохраняется)",
                                    en: "Gateway Password (not saved)"
                                ),
                                text: $gatewayPassword
                            )
                            .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            if host.profile.connectionType == .rdp,
                               model.isSessionRunning(profileID: host.id) {
                                Button(
                                    UpdateLocalization.text(ru: "Отключить", en: "Disconnect"),
                                    role: .destructive
                                ) {
                                    model.disconnect(profileID: host.id)
                                }
                            } else {
                                Button(
                                    connectionButtonTitle(host.profile.connectionType),
                                    systemImage: host.profile.connectionType == .rdp
                                        ? "play.fill"
                                        : "terminal"
                                ) {
                                    connect(host)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    host.profile.connectionType == .rdp
                                        && password.isEmpty
                                )
                            }
                            Spacer()
                        }

                        Label(
                            UpdateLocalization.text(
                                ru: "Проекция только для чтения: профиль не добавляется в Personal Vault, введённые пароли не сохраняются.",
                                en: "Read-only projection: the profile is not added to Personal Vault and entered passwords are not saved."
                            ),
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(24)
        }
    }

    private func connect(_ host: SelectiveRemoteTeamHost) {
        var profile = host.profile
        profile.username = username
        if profile.connectionType == .rdp {
            model.connectTeamHost(
                profile,
                password: password,
                gatewayPassword: gatewayPassword
            )
        } else {
            onOpenTerminal(host, username, password.isEmpty ? nil : password)
        }
        password = ""
        gatewayPassword = ""
    }

    private func normalizeSelection() {
        if let selectedHostID,
           store.hosts.contains(where: { $0.id == selectedHostID }) {
            return
        }
        self.selectedHostID = store.hosts.first?.id
        resetConnectionFields()
    }

    private func resetConnectionFields() {
        username = selectedHost?.profile.username ?? ""
        password = ""
        gatewayPassword = ""
    }

    private func roleTitle(_ role: SelectiveRemoteCloudTeamRole) -> String {
        switch role {
        case .owner: "Owner"
        case .admin: "Admin"
        case .editor: "Editor"
        case .viewer: "Viewer"
        }
    }

    private func connectionButtonTitle(_ type: ConnectionType) -> String {
        switch type {
        case .rdp: UpdateLocalization.text(ru: "Подключить RDP", en: "Connect RDP")
        case .ssh: UpdateLocalization.text(ru: "Открыть SSH", en: "Open SSH")
        case .telnet: UpdateLocalization.text(ru: "Открыть Telnet", en: "Open Telnet")
        case .serial: UpdateLocalization.text(ru: "Открыть Serial", en: "Open Serial")
        }
    }
}
