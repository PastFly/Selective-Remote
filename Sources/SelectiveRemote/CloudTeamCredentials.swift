import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

struct SelectiveRemoteTeamCredential: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordID: UUID
    let teamID: UUID
    let teamName: String
    let role: SelectiveRemoteCloudTeamRole
    let vaultID: UUID
    let vaultName: String
    let revision: Int
    let keyGeneration: Int
    let modifiedDate: Date
    let title: String
    let username: String
    let secret: String
    let folder: String
    let tags: [String]
    let sourceHostID: UUID?
    let sourceHostTitle: String?
    let kind: KeychainCredentialKind?
}

enum SelectiveRemoteTeamCredentialMaterializationError: Error, Equatable {
    case invalidSnapshot
    case invalidCredentialRecord
}

enum SelectiveRemoteTeamCredentialMaterializer {
    private static let credentialKeys = Set(["title", "username", "secret"])
    private static let organizedCredentialKeys = Set([
        "title", "username", "secret", "folder", "tags"
    ])
    private static let hostCredentialKeys = Set([
        "title", "username", "secret", "kind", "sourceID"
    ])

    static func materialize(
        _ snapshot: SelectiveRemoteTeamVaultMaterializedSnapshot
    ) throws -> [SelectiveRemoteTeamCredential] {
        guard snapshot.teamID.isSelectiveRemoteCloudUUID,
              snapshot.vaultID.isSelectiveRemoteCloudUUID,
              snapshot.revision > 0,
              snapshot.keyGeneration > 0,
              validName(snapshot.teamName),
              validName(snapshot.vaultName)
        else { throw SelectiveRemoteTeamCredentialMaterializationError.invalidSnapshot }

        let document: SelectiveRemoteVaultDocument
        do {
            document = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
        } catch {
            throw SelectiveRemoteTeamCredentialMaterializationError.invalidSnapshot
        }

        let hosts = (try? SelectiveRemoteTeamHostMaterializer.materialize(snapshot)) ?? []
        let hostMetadata = Dictionary(uniqueKeysWithValues: hosts.map {
            ($0.recordID, (title: $0.profile.friendlyName, folder: $0.profile.group, tags: $0.profile.tags))
        })

        return try document.records.compactMap { record in
            guard record.type == .credential else { return nil }
            guard case let .object(data) = record.data else {
                throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
            }
            guard let keys = SelectiveRemoteVaultBrowserMetadata.coreKeys(data) else {
                throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
            }
            let sourceHostID: UUID?
            let sourceHostTitle: String?
            let kind: KeychainCredentialKind?
            let folder: String
            let tags: [String]
            if keys == hostCredentialKeys {
                guard let sourceText = string(data["sourceID"]),
                      let resolvedSourceID = UUID(uuidString: sourceText),
                      resolvedSourceID.isSelectiveRemoteCloudUUID,
                      let resolvedHost = hostMetadata[resolvedSourceID],
                      let kindText = string(data["kind"]),
                      let resolvedKind = KeychainCredentialKind(rawValue: kindText),
                      resolvedKind == .rdp || resolvedKind == .ssh || resolvedKind == .gateway
                else {
                    throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
                }
                sourceHostID = resolvedSourceID
                sourceHostTitle = resolvedHost.title
                kind = resolvedKind
                folder = resolvedHost.folder
                tags = resolvedHost.tags
            } else if keys == credentialKeys || keys == organizedCredentialKeys {
                sourceHostID = nil
                sourceHostTitle = nil
                kind = nil
                if keys == organizedCredentialKeys {
                    guard let resolvedFolder = string(data["folder"]),
                          validFolder(resolvedFolder),
                          let resolvedTags = strings(data["tags"]),
                          resolvedTags.count <= 32,
                          resolvedTags.allSatisfy({ validTag($0) }),
                          Set(resolvedTags).count == resolvedTags.count
                    else {
                        throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
                    }
                    folder = resolvedFolder
                    tags = resolvedTags
                } else {
                    folder = ""
                    tags = []
                }
            } else {
                throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
            }
            guard
                  let title = string(data["title"]),
                  let username = string(data["username"]),
                  let secret = string(data["secret"]),
                  validName(title),
                  validUsername(username),
                  validSecret(secret),
                  let modifiedDate = timestamp(record.modifiedAt)
            else {
                throw SelectiveRemoteTeamCredentialMaterializationError.invalidCredentialRecord
            }
            return .init(
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
                modifiedDate: modifiedDate,
                title: title,
                username: username,
                secret: secret,
                folder: folder,
                tags: tags,
                sourceHostID: sourceHostID,
                sourceHostTitle: sourceHostTitle,
                kind: kind
            )
        }
    }

