import CryptoKit
import Foundation

enum SelectiveRemoteTeamHostMutationError: LocalizedError, Equatable {
    case readOnlyRole
    case duplicateHost
    case hostNotFound
    case recordIsNotHost
    case syncConflict

    var errorDescription: String? {
        switch self {
        case .readOnlyRole:
            UpdateLocalization.text(
                ru: "Роль Viewer может только просматривать Team Hosts.",
                en: "The Viewer role can only view Team Hosts."
            )
        case .duplicateHost:
            UpdateLocalization.text(ru: "Team Host с таким ID уже существует.", en: "A Team Host with this ID already exists.")
        case .hostNotFound:
            UpdateLocalization.text(ru: "Team Host больше не существует.", en: "The Team Host no longer exists.")
        case .recordIsNotHost:
            UpdateLocalization.text(ru: "Выбранная запись не является Team Host.", en: "The selected record is not a Team Host.")
        case .syncConflict:
            UpdateLocalization.text(
                ru: "Team Vault изменился параллельно. Локальная версия сохранена; синхронизируйте Vault и повторите.",
                en: "The Team Vault changed concurrently. The local version was preserved; synchronize the Vault and try again."
            )
        }
    }
}

enum SelectiveRemoteTeamHostDocumentMutation {
    static func isWritable(role: SelectiveRemoteCloudTeamRole) -> Bool {
        role == .owner || role == .admin || role == .editor
    }

    static func create(
        profile: ConnectionProfile,
        credentials: SelectiveRemoteTeamHostCredentials = .empty,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try mutate(
            document: .init(),
            profile: profile,
            credentials: credentials,
            recordID: profile.id,
            role: role,
            deviceID: deviceID,
            modifiedAt: modifiedAt,
            requiresExistingHost: false
        )
    }

    static func create(
        in document: SelectiveRemoteVaultDocument,
        profile: ConnectionProfile,
        credentials: SelectiveRemoteTeamHostCredentials = .empty,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        guard document.records.allSatisfy({ $0.id != profile.id }),
              document.tombstones.allSatisfy({ $0.id != profile.id })
        else { throw SelectiveRemoteTeamHostMutationError.duplicateHost }
        return try mutate(
            document: document,
            profile: profile,
            credentials: credentials,
            recordID: profile.id,
            role: role,
            deviceID: deviceID,
            modifiedAt: modifiedAt,
            requiresExistingHost: false
        )
    }

    static func update(
        in document: SelectiveRemoteVaultDocument,
        recordID: UUID,
        profile: ConnectionProfile,
        credentials: SelectiveRemoteTeamHostCredentials = .empty,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try mutate(
            document: document,
            profile: profile,
            credentials: credentials,
            recordID: recordID,
            role: role,
            deviceID: deviceID,
            modifiedAt: modifiedAt,
            requiresExistingHost: true
        )
    }

