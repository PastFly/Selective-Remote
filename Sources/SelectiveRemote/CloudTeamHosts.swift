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
    let credentials: SelectiveRemoteTeamHostCredentials
}

struct SelectiveRemoteTeamHostCredentials: Equatable, Sendable {
    var password: String?
    var gatewayPassword: String?

    static let empty = Self(password: nil, gatewayPassword: nil)
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
    private static let organizationKeys: Set<String> = ["folder", "tags", "description"]
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

        let credentials = try materializedCredentials(document.records)
        let hostIDs = Set(document.records.filter { $0.type == .host }.map(\.id))
        guard credentials.keys.allSatisfy(hostIDs.contains) else {
            throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
        }
        return try document.records.compactMap { record in
            guard record.type == .host else { return nil }
            guard case let .object(data) = record.data,
                  let title = string(data["title"]),
                  let address = string(data["address"]),
                  validTitle(title),
                  validAddress(address)
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }

            var input: ConnectionProfile
            let keys = Set(data.keys)
            let structuralKeys = keys.subtracting(organizationKeys)
            if structuralKeys == browserKeys {
                input = try browserProfile(
                    recordID: record.id,
                    title: title,
                    address: address
                )
            } else if structuralKeys == macOSKeys {
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
            input = try applyingOrganization(data, to: input)

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
                ),
                credentials: credentials[record.id] ?? .empty
            )
        }
    }

    private static func materializedCredentials(
        _ records: [SelectiveRemoteVaultRecord]
    ) throws -> [UUID: SelectiveRemoteTeamHostCredentials] {
        var result: [UUID: SelectiveRemoteTeamHostCredentials] = [:]
        for record in records where record.type == .credential {
            guard case let .object(data) = record.data,
                  Set(data.keys) == Set(["title", "username", "secret", "kind", "sourceID"]),
                  let source = string(data["sourceID"]),
                  let sourceID = UUID(uuidString: source),
                  sourceID.isSelectiveRemoteCloudUUID,
                  let secret = string(data["secret"]),
                  !secret.isEmpty,
                  secret.utf8.count <= 16_384,
                  let kind = string(data["kind"]),
                  kind == KeychainCredentialKind.rdp.rawValue
                    || kind == KeychainCredentialKind.ssh.rawValue
                    || kind == KeychainCredentialKind.gateway.rawValue
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }
            var value = result[sourceID] ?? .empty
            if kind == KeychainCredentialKind.gateway.rawValue {
                guard value.gatewayPassword == nil else {
                    throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
                }
                value.gatewayPassword = secret
            } else {
                guard value.password == nil else {
                    throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
                }
                value.password = secret
            }
            result[sourceID] = value
        }
        return result
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
              !input.gatewayUsername.contains(where: { $0.isNewline }),
              validOptionalName(input.group),
              input.tags.count <= 64,
              Set(input.tags).count == input.tags.count,
              input.tags.allSatisfy(validTag),
              input.profileDescription.utf8.count <= 2_048,
              !input.profileDescription.contains(where: { $0.isNewline })
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
        safe.group = input.group
        safe.sortIndex = input.sortIndex
        safe.tags = input.tags
        safe.profileDescription = input.profileDescription
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

    private static func applyingOrganization(
        _ data: [String: SelectiveRemoteJSONValue],
        to input: ConnectionProfile
    ) throws -> ConnectionProfile {
        var result = input
        if let value = data["folder"] {
            guard let folder = string(value), validOptionalName(folder) else {
                throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
            }
            result.group = folder
        }
        if let value = data["description"] {
            guard let description = string(value), description.utf8.count <= 2_048,
                  !description.contains(where: { $0.isNewline })
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }
            result.profileDescription = description
        }
        if let value = data["tags"] {
            guard case let .array(values) = value else {
                throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord
            }
            let tags = values.compactMap(string)
            guard tags.count == values.count, tags.count <= 24,
                  Set(tags).count == tags.count, tags.allSatisfy(validTag)
            else { throw SelectiveRemoteTeamHostMaterializationError.invalidHostRecord }
            result.tags = tags
        }
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

    private static func validOptionalName(_ value: String) -> Bool {
        value.isEmpty || validName(value)
    }

    private static func validTag(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty
            && normalized == value
            && value.count <= 64
            && !value.contains(where: { $0.isNewline })
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
    @Published private(set) var vaults: [SelectiveRemoteTeamHostVaultContext] = []
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var synchronizedVaultCount = 0
    @Published private(set) var invalidVaultCount = 0

    private var snapshots: [String: SelectiveRemoteTeamVaultMaterializedSnapshot] = [:]

    init() {}

    func replace(
        with snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot],
        now: Date = Date()
    ) {
        self.snapshots = Dictionary(
            snapshots.map { (scopeKey(teamID: $0.teamID, vaultID: $0.vaultID), $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        rebuild(now: now)
    }

    func replaceVault(
        with snapshot: SelectiveRemoteTeamVaultMaterializedSnapshot,
        now: Date = Date()
    ) {
        snapshots[scopeKey(teamID: snapshot.teamID, vaultID: snapshot.vaultID)] = snapshot
        rebuild(now: now)
    }

    func clear() {
        snapshots = [:]
        hosts = []
        vaults = []
        synchronizedVaultCount = 0
        invalidVaultCount = 0
        lastUpdatedAt = nil
    }

    private func rebuild(now: Date) {
        var nextHosts: [SelectiveRemoteTeamHost] = []
        var nextVaults: [SelectiveRemoteTeamHostVaultContext] = []
        var invalid = 0
        for snapshot in snapshots.values {
            do {
                nextHosts += try SelectiveRemoteTeamHostMaterializer.materialize(snapshot)
                nextVaults.append(.init(
                    id: SelectiveRemoteTeamHostMaterializer.scopedID(
                        teamID: snapshot.teamID,
                        vaultID: snapshot.vaultID,
                        recordID: snapshot.vaultID
                    ),
                    teamID: snapshot.teamID,
                    teamName: snapshot.teamName,
                    role: snapshot.role,
                    vaultID: snapshot.vaultID,
                    vaultName: snapshot.vaultName
                ))
            } catch {
                invalid += 1
            }
        }
        hosts = nextHosts.sorted {
            let left = [$0.teamName, $0.vaultName, $0.profile.friendlyName]
                .map { $0.localizedLowercase }
            let right = [$1.teamName, $1.vaultName, $1.profile.friendlyName]
                .map { $0.localizedLowercase }
            return left == right
                ? $0.recordID.canonicalCloudString < $1.recordID.canonicalCloudString
                : left.lexicographicallyPrecedes(right)
        }
        vaults = nextVaults.sorted {
            [$0.teamName.localizedLowercase, $0.vaultName.localizedLowercase]
                .lexicographicallyPrecedes(
                    [$1.teamName.localizedLowercase, $1.vaultName.localizedLowercase]
                )
        }
        synchronizedVaultCount = snapshots.count - invalid
        invalidVaultCount = invalid
        lastUpdatedAt = now
    }

    private func scopeKey(teamID: UUID, vaultID: UUID) -> String {
        "\(teamID.canonicalCloudString)/\(vaultID.canonicalCloudString)"
    }
}

struct SelectiveRemoteTeamHostsView: View {
    @ObservedObject var store: SelectiveRemoteTeamHostStore
    @ObservedObject var model: AppModel
    @ObservedObject private var personalSettingsStore =
        SelectiveRemoteTeamHostPersonalSettingsStore.shared
    let onOpenTerminal: (SelectiveRemoteTeamHost, String, String?) -> Void
    let onOpenSFTP: (SelectiveRemoteTeamHost, String, String?) -> Void

    @State private var selectedHostID: UUID?
    @State private var username = ""
    @State private var password = ""
    @State private var gatewayPassword = ""
    @State private var editorRequest: SelectiveRemoteTeamHostEditorRequest?
    @State private var personalSettingsHost: SelectiveRemoteTeamHost?
    @State private var hostPendingDeletion: SelectiveRemoteTeamHost?
    @State private var isMutating = false
    @State private var mutationMessage: SelectiveRemoteTeamHostMutationMessage?
    @State private var searchText = ""
    @State private var selectedFolder = ""
    @State private var expandedTeamIDs: Set<UUID> = []
    @State private var expandedFolderKeys: Set<String> = []
    @AppStorage("SelectiveRemote.cloud.endpoint.v1") private var endpoint = SelectiveRemoteCloudEndpoint.production
    @AppStorage("SelectiveRemote.cloud.device-id.v1") private var storedDeviceID = ""

    private let identityManager = SelectiveRemoteTeamDeviceIdentityManager()

    private var selectedHost: SelectiveRemoteTeamHost? {
        store.hosts.first(where: { $0.id == selectedHostID })
    }

    private var writableVaults: [SelectiveRemoteTeamHostVaultContext] {
        store.vaults.filter {
            SelectiveRemoteTeamHostDocumentMutation.isWritable(role: $0.role)
        }
    }

    private var folderNames: [String] {
        Array(Set(store.hosts.map { $0.profile.group }))
            .sorted { folderTitle($0).localizedCaseInsensitiveCompare(folderTitle($1)) == .orderedAscending }
    }

    private var teamIDs: [UUID] {
        Array(Set(visibleHosts.map(\.teamID))).sorted { left, right in
            let leftName = store.hosts.first(where: { $0.teamID == left })?.teamName ?? ""
            let rightName = store.hosts.first(where: { $0.teamID == right })?.teamName ?? ""
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }

    private func teamName(_ teamID: UUID) -> String {
        store.hosts.first(where: { $0.teamID == teamID })?.teamName
            ?? UpdateLocalization.text(ru: "Команда", en: "Team")
    }

    private func folders(in teamID: UUID) -> [String] {
        Array(Set(visibleHosts.filter { $0.teamID == teamID }.map { $0.profile.group }))
            .sorted { folderTitle($0).localizedCaseInsensitiveCompare(folderTitle($1)) == .orderedAscending }
    }

    private func outlineItems(in teamID: UUID) -> [SelectiveRemoteTeamHostOutlineItem] {
        SelectiveRemoteTeamHostOutlineItem.roots(
            teamID: teamID,
            hosts: visibleHosts.filter { $0.teamID == teamID }
        )
    }

    private var visibleHosts: [SelectiveRemoteTeamHost] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.hosts.filter { host in
            (selectedFolder.isEmpty || host.profile.group == selectedFolder)
                && (query.isEmpty || [
                    host.profile.friendlyName,
                    host.address,
                    host.profile.username,
                    host.teamName,
                    host.vaultName,
                    host.profile.group,
                    host.profile.tags.joined(separator: " ")
                ].contains { $0.localizedCaseInsensitiveContains(query) })
        }
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
                    List(selection: $selectedHostID) {
                        ForEach(teamIDs, id: \.self) { teamID in
                            DisclosureGroup(
                                isExpanded: expansionBinding(for: teamID)
                            ) {
                                OutlineGroup(outlineItems(in: teamID), children: \.children) { item in
                                    switch item.kind {
                                    case let .folder(path, name):
                                        Label(name, systemImage: path.isEmpty ? "tray" : "folder")
                                            .dropDestination(for: String.self) { values, _ in
                                                moveTeamHost(values, toFolder: path)
                                            }
                                    case let .host(host):
                                        hostRow(host)
                                            .tag(host.id)
                                            .draggable("team-host:\(host.id.uuidString)")
                                            .dropDestination(for: String.self) { values, _ in
                                                moveTeamHost(
                                                    values,
                                                    toFolder: host.profile.group,
                                                    before: host.id
                                                )
                                            }
                                    }
                                }
                            } label: {
                                Label(teamName(teamID), systemImage: "person.3.fill")
                                    .font(.headline)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .searchable(
                        text: $searchText,
                        prompt: UpdateLocalization.text(
                            ru: "Host, адрес, папка или тег",
                            en: "Host, address, folder, or tag"
                        )
                    )
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
                    Menu {
                        Button(UpdateLocalization.text(ru: "Все папки", en: "All Folders")) {
                            selectedFolder = ""
                        }
                        Divider()
                        ForEach(folderNames.filter { !$0.isEmpty }, id: \.self) { folder in
                            Button(folder) { selectedFolder = folder }
                        }
                    } label: {
                        Label(
                            selectedFolder.isEmpty
                                ? UpdateLocalization.text(ru: "Все папки", en: "All Folders")
                                : selectedFolder,
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }

                    Menu {
                        ForEach(writableVaults) { vault in
                            Button("\(vault.teamName) / \(vault.vaultName)") {
                                editorRequest = .init(context: vault, host: nil)
                            }
                        }
                    } label: {
                        Label(
                            UpdateLocalization.text(ru: "Добавить Host", en: "Add Host"),
                            systemImage: "plus"
                        )
                    }
                    .disabled(writableVaults.isEmpty || isMutating)
                    .help(writableVaults.isEmpty
                        ? UpdateLocalization.text(
                            ru: "Нет синхронизированного Team Vault с правом записи",
                            en: "No synchronized writable Team Vault"
                        )
                        : UpdateLocalization.text(
                            ru: "Добавить Host в Team Vault",
                            en: "Add a Host to a Team Vault"
                        )
                    )
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
        .onAppear {
            normalizeSelection()
            expandNewHierarchy()
        }
        .onChange(of: store.hosts.map(\.id)) { _, _ in
            normalizeSelection()
            expandNewHierarchy()
        }
        .onChange(of: selectedHostID) { _, _ in resetConnectionFields() }
        .sheet(item: $editorRequest) { request in
            SelectiveRemoteTeamHostEditorView(request: request) { profile, credentials in
                mutate(
                    request.host.map {
                        .update(recordID: $0.recordID, profile: profile, credentials: credentials)
                    } ?? .create(profile, credentials),
                    context: request.context,
                    selectedRecordID: profile.id
                )
            }
        }
        .sheet(item: $personalSettingsHost, onDismiss: resetConnectionFields) { host in
            SelectiveRemoteTeamHostPersonalSettingsView(
                host: host,
                endpoint: endpoint,
                store: personalSettingsStore
            )
        }
        .confirmationDialog(
            UpdateLocalization.text(ru: "Удалить Team Host?", en: "Delete Team Host?"),
            isPresented: Binding(
                get: { hostPendingDeletion != nil },
                set: { if !$0 { hostPendingDeletion = nil } }
            ),
            presenting: hostPendingDeletion
        ) { host in
            Button(
                UpdateLocalization.text(ru: "Удалить", en: "Delete"),
                role: .destructive
            ) {
                if let context = context(for: host) {
                    mutate(
                        .delete(recordID: host.recordID),
                        context: context,
                        selectedRecordID: nil
                    )
                }
                hostPendingDeletion = nil
            }
            Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel"), role: .cancel) {}
        } message: { host in
            Text(host.profile.friendlyName)
        }
        .alert(item: $mutationMessage) { value in
            Alert(
                title: Text(value.isError
                    ? UpdateLocalization.text(ru: "Team Host не изменён", en: "Team Host Not Changed")
                    : UpdateLocalization.text(ru: "Team Host обновлён", en: "Team Host Updated")
                ),
                message: Text(value.text),
                dismissButton: .default(Text("OK"))
            )
        }
        .overlay {
            if isMutating {
                ZStack {
                    Color.black.opacity(0.12)
                    ProgressView(UpdateLocalization.text(
                        ru: "Шифрование и синхронизация…",
                        en: "Encrypting and synchronizing…"
                    ))
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
    }

    private func hostRow(_ host: SelectiveRemoteTeamHost) -> some View {
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
            if !host.profile.tags.isEmpty {
                Text(host.profile.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func folderTitle(_ folder: String) -> String {
        folder.isEmpty
            ? UpdateLocalization.text(ru: "Без папки", en: "No Folder")
            : folder
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
                    Button(
                        UpdateLocalization.text(ru: "Мои настройки", en: "My Settings"),
                        systemImage: "person.crop.circle.badge.gearshape"
                    ) {
                        personalSettingsHost = host
                    }
                    if SelectiveRemoteTeamHostDocumentMutation.isWritable(role: host.role) {
                        Button(
                            UpdateLocalization.text(ru: "Изменить", en: "Edit"),
                            systemImage: "pencil"
                        ) {
                            if let context = context(for: host) {
                                editorRequest = .init(context: context, host: host)
                            }
                        }
                        .disabled(isMutating)
                        Button(
                            UpdateLocalization.text(ru: "Удалить", en: "Delete"),
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            hostPendingDeletion = host
                        }
                        .disabled(isMutating)
                    }
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
                            UpdateLocalization.text(ru: "Папка", en: "Folder"),
                            value: folderTitle(host.profile.group)
                        )
                        if !host.profile.tags.isEmpty {
                            LabeledContent(
                                UpdateLocalization.text(ru: "Теги", en: "Tags"),
                                value: host.profile.tags.map { "#\($0)" }.joined(separator: " ")
                            )
                        }
                        if !host.profile.profileDescription.isEmpty {
                            LabeledContent(
                                UpdateLocalization.text(ru: "Описание", en: "Description"),
                                value: host.profile.profileDescription
                            )
                        }
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
                        if host.profile.connectionType == .ssh
                            || host.profile.connectionType == .telnet {
                            LabeledContent(
                                UpdateLocalization.text(ru: "Порт", en: "Port"),
                                value: "\(host.profile.sshPort)"
                            )
                        }
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
                                        ru: "Пароль RDP (общий или временный)",
                                        en: "RDP Password (shared or temporary)"
                                    )
                                    : UpdateLocalization.text(
                                        ru: "Пароль SSH (общий или временный)",
                                        en: "SSH Password (shared or temporary)"
                                    ),
                                text: $password
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        if host.profile.connectionType == .rdp,
                           !host.profile.gatewayHost.isEmpty {
                            SecureField(
                                UpdateLocalization.text(
                                    ru: "Пароль Gateway (общий или временный)",
                                    en: "Gateway Password (shared or temporary)"
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
                            if host.profile.connectionType == .ssh {
                                Button(
                                    UpdateLocalization.text(ru: "Открыть SFTP", en: "Open SFTP"),
                                    systemImage: "folder.badge.gearshape"
                                ) {
                                    onOpenSFTP(
                                        host,
                                        username,
                                        password.isEmpty ? nil : password
                                    )
                                    password = host.credentials.password ?? ""
                                    gatewayPassword = host.credentials.gatewayPassword ?? ""
                                }
                            }
                            Spacer()
                        }

                        Label(
                            UpdateLocalization.text(
                                ru: "Общие пароли приходят из зашифрованного Team Vault. Изменить или удалить их могут Owner, Admin и Editor через карточку Host; временно введённое значение не сохраняется.",
                                en: "Shared passwords come from the encrypted Team Vault. Owners, Admins, and Editors can change or remove them in the Host editor; a temporary override is not saved."
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

    private func context(
        for host: SelectiveRemoteTeamHost
    ) -> SelectiveRemoteTeamHostVaultContext? {
        store.vaults.first {
            $0.teamID == host.teamID && $0.vaultID == host.vaultID
        }
    }

    private func mutate(
        _ change: SelectiveRemoteTeamHostMutationChange,
        context: SelectiveRemoteTeamHostVaultContext,
        selectedRecordID: UUID?
    ) {
        guard !isMutating else { return }
        isMutating = true
        Task { @MainActor in
            defer { isMutating = false }
            do {
                let url = try SelectiveRemoteCloudEndpoint.normalized(endpoint)
                let deviceID = resolvedDeviceID()
                let identity = try await identityManager.identity(
                    endpoint: url,
                    deviceID: deviceID
                )
                let service = try SelectiveRemoteTeamHostMutationService()
                let snapshot = try await service.apply(
                    change,
                    to: context,
                    endpoint: url,
                    identity: identity
                )
                store.replaceVault(with: snapshot)
                if let selectedRecordID {
                    selectedHostID = SelectiveRemoteTeamHostMaterializer.scopedID(
                        teamID: context.teamID,
                        vaultID: context.vaultID,
                        recordID: selectedRecordID
                    )
                } else {
                    selectedHostID = nil
                }
                mutationMessage = .init(
                    text: UpdateLocalization.text(
                        ru: "Зашифрованная Team Vault ревизия синхронизирована.",
                        en: "The encrypted Team Vault revision was synchronized."
                    ),
                    isError: false
                )
            } catch {
                mutationMessage = .init(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func moveTeamHost(
        _ values: [String],
        toFolder rawFolder: String,
        before targetID: UUID? = nil
    ) -> Bool {
        guard !isMutating,
              let value = values.first,
              value.hasPrefix("team-host:"),
              let hostID = UUID(uuidString: String(value.dropFirst("team-host:".count))),
              let host = store.hosts.first(where: { $0.id == hostID }),
              let context = context(for: host),
              SelectiveRemoteTeamHostDocumentMutation.isWritable(role: context.role)
        else { return false }

        let folder = SelectiveRemoteHostFolderPath.normalize(rawFolder)
        let scopedHosts = store.hosts.filter {
            $0.teamID == host.teamID && $0.vaultID == host.vaultID
        }
        var grouped = Dictionary(grouping: scopedHosts) { candidate in
            candidate.id == host.id
                ? folder
                : SelectiveRemoteHostFolderPath.normalize(candidate.profile.group)
        }
        var updates: [SelectiveRemoteTeamHostOrganizationUpdate] = []
        for path in grouped.keys.sorted() {
            var ordered = (grouped[path] ?? []).sorted { lhs, rhs in
                if lhs.profile.sortIndex != rhs.profile.sortIndex {
                    return lhs.profile.sortIndex < rhs.profile.sortIndex
                }
                return lhs.profile.friendlyName.localizedCaseInsensitiveCompare(
                    rhs.profile.friendlyName
                ) == .orderedAscending
            }
            if path == folder,
               let source = ordered.firstIndex(where: { $0.id == host.id }) {
                let moving = ordered.remove(at: source)
                let destination = targetID.flatMap { id in
                    ordered.firstIndex(where: { $0.id == id })
                } ?? ordered.endIndex
                ordered.insert(moving, at: destination)
            }
            for (sortIndex, candidate) in ordered.enumerated() {
                var profile = candidate.profile
                profile.group = path
                profile.sortIndex = sortIndex
                guard profile.group != candidate.profile.group
                        || profile.sortIndex != candidate.profile.sortIndex
                else { continue }
                updates.append(.init(
                    recordID: candidate.recordID,
                    profile: profile
                ))
            }
        }
        guard !updates.isEmpty else { return false }
        mutate(.organize(updates), context: context, selectedRecordID: host.recordID)
        return true
    }

    private func resolvedDeviceID() -> UUID {
        if let value = UUID(uuidString: storedDeviceID),
           value.isSelectiveRemoteCloudUUID {
            return value
        }
        let value = UUID()
        storedDeviceID = value.canonicalCloudString
        return value
    }

    private func expansionBinding(for teamID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedTeamIDs.contains(teamID) },
            set: { expanded in
                if expanded { expandedTeamIDs.insert(teamID) }
                else { expandedTeamIDs.remove(teamID) }
            }
        )
    }

    private func folderExpansionBinding(teamID: UUID, folder: String) -> Binding<Bool> {
        let key = "\(teamID.uuidString.lowercased())/\(folder)"
        return Binding(
            get: { expandedFolderKeys.contains(key) },
            set: { expanded in
                if expanded { expandedFolderKeys.insert(key) }
                else { expandedFolderKeys.remove(key) }
            }
        )
    }

    private func expandNewHierarchy() {
        for host in store.hosts {
            expandedTeamIDs.insert(host.teamID)
            expandedFolderKeys.insert(
                "\(host.teamID.uuidString.lowercased())/\(host.profile.group)"
            )
        }
    }

    private func connect(_ host: SelectiveRemoteTeamHost) {
        var profile = personalSettingsStore.appliedProfile(
            for: host,
            endpoint: endpoint
        )
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
        password = selectedHost?.credentials.password ?? ""
        gatewayPassword = selectedHost?.credentials.gatewayPassword ?? ""
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
        username = selectedHost.map {
            personalSettingsStore.settings(for: $0, endpoint: endpoint).preferredUsername
        } ?? ""
        password = selectedHost?.credentials.password ?? ""
        gatewayPassword = selectedHost?.credentials.gatewayPassword ?? ""
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