    static func scopedID(teamID: UUID, vaultID: UUID, recordID: UUID) -> UUID {
        let scope = [
            "selective-remote/team-credential/v1",
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

    private static func string(_ value: SelectiveRemoteJSONValue?) -> String? {
        guard case let .string(result) = value else { return nil }
        return result
    }

    private static func strings(_ value: SelectiveRemoteJSONValue?) -> [String]? {
        guard case let .array(values) = value else { return nil }
        return values.reduce(into: [String]?([])) { result, value in
            guard let string = string(value) else { result = nil; return }
            result?.append(string)
        }
    }

    private static func validName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && !value.isEmpty && value.count <= 120
            && !value.contains(where: { $0.isNewline })
    }

    private static func validUsername(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 2_048
            && !value.contains(where: { $0.isNewline })
    }

    private static func validFolder(_ value: String) -> Bool {
        value.isEmpty || (value == SelectiveRemoteHostFolderPath.normalize(value)
            && value.count <= 240
            && value.split(separator: "/").allSatisfy { validName(String($0)) })
    }

    private static func validTag(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value == trimmed && value.count <= 64
            && !value.contains(where: { $0.isNewline })
    }

    private static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32_768
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    && $0.value != 9
                    && $0.value != 10
                    && $0.value != 13
            })
    }

    private static func timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum SelectiveRemoteTeamCredentialMutationError: LocalizedError, Equatable {
    case readOnlyRole
    case credentialNotFound
    case hostLinkedCredential
    case invalidOrganization
    case syncConflict

    var errorDescription: String? {
        switch self {
        case .readOnlyRole:
            UpdateLocalization.text(
                ru: "Роль Viewer может только просматривать Team Credentials.",
                en: "The Viewer role can only view Team Credentials."
            )
        case .credentialNotFound:
            UpdateLocalization.text(
                ru: "Team Credential больше не существует.",
                en: "The Team Credential no longer exists."
            )
        case .hostLinkedCredential:
            UpdateLocalization.text(
                ru: "Папка этой записи наследуется от Team Host. Переместите сам Host.",
                en: "This record inherits its folder from the Team Host. Move the Host instead."
            )
        case .invalidOrganization:
            UpdateLocalization.text(
                ru: "Проверьте папку и теги. Допустимо до 32 уникальных тегов.",
                en: "Check the folder and tags. Up to 32 unique tags are allowed."
            )
        case .syncConflict:
            UpdateLocalization.text(
                ru: "Team Vault изменился параллельно. Синхронизируйте Vault и повторите.",
                en: "The Team Vault changed concurrently. Synchronize it and try again."
            )
        }
    }
}

enum SelectiveRemoteTeamCredentialDocumentMutation {
    static func isWritable(role: SelectiveRemoteCloudTeamRole) -> Bool {
        role == .owner || role == .admin || role == .editor
    }

    static func organize(
        in document: SelectiveRemoteVaultDocument,
        recordID: UUID,
        folder rawFolder: String,
        tags rawTags: [String],
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        guard isWritable(role: role) else {
            throw SelectiveRemoteTeamCredentialMutationError.readOnlyRole
        }
        guard let existing = document.records.first(where: { $0.id == recordID }) else {
            throw SelectiveRemoteTeamCredentialMutationError.credentialNotFound
        }
        guard existing.type == .credential, case let .object(data) = existing.data else {
            throw SelectiveRemoteTeamCredentialMutationError.credentialNotFound
        }
        guard data["sourceID"] == nil else {
            throw SelectiveRemoteTeamCredentialMutationError.hostLinkedCredential
        }
        let allowedKeys = Set(["title", "username", "secret", "folder", "tags"])
        guard SelectiveRemoteVaultBrowserMetadata.coreKeys(data)?.isSubset(of: allowedKeys) == true,
              case let .string(title)? = data["title"],
              case let .string(username)? = data["username"],
              case let .string(secret)? = data["secret"]
        else { throw SelectiveRemoteTeamCredentialMutationError.invalidOrganization }

        let folder = SelectiveRemoteHostFolderPath.normalize(rawFolder)
        let tags = normalizedTags(rawTags)
        guard validFolder(folder), tags.count <= 32, tags.allSatisfy({ validTag($0) }) else {
            throw SelectiveRemoteTeamCredentialMutationError.invalidOrganization
        }
        let record = try SelectiveRemoteVaultRecord(
            id: existing.id,
            type: .credential,
            version: try existing.version.incrementing(deviceID),
            modifiedAt: modifiedAt,
            data: SelectiveRemoteVaultBrowserMetadata.preservingFavorite(in: .object([
                "title": .string(title),
                "username": .string(username),
                "secret": .string(secret),
                "folder": .string(folder),
                "tags": .array(tags.map { .string($0) })
            ]), from: existing)
        )
        return try .init(
            records: document.records.map { $0.id == recordID ? record : $0 },
            tombstones: document.tombstones
        )
    }