    static func organize(
        in document: SelectiveRemoteVaultDocument,
        recordID: UUID,
        profile: ConnectionProfile,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try requireWritable(role)
        guard let existing = document.records.first(where: { $0.id == recordID }) else {
            throw SelectiveRemoteTeamHostMutationError.hostNotFound
        }
        guard existing.type == .host else {
            throw SelectiveRemoteTeamHostMutationError.recordIsNotHost
        }
        var exportedProfile = profile
        exportedProfile.id = recordID
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [exportedProfile],
            credentials: [],
            snippets: [],
            forwarding: [],
            deviceID: deviceID
        ).document.records[0]
        let replacement = try SelectiveRemoteVaultRecord(
            id: recordID,
            type: .host,
            version: existing.version.incrementing(deviceID),
            modifiedAt: modifiedAt,
            data: exported.data
        )
        return try .init(
            records: document.records.map { $0.id == recordID ? replacement : $0 },
            tombstones: document.tombstones
        )
    }

    static func delete(
        from document: SelectiveRemoteVaultDocument,
        recordID: UUID,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        deletedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try requireWritable(role)
        guard let existing = document.records.first(where: { $0.id == recordID }) else {
            if document.tombstones.contains(where: { $0.id == recordID }) {
                throw SelectiveRemoteTeamHostMutationError.hostNotFound
            }
            throw SelectiveRemoteTeamHostMutationError.hostNotFound
        }
        guard existing.type == .host else {
            throw SelectiveRemoteTeamHostMutationError.recordIsNotHost
        }
        let removed = document.records.filter { record in
            record.id == recordID || isCredential(record, for: recordID)
        }
        let tombstones = try removed.map { record in
            try SelectiveRemoteVaultTombstone(
                id: record.id,
                version: record.version.incrementing(deviceID),
                deletedAt: deletedAt
            )
        }
        return try .init(
            records: document.records.filter { record in
                !removed.contains(where: { $0.id == record.id })
            },
            tombstones: document.tombstones.filter { tombstone in
                !removed.contains(where: { $0.id == tombstone.id })
            } + tombstones
        )
    }

    private static func mutate(
        document: SelectiveRemoteVaultDocument,
        profile: ConnectionProfile,
        credentials: SelectiveRemoteTeamHostCredentials,
        recordID: UUID,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String,
        requiresExistingHost: Bool
    ) throws -> SelectiveRemoteVaultDocument {
        try requireWritable(role)
        let existing = document.records.first(where: { $0.id == recordID })
        if requiresExistingHost {
            guard let existing else { throw SelectiveRemoteTeamHostMutationError.hostNotFound }
            guard existing.type == .host else {
                throw SelectiveRemoteTeamHostMutationError.recordIsNotHost
            }
        }

        var exportedProfile = profile
        exportedProfile.id = recordID
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [exportedProfile],
            credentials: [],
            snippets: [],
            forwarding: [],
            deviceID: deviceID
        ).document.records[0]
        let priorVersion = existing?.version
            ?? document.tombstones.first(where: { $0.id == recordID })?.version
        let record = try SelectiveRemoteVaultRecord(
            id: recordID,
            type: .host,
            version: try priorVersion?.incrementing(deviceID)
                ?? SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: modifiedAt,
            data: exported.data
        )
        let previous = document.records.filter { isCredential($0, for: recordID) }
        let credentialRecords = try makeCredentials(
            credentials,
            profile: exportedProfile,
            recordID: recordID,
            previous: previous,
            deviceID: deviceID,
            modifiedAt: modifiedAt
        )
        let currentIDs = Set(credentialRecords.map(\.id))
        let credentialTombstones = try previous.filter { !currentIDs.contains($0.id) }.map {
            try SelectiveRemoteVaultTombstone(
                id: $0.id,
                version: $0.version.incrementing(deviceID),
                deletedAt: modifiedAt
            )
        }
        let replacedIDs = Set([recordID] + previous.map(\.id))
        return try .init(
            records: document.records.filter { !replacedIDs.contains($0.id) }
                + [record] + credentialRecords,
            tombstones: document.tombstones.filter {
                $0.id != recordID && !currentIDs.contains($0.id)
            } + credentialTombstones
        )
    }

    private static func makeCredentials(
        _ value: SelectiveRemoteTeamHostCredentials,
        profile: ConnectionProfile,
        recordID: UUID,
        previous: [SelectiveRemoteVaultRecord],
        deviceID: UUID,
        modifiedAt: String
    ) throws -> [SelectiveRemoteVaultRecord] {
        let inputs: [(KeychainCredentialKind, String)] = [
            (profile.connectionType == .ssh ? .ssh : .rdp, value.password ?? ""),
            (.gateway, value.gatewayPassword ?? "")
        ]
        return try inputs.compactMap { kind, secret in
            guard !secret.isEmpty else { return nil }
            let id = credentialID(sourceID: recordID, kind: kind)
            let old = previous.first(where: { $0.id == id })
            return try SelectiveRemoteVaultRecord(
                id: id,
                type: .credential,
                version: try old?.version.incrementing(deviceID)
                    ?? SelectiveRemoteVaultVersion([deviceID: 1]),
                modifiedAt: modifiedAt,
                data: .object([
                    "title": .string("\(profile.friendlyName) · \(kind.rawValue)"),
                    "username": .string(kind == .gateway ? profile.gatewayUsername : profile.username),
                    "secret": .string(secret),
                    "kind": .string(kind.rawValue),
                    "sourceID": .string(recordID.canonicalCloudString)
                ])
            )
        }
    }

    private static func credentialID(sourceID: UUID, kind: KeychainCredentialKind) -> UUID {
        let value = "selective-remote/team-host-credential/v1\u{0}\(sourceID.canonicalCloudString)\u{0}\(kind.rawValue)"
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func isCredential(_ record: SelectiveRemoteVaultRecord, for hostID: UUID) -> Bool {
        guard record.type == .credential, case let .object(data) = record.data,
              case let .string(source)? = data["sourceID"] else { return false }
        return UUID(uuidString: source) == hostID
    }

    private static func requireWritable(_ role: SelectiveRemoteCloudTeamRole) throws {
        guard isWritable(role: role) else {
            throw SelectiveRemoteTeamHostMutationError.readOnlyRole
        }
    }
}


struct SelectiveRemoteTeamHostVaultContext: Identifiable, Equatable {
    let id: UUID
    let teamID: UUID
    let teamName: String
    let role: SelectiveRemoteCloudTeamRole
    let vaultID: UUID
    let vaultName: String
}

