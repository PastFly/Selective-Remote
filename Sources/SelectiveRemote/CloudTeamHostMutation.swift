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
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try mutate(
            document: .init(),
            profile: profile,
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
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try mutate(
            document: document,
            profile: profile,
            recordID: recordID,
            role: role,
            deviceID: deviceID,
            modifiedAt: modifiedAt,
            requiresExistingHost: true
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
        let tombstone = try SelectiveRemoteVaultTombstone(
            id: recordID,
            version: existing.version.incrementing(deviceID),
            deletedAt: deletedAt
        )
        return try .init(
            records: document.records.filter { $0.id != recordID },
            tombstones: document.tombstones.filter { $0.id != recordID } + [tombstone]
        )
    }

    private static func mutate(
        document: SelectiveRemoteVaultDocument,
        profile: ConnectionProfile,
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
        return try .init(
            records: document.records.filter { $0.id != recordID } + [record],
            tombstones: document.tombstones.filter { $0.id != recordID }
        )
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
    case create(ConnectionProfile)
    case update(recordID: UUID, profile: ConnectionProfile)
    case delete(recordID: UUID)
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
                  case let .create(profile) = change
            else { throw SelectiveRemoteTeamHostMutationError.hostNotFound }
            let document = try SelectiveRemoteTeamHostDocumentMutation.create(
                profile: profile,
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
        case let .create(profile):
            try SelectiveRemoteTeamHostDocumentMutation.create(
                in: document,
                profile: profile,
                role: role,
                deviceID: deviceID,
                modifiedAt: timestamp
            )
        case let .update(recordID, profile):
            try SelectiveRemoteTeamHostDocumentMutation.update(
                in: document,
                recordID: recordID,
                profile: profile,
                role: role,
                deviceID: deviceID,
                modifiedAt: timestamp
            )
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