    private static func normalizedTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized.localizedLowercase
            guard !normalized.isEmpty, seen.insert(key).inserted else { return nil }
            return normalized
        }
    }

    private static func validFolder(_ value: String) -> Bool {
        value.isEmpty || (value.count <= 240
            && value.split(separator: "/").allSatisfy { validName(String($0)) })
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 120 && !value.contains(where: { $0.isNewline })
    }

    private static func validTag(_ value: String) -> Bool {
        value.count <= 64 && !value.contains(where: { $0.isNewline })
    }
}

@MainActor
final class SelectiveRemoteTeamCredentialMutationService {
    private let remote: any SelectiveRemoteTeamVaultRemote
    private let snapshots: any SelectiveRemoteTeamVaultSnapshotStore

    init(
        remote: any SelectiveRemoteTeamVaultRemote = SelectiveRemoteCloudAPIClient(),
        snapshots: any SelectiveRemoteTeamVaultSnapshotStore
    ) {
        self.remote = remote
        self.snapshots = snapshots
    }

    convenience init() throws {
        try self.init(snapshots: SelectiveRemoteTeamVaultFileSnapshotStore())
    }

    func organize(
        _ credential: SelectiveRemoteTeamCredential,
        folder: String,
        tags: [String],
        endpoint: URL,
        identity: SelectiveRemoteTeamDeviceIdentity,
        now: Date = Date()
    ) async throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: snapshots
        )
        let refreshed = try await coordinator.refresh(
            teamID: credential.teamID,
            vaultID: credential.vaultID,
            identity: identity
        )
        let snapshot: SelectiveRemoteTeamVaultDecryptedSnapshot
        switch refreshed {
        case let .synchronized(value), let .localChanges(value):
            snapshot = value
        case .empty:
            throw SelectiveRemoteTeamCredentialMutationError.credentialNotFound
        case .conflict:
            throw SelectiveRemoteTeamCredentialMutationError.syncConflict
        }
        let current = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
        let document = try SelectiveRemoteTeamCredentialDocumentMutation.organize(
            in: current,
            recordID: credential.recordID,
            folder: folder,
            tags: tags,
            role: credential.role,
            deviceID: identity.deviceID,
            modifiedAt: Self.timestamp(now)
        )
        _ = try await coordinator.stage(
            document.encoded(),
            teamID: credential.teamID,
            vaultID: credential.vaultID,
            identity: identity
        )
        guard case let .uploaded(uploaded) = try await coordinator.push(
            teamID: credential.teamID,
            vaultID: credential.vaultID,
            identity: identity
        ) else {
            throw SelectiveRemoteTeamCredentialMutationError.syncConflict
        }
        return .init(
            teamID: credential.teamID,
            teamName: credential.teamName,
            role: credential.role,
            vaultID: credential.vaultID,
            vaultName: credential.vaultName,
            revision: uploaded.snapshot.serverRevision,
            keyGeneration: uploaded.snapshot.keyGeneration,
            payload: uploaded.payload
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

@MainActor
final class SelectiveRemoteTeamCredentialStore: ObservableObject {
    static let shared = SelectiveRemoteTeamCredentialStore()

    @Published private(set) var credentials: [SelectiveRemoteTeamCredential] = []
    @Published private(set) var synchronizedVaultCount = 0
    @Published private(set) var invalidVaultCount = 0
    @Published private(set) var lastUpdatedAt: Date?

    private var snapshots: [String: SelectiveRemoteTeamVaultMaterializedSnapshot] = [:]

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
        credentials = []
        synchronizedVaultCount = 0
        invalidVaultCount = 0
        lastUpdatedAt = nil
    }

    private func rebuild(now: Date) {
        var next: [SelectiveRemoteTeamCredential] = []
        var invalid = 0
        for snapshot in snapshots.values {
            do {
                next += try SelectiveRemoteTeamCredentialMaterializer.materialize(snapshot)
            } catch {
                invalid += 1
            }
        }
        credentials = next.sorted {
            let left = [$0.teamName, $0.vaultName, $0.title].map(\.localizedLowercase)
            let right = [$1.teamName, $1.vaultName, $1.title].map(\.localizedLowercase)
            return left == right
                ? $0.recordID.canonicalCloudString < $1.recordID.canonicalCloudString
                : left.lexicographicallyPrecedes(right)
        }
        synchronizedVaultCount = snapshots.count - invalid
        invalidVaultCount = invalid
        lastUpdatedAt = snapshots.isEmpty ? nil : now
    }

    private func scopeKey(teamID: UUID, vaultID: UUID) -> String {
        "\(teamID.canonicalCloudString)/\(vaultID.canonicalCloudString)"
    }
}