enum SelectiveRemoteTeamHostMutationChange {
    case create(ConnectionProfile, SelectiveRemoteTeamHostCredentials)
    case update(recordID: UUID, profile: ConnectionProfile, credentials: SelectiveRemoteTeamHostCredentials)
    case organize([SelectiveRemoteTeamHostOrganizationUpdate])
    case delete(recordID: UUID)
}

struct SelectiveRemoteTeamHostOrganizationUpdate {
    let recordID: UUID
    let profile: ConnectionProfile
}

@MainActor
final class SelectiveRemoteTeamHostMutationService {
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

    func apply(
        _ change: SelectiveRemoteTeamHostMutationChange,
        to context: SelectiveRemoteTeamHostVaultContext,
        endpoint: URL,
        identity: SelectiveRemoteTeamDeviceIdentity,
        now: Date = Date()
    ) async throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        guard SelectiveRemoteTeamHostDocumentMutation.isWritable(role: context.role) else {
            throw SelectiveRemoteTeamHostMutationError.readOnlyRole
        }
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: snapshots
        )
        let refreshed = try await coordinator.refresh(
            teamID: context.teamID,
            vaultID: context.vaultID,
            identity: identity
        )
        let timestamp = Self.timestamp(now)
        let outcome: SelectiveRemoteTeamVaultPushOutcome
        switch refreshed {
        case let .synchronized(snapshot), let .localChanges(snapshot):
            let current = try SelectiveRemoteVaultDocument.decode(snapshot.payload)
            let document = try Self.mutated(
                current,
                change: change,
                role: context.role,
                deviceID: identity.deviceID,
                timestamp: timestamp
            )
            _ = try await coordinator.stage(
                document.encoded(),
                teamID: context.teamID,
                vaultID: context.vaultID,
                identity: identity
            )
            outcome = try await coordinator.push(
                teamID: context.teamID,
                vaultID: context.vaultID,
                identity: identity
            )
        case .empty:
            guard context.role == .owner || context.role == .admin,
                  case let .create(profile, credentials) = change
            else { throw SelectiveRemoteTeamHostMutationError.hostNotFound }
            let document = try SelectiveRemoteTeamHostDocumentMutation.create(
                profile: profile,
                credentials: credentials,
                role: context.role,
                deviceID: identity.deviceID,
                modifiedAt: timestamp
            )
            let devices = try await remote.teamKeyDevices(
                endpoint: endpoint,
                teamID: context.teamID,
                vaultID: context.vaultID
            )
            outcome = try await coordinator.initialize(
                payload: document.encoded(),
                teamID: context.teamID,
                vaultID: context.vaultID,
                identity: identity,
                keyDevices: devices
            )
        case .conflict:
            throw SelectiveRemoteTeamHostMutationError.syncConflict
        }
        guard case let .uploaded(uploaded) = outcome else {
            throw SelectiveRemoteTeamHostMutationError.syncConflict
        }
        return .init(
            teamID: context.teamID,
            teamName: context.teamName,
            role: context.role,
            vaultID: context.vaultID,
            vaultName: context.vaultName,
            revision: uploaded.snapshot.serverRevision,
            keyGeneration: uploaded.snapshot.keyGeneration,
            payload: uploaded.payload
        )
    }

    private static func mutated(
        _ document: SelectiveRemoteVaultDocument,
        change: SelectiveRemoteTeamHostMutationChange,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        timestamp: String
    ) throws -> SelectiveRemoteVaultDocument {
        switch change {
        case let .create(profile, credentials):
            try SelectiveRemoteTeamHostDocumentMutation.create(
                in: document,
                profile: profile,
                credentials: credentials,
                role: role,
                deviceID: deviceID,
                modifiedAt: timestamp
            )
        case let .update(recordID, profile, credentials):
            try SelectiveRemoteTeamHostDocumentMutation.update(
                in: document,
                recordID: recordID,
                profile: profile,
                credentials: credentials,
                role: role,
                deviceID: deviceID,
                modifiedAt: timestamp
            )
        case let .organize(updates):
            try updates.reduce(document) { partial, update in
                try SelectiveRemoteTeamHostDocumentMutation.organize(
                    in: partial,
                    recordID: update.recordID,
                    profile: update.profile,
                    role: role,
                    deviceID: deviceID,
                    modifiedAt: timestamp
                )
            }
        case let .delete(recordID):
            try SelectiveRemoteTeamHostDocumentMutation.delete(
                from: document,
                recordID: recordID,
                role: role,
                deviceID: deviceID,
                deletedAt: timestamp
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
