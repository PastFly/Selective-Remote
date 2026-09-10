import Foundation

enum SelectiveRemoteTeamHostMutationError: LocalizedError, Equatable {
    case readOnlyRole
    case duplicateHost
    case hostNotFound
    case recordIsNotHost

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