private enum SelectiveRemoteTeamCredentialKindFilter: String, CaseIterable, Identifiable {
    case all, standalone, ssh, rdp, gateway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: UpdateLocalization.text(ru: "Все типы", en: "All Types")
        case .standalone: UpdateLocalization.text(ru: "Самостоятельные", en: "Standalone")
        case .ssh: "SSH"
        case .rdp: "RDP"
        case .gateway: UpdateLocalization.text(ru: "Шлюз", en: "Gateway")
        }
    }
}

private enum SelectiveRemoteTeamCredentialSortMode: String, CaseIterable, Identifiable {
    case title, recent, host

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: UpdateLocalization.text(ru: "Название: А–Я", en: "Title: A–Z")
        case .recent: UpdateLocalization.text(ru: "Сначала новые", en: "Newest First")
        case .host: UpdateLocalization.text(ru: "По Host", en: "By Host")
        }
    }
}

private struct SelectiveRemoteTeamCredentialFolderGroup: Identifiable {
    let id: String
    let folder: String
    let credentials: [SelectiveRemoteTeamCredential]
}

private struct SelectiveRemoteTeamCredentialVaultGroup: Identifiable {
    let id: String
    let title: String
    let folders: [SelectiveRemoteTeamCredentialFolderGroup]
    let count: Int
}

@MainActor
struct SelectiveRemoteTeamCredentialsView: View {
    @ObservedObject var store: SelectiveRemoteTeamCredentialStore

    @State private var query = ""
    @State private var selectedCredentialID: UUID?
    @State private var selectedVaultKey = ""
    @AppStorage("SelectiveRemote.team-credential.kind-filter.v1")
    private var kindFilter = SelectiveRemoteTeamCredentialKindFilter.all
    @AppStorage("SelectiveRemote.team-credential.sort-mode.v1")
    private var sortMode = SelectiveRemoteTeamCredentialSortMode.title
    @State private var expandedVaultKeys = Set<String>()
    @State private var expandedFolderKeys = Set<String>()
    @AppStorage("SelectiveRemote.team-credential.expanded-vaults.v1")
    private var expandedVaultKeysStorage = ""
    @AppStorage("SelectiveRemote.team-credential.expanded-folders.v1")
    private var expandedFolderKeysStorage = ""
    @AppStorage("SelectiveRemote.team-credential.expansion-initialized.v1")
    private var expansionInitialized = false
    @State private var revealedCredentialIDs: Set<UUID> = []
    @State private var revealTasks: [UUID: Task<Void, Never>] = [:]
    @State private var feedback = ""
    @State private var organizationEditorCredential: SelectiveRemoteTeamCredential?
    @State private var isOrganizing = false
    @AppStorage("SelectiveRemote.cloud.endpoint.v1")
    private var endpoint = SelectiveRemoteCloudEndpoint.production
    @AppStorage("SelectiveRemote.cloud.device-id.v1")
    private var storedDeviceID = ""

    private let identityManager = SelectiveRemoteTeamDeviceIdentityManager()

    private var visibleCredentials: [SelectiveRemoteTeamCredential] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.credentials.filter { credential in
            (selectedVaultKey.isEmpty || vaultKey(credential) == selectedVaultKey)
                && kindMatches(credential)
                && (normalized.isEmpty || [
                    credential.title, credential.username,
                    credential.teamName, credential.vaultName,
                    credential.sourceHostTitle ?? "", credentialKindTitle(credential.kind),
                    credential.folder, credential.tags.joined(separator: " ")
                ].contains { $0.localizedCaseInsensitiveContains(normalized) })
        }
    }

    private var groupedCredentials: [SelectiveRemoteTeamCredentialVaultGroup] {
        Dictionary(grouping: visibleCredentials) { credential in
            vaultKey(credential)
        }
            .compactMap { key, values in
                guard let first = values.first else { return nil }
                let folders = Dictionary(grouping: values) { normalizedFolder($0.folder) }
                    .map { folder, credentials in
                        SelectiveRemoteTeamCredentialFolderGroup(
                            id: "\(key)/\(folder)",
                            folder: folder,
                            credentials: sorted(credentials)
                        )
                    }
                    .sorted { folderTitle($0.folder).localizedStandardCompare(folderTitle($1.folder)) == .orderedAscending }
                return .init(
                    id: key,
                    title: "\(first.teamName) / \(first.vaultName)",
                    folders: folders,
                    count: values.count
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var selectedCredential: SelectiveRemoteTeamCredential? {
        visibleCredentials.first { $0.id == selectedCredentialID }
    }

    var body: some View {
        GeometryReader { proxy in
            HSplitView {
                VStack(spacing: 0) {
                    controls
                    Divider()
                    if store.credentials.isEmpty {
                        ContentUnavailableView(
                            UpdateLocalization.text(
                                ru: "Team Credentials пока не синхронизированы",
                                en: "Team Credentials Have Not Synchronized Yet"
                            ),
                            systemImage: "key.viewfinder",
                            description: Text(UpdateLocalization.text(
                                ru: "Разблокируйте приложение и дождитесь безопасной синхронизации Team Vault.",
                                en: "Unlock the app and wait for secure Team Vault synchronization."
                            ))
                        )
                    } else if visibleCredentials.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List(selection: $selectedCredentialID) {
                            ForEach(groupedCredentials) { vault in
                                DisclosureGroup(isExpanded: expansionBinding(forVault: vault.id)) {
                                    ForEach(vault.folders) { folder in
                                        DisclosureGroup(isExpanded: expansionBinding(forFolder: folder.id)) {
                                            ForEach(folder.credentials) { credential in
                                                credentialRow(credential)
                                                    .tag(credential.id)
                                                    .listRowBackground(Color.clear)
                                                    .listRowSeparator(.hidden)
                                                    .contextMenu { credentialActions(credential) }
                                            }
                                        } label: {
                                            groupLabel(folderTitle(folder.folder), count: folder.credentials.count, icon: "folder")
                                        }
                                    }
                                } label: {
                                    groupLabel(vault.title, count: vault.count, icon: "tray.full")
                                }
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                    Divider()
                    status
                }
                .frame(minWidth: 340, idealWidth: max(400, proxy.size.width * 0.42))

                Group {
                    if let selectedCredential {
                        inspector(selectedCredential)
                    } else {
                        ContentUnavailableView(
                            UpdateLocalization.text(
                                ru: "Выберите Team Credential",
                                en: "Select a Team Credential"
                            ),
                            systemImage: "key.viewfinder"
                        )
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { restoreOrInitializeExpansion(); normalizeSelection() }
        .onChange(of: store.credentials.map(\.id)) { _, _ in restoreOrInitializeExpansion(); normalizeSelection() }
        .onChange(of: selectedVaultKey) { _, _ in restoreOrInitializeExpansion(); normalizeSelection() }
        .onChange(of: kindFilter) { _, _ in restoreOrInitializeExpansion(); normalizeSelection() }
        .onChange(of: expandedVaultKeys) { _, value in
            expandedVaultKeysStorage = value.sorted().joined(separator: "\n")
        }
        .onChange(of: expandedFolderKeys) { _, value in
            expandedFolderKeysStorage = value.sorted().joined(separator: "\n")
        }
        .onChange(of: selectedCredentialID) { _, _ in feedback = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            concealAll()
        }
        .onDisappear { concealAll() }
        .sheet(item: $organizationEditorCredential) { credential in
            SelectiveRemoteTeamCredentialOrganizationEditor(credential: credential) { folder, tags in
                organize(credential, folder: folder, tags: tags)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(
                    UpdateLocalization.text(
                        ru: "Название, логин, имя команды или Vault",
                        en: "Title, username, Team, or Vault"
                    ),
                    text: $query
                )
                .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Menu {
                    Button(UpdateLocalization.text(ru: "Все Team Vaults", en: "All Team Vaults")) {
                        selectedVaultKey = ""
                    }
                    Divider()
                    ForEach(vaultOptions, id: \.key) { option in
                        Button(option.title) { selectedVaultKey = option.key }
                    }
                } label: {
                    Label(selectedVaultTitle, systemImage: "tray.full")
                }
                .menuStyle(.borderlessButton)
                Menu {
                    Picker(UpdateLocalization.text(ru: "Тип", en: "Type"), selection: $kindFilter) {
                        ForEach(SelectiveRemoteTeamCredentialKindFilter.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    Divider()
                    Picker(UpdateLocalization.text(ru: "Сортировка", en: "Sort"), selection: $sortMode) {
                        ForEach(SelectiveRemoteTeamCredentialSortMode.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                } label: {
                    Label(kindFilter.title, systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Text("\(visibleCredentials.count) \(UpdateLocalization.text(ru: "из", en: "of")) \(store.credentials.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(SelectiveRemoteWorkspaceChrome.accent.opacity(0.025))
    }

    private func credentialRow(_ credential: SelectiveRemoteTeamCredential) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(credential.title).font(.headline).lineLimit(1)
                Spacer()
                Text(roleTitle(credential.role))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("\(credential.teamName) / \(credential.vaultName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(credential.username)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            if !credential.tags.isEmpty {
                Label(credential.tags.joined(separator: ", "), systemImage: "tag")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let sourceHostTitle = credential.sourceHostTitle {
                Label(
                    "\(UpdateLocalization.text(ru: "Хост", en: "Host")): \(sourceHostTitle) · \(credentialKindTitle(credential.kind))",
                    systemImage: "display"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func inspector(_ credential: SelectiveRemoteTeamCredential) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "key.viewfinder")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SelectiveRemoteWorkspaceChrome.accentStrong)
                    .frame(width: 42, height: 42)
                    .background(
                        SelectiveRemoteWorkspaceChrome.accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 11)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(credential.title).font(.title2.bold())
                    Text("\(credential.teamName) / \(credential.vaultName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copy(credential.secret, message: UpdateLocalization.text(
                        ru: "Пароль скопирован",
                        en: "Password copied"
                    ))
                } label: {
                    Label(UpdateLocalization.text(ru: "Копировать пароль", en: "Copy Password"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                if credential.sourceHostID == nil,
                   SelectiveRemoteTeamCredentialDocumentMutation.isWritable(role: credential.role) {
                    Button {
                        organizationEditorCredential = credential
                    } label: {
                        Label(
                            UpdateLocalization.text(ru: "Организовать", en: "Organize"),
                            systemImage: "folder.badge.gearshape"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isOrganizing)
                }
            }

            HStack(spacing: 18) {
                Label(roleTitle(credential.role), systemImage: "person.badge.shield.checkmark")
                if let sourceHostTitle = credential.sourceHostTitle {
                    Label(
                        "\(UpdateLocalization.text(ru: "Хост", en: "Host")): \(sourceHostTitle) · \(credentialKindTitle(credential.kind))",
                        systemImage: "display"
                    )
                }
                Label(
                    "r\(credential.revision) · k\(credential.keyGeneration)",
                    systemImage: "lock.shield"
                )
                Label(UpdateLocalization.dateTimeShort(credential.modifiedDate), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GroupBox(UpdateLocalization.text(ru: "Организация", en: "Organization")) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(folderTitle(credential.folder), systemImage: "folder")
                    Label(
                        credential.tags.isEmpty
                            ? UpdateLocalization.text(ru: "Без тегов", en: "No Tags")
                            : credential.tags.joined(separator: ", "),
                        systemImage: "tag"
                    )
                    if credential.sourceHostID != nil {
                        Text(UpdateLocalization.text(
                            ru: "Папка и теги наследуются от связанного Team Host.",
                            en: "Folder and tags are inherited from the linked Team Host."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox(UpdateLocalization.text(ru: "Имя пользователя", en: "Username")) {
                HStack {
                    Text(credential.username).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button(UpdateLocalization.text(ru: "Копировать", en: "Copy"), systemImage: "doc.on.doc") {
                        copy(credential.username, message: UpdateLocalization.text(
                            ru: "Имя пользователя скопировано",
                            en: "Username copied"
                        ))
                    }
                }
                .padding(8)
            }

            GroupBox(UpdateLocalization.text(ru: "Пароль", en: "Password")) {
                HStack {
                    if revealedCredentialIDs.contains(credential.id) {
                        Text(credential.secret)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                    } else {
                        Text(maskedSecret(credential))
                            .font(.body.monospaced())
                    }
                    Spacer()
                    Button {
                        toggleReveal(credential.id)
                    } label: {
                        Label(
                            revealedCredentialIDs.contains(credential.id)
                                ? UpdateLocalization.text(ru: "Скрыть", en: "Hide")
                                : UpdateLocalization.text(ru: "Показать", en: "Reveal"),
                            systemImage: revealedCredentialIDs.contains(credential.id) ? "eye.slash" : "eye"
                        )
                    }
                }
                .padding(8)
            }

            if !feedback.isEmpty {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()
            Label(
                UpdateLocalization.text(
                    ru: "Секрет находится только в памяти после расшифровки Team Vault и открывается или копируется только по вашему действию.",
                    en: "The secret exists only in memory after Team Vault decryption and is revealed or copied only by your action."
                ),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    @ViewBuilder
    private func credentialActions(_ credential: SelectiveRemoteTeamCredential) -> some View {
        Button(UpdateLocalization.text(ru: "Копировать логин", en: "Copy Username"), systemImage: "person.crop.circle") {
            copy(credential.username, message: UpdateLocalization.text(
                ru: "Имя пользователя скопировано",
                en: "Username copied"
            ))
        }
        Button(UpdateLocalization.text(ru: "Копировать пароль", en: "Copy Password"), systemImage: "doc.on.doc") {
            copy(credential.secret, message: UpdateLocalization.text(
                ru: "Пароль скопирован",
                en: "Password copied"
            ))
        }
        Divider()
        Button(
            revealedCredentialIDs.contains(credential.id)
                ? UpdateLocalization.text(ru: "Скрыть пароль", en: "Hide Password")
                : UpdateLocalization.text(ru: "Показать пароль", en: "Reveal Password"),
            systemImage: revealedCredentialIDs.contains(credential.id) ? "eye.slash" : "eye"
        ) {
            toggleReveal(credential.id)
        }
        if credential.sourceHostID == nil,
           SelectiveRemoteTeamCredentialDocumentMutation.isWritable(role: credential.role) {
            Divider()
            Button(
                UpdateLocalization.text(ru: "Изменить папку и теги…", en: "Edit Folder and Tags…"),
                systemImage: "folder.badge.gearshape"
            ) {
                organizationEditorCredential = credential
            }
            .disabled(isOrganizing)
        }
    }

    private var vaultOptions: [(key: String, title: String)] {
        Dictionary(grouping: store.credentials, by: { vaultKey($0) })
            .compactMap { _, values in
                guard let value = values.first else { return nil }
                return (vaultKey(value), "\(value.teamName) / \(value.vaultName)")
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var selectedVaultTitle: String {
        vaultOptions.first { $0.key == selectedVaultKey }?.title
            ?? UpdateLocalization.text(ru: "Все Team Vaults", en: "All Team Vaults")
    }

    private func vaultKey(_ credential: SelectiveRemoteTeamCredential) -> String {
        "\(credential.teamID.canonicalCloudString)/\(credential.vaultID.canonicalCloudString)"
    }

    private func normalizedFolder(_ value: String) -> String {
        SelectiveRemoteHostFolderPath.normalize(value)
    }

    private func folderTitle(_ value: String) -> String {
        let normalized = normalizedFolder(value)
        return normalized.isEmpty ? UpdateLocalization.text(ru: "Без папки", en: "No Folder") : normalized
    }

    private func kindMatches(_ credential: SelectiveRemoteTeamCredential) -> Bool {
        switch kindFilter {
        case .all: true
        case .standalone: credential.kind == nil
        case .ssh: credential.kind == .ssh
        case .rdp: credential.kind == .rdp
        case .gateway: credential.kind == .gateway
        }
    }

    private func sorted(_ credentials: [SelectiveRemoteTeamCredential]) -> [SelectiveRemoteTeamCredential] {
        credentials.sorted { left, right in
            switch sortMode {
            case .title:
                left.title.localizedStandardCompare(right.title) == .orderedAscending
            case .recent:
                left.modifiedDate == right.modifiedDate
                    ? left.title.localizedStandardCompare(right.title) == .orderedAscending
                    : left.modifiedDate > right.modifiedDate
            case .host:
                (left.sourceHostTitle ?? left.title).localizedStandardCompare(
                    right.sourceHostTitle ?? right.title
                ) == .orderedAscending
            }
        }
    }

    private func groupLabel(_ title: String, count: Int, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.headline)
            Spacer()
            Text("\(count)").font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func expansionBinding(forVault key: String) -> Binding<Bool> {
        Binding(
            get: { expandedVaultKeys.contains(key) },
            set: { value in
                if value { expandedVaultKeys.insert(key) } else { expandedVaultKeys.remove(key) }
            }
        )
    }

    private func expansionBinding(forFolder key: String) -> Binding<Bool> {
        Binding(
            get: { expandedFolderKeys.contains(key) },
            set: { value in
                if value { expandedFolderKeys.insert(key) } else { expandedFolderKeys.remove(key) }
            }
        )
    }

    private func restoreOrInitializeExpansion() {
        let validVaults = Set(groupedCredentials.map(\.id))
        let validFolders = Set(groupedCredentials.flatMap { $0.folders.map(\.id) })
        if expansionInitialized {
            expandedVaultKeys = Set(expandedVaultKeysStorage.split(separator: "\n").map(String.init))
            expandedFolderKeys = Set(expandedFolderKeysStorage.split(separator: "\n").map(String.init))
        } else {
            expandedVaultKeys = validVaults
            expandedFolderKeys = validFolders
            expansionInitialized = true
        }
        expandedVaultKeys.formIntersection(validVaults)
        expandedFolderKeys.formIntersection(validFolders)
    }

    private func normalizeSelection() {
        if !selectedVaultKey.isEmpty && !vaultOptions.contains(where: { $0.key == selectedVaultKey }) {
            selectedVaultKey = ""
        }
        if selectedCredential == nil { selectedCredentialID = visibleCredentials.first?.id }
    }

    private func organize(
        _ credential: SelectiveRemoteTeamCredential,
        folder: String,
        tags: [String]
    ) {
        guard !isOrganizing else { return }
        isOrganizing = true
        Task { @MainActor in
            defer { isOrganizing = false }
            do {
                let url = try SelectiveRemoteCloudEndpoint.normalized(endpoint)
                let identity = try await identityManager.identity(
                    endpoint: url,
                    deviceID: resolvedDeviceID()
                )
                let service = try SelectiveRemoteTeamCredentialMutationService()
                let snapshot = try await service.organize(
                    credential,
                    folder: folder,
                    tags: tags,
                    endpoint: url,
                    identity: identity
                )
                store.replaceVault(with: snapshot)
                selectedCredentialID = SelectiveRemoteTeamCredentialMaterializer.scopedID(
                    teamID: credential.teamID,
                    vaultID: credential.vaultID,
                    recordID: credential.recordID
                )
                feedback = UpdateLocalization.text(
                    ru: "Папка и теги синхронизированы",
                    en: "Folder and tags synchronized"
                )
            } catch {
                feedback = error.localizedDescription
            }
        }
    }

    private func resolvedDeviceID() -> UUID {
        if let value = UUID(uuidString: storedDeviceID), value.isSelectiveRemoteCloudUUID {
            return value
        }
        let value = UUID()
        storedDeviceID = value.canonicalCloudString
        return value
    }

    private func toggleReveal(_ id: UUID) {
        if revealedCredentialIDs.contains(id) {
            conceal(id)
        } else {
            revealedCredentialIDs.insert(id)
            revealTasks[id]?.cancel()
            revealTasks[id] = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: CredentialDisclosurePolicy.visibleNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                conceal(id)
            }
        }
    }

    private func conceal(_ id: UUID) {
        revealTasks[id]?.cancel()
        revealTasks[id] = nil
        revealedCredentialIDs.remove(id)
    }

    private func concealAll() {
        for task in revealTasks.values { task.cancel() }
        revealTasks.removeAll()
        revealedCredentialIDs.removeAll()
    }

    private func maskedSecret(_ credential: SelectiveRemoteTeamCredential) -> String {
        guard !revealedCredentialIDs.contains(credential.id) else { return credential.secret }
        return String(repeating: "•", count: min(max(credential.secret.count, 8), 24))
    }

    private func copy(_ value: String, message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { return }
        feedback = message
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: CredentialDisclosurePolicy.clipboardNanoseconds
            )
            if NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
        }
    }

    private func roleTitle(_ role: SelectiveRemoteCloudTeamRole) -> String {
        role.displayRoleTitle()
    }

    private func credentialKindTitle(_ kind: KeychainCredentialKind?) -> String {
        switch kind {
        case .rdp: "RDP"
        case .gateway: UpdateLocalization.text(ru: "Шлюз", en: "Gateway")
        case .ssh: "SSH"
        case .forwarding: "Forwarding"
        case .proxy: "Proxy"
        case .sshKeyAuthorization: "SSH Key"
        case nil: UpdateLocalization.text(ru: "Самостоятельная", en: "Standalone")
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if let lastUpdatedAt = store.lastUpdatedAt {
                Label(lastUpdatedAt.formatted(date: .omitted, time: .shortened), systemImage: "arrow.triangle.2.circlepath")
            }
            Text(UpdateLocalization.text(
                ru: "Team Vaults: \(store.synchronizedVaultCount)",
                en: "Team Vaults: \(store.synchronizedVaultCount)"
            ))
            if store.invalidVaultCount > 0 {
                Label("\(store.invalidVaultCount)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(UpdateLocalization.text(ru: "Только в памяти", en: "Memory only"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    }
}

private struct SelectiveRemoteTeamCredentialOrganizationEditor: View {
    @Environment(\.dismiss) private var dismiss

    let credential: SelectiveRemoteTeamCredential
    let onSave: (String, [String]) -> Void

    @State private var folder: String
    @State private var tags: String

    init(
        credential: SelectiveRemoteTeamCredential,
        onSave: @escaping (String, [String]) -> Void
    ) {
        self.credential = credential
        self.onSave = onSave
        _folder = State(initialValue: credential.folder)
        _tags = State(initialValue: credential.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(UpdateLocalization.text(ru: "Организация Credential", en: "Organize Credential"))
                        .font(.title2.bold())
                    Text("\(credential.teamName) / \(credential.vaultName) · \(credential.title)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                TextField(
                    UpdateLocalization.text(ru: "Папка", en: "Folder"),
                    text: $folder,
                    prompt: Text("Production/SSH")
                )
                TextField(
                    UpdateLocalization.text(ru: "Теги через запятую", en: "Comma-separated tags"),
                    text: $tags,
                    prompt: Text("linux, production")
                )
            }
            .formStyle(.grouped)

            Text(UpdateLocalization.text(
                ru: "Папка и теги сохраняются внутри зашифрованной Team Vault записи. Права наследуются от роли Team.",
                en: "Folder and tags stay inside the encrypted Team Vault record. Permissions inherit from the Team role."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) { dismiss() }
                Button(UpdateLocalization.text(ru: "Сохранить", en: "Save")) {
                    let values = tags.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
                    onSave(folder, values)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
