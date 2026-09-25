import Foundation

enum SelectiveRemoteTeamSnippetMutationError: LocalizedError, Equatable {
    case readOnlyRole
    case duplicateSnippet
    case snippetNotFound
    case recordIsNotSnippet
    case invalidSnippet
    case syncConflict

    var errorDescription: String? {
        switch self {
        case .readOnlyRole:
            UpdateLocalization.text(
                ru: "Роль Viewer может только просматривать Team Snippets.",
                en: "The Viewer role can only view Team Snippets."
            )
        case .duplicateSnippet:
            UpdateLocalization.text(
                ru: "Team Snippet с таким ID уже существует.",
                en: "A Team Snippet with this ID already exists."
            )
        case .snippetNotFound:
            UpdateLocalization.text(
                ru: "Team Snippet больше не существует.",
                en: "The Team Snippet no longer exists."
            )
        case .recordIsNotSnippet:
            UpdateLocalization.text(
                ru: "Выбранная запись не является Team Snippet.",
                en: "The selected record is not a Team Snippet."
            )
        case .invalidSnippet:
            UpdateLocalization.text(
                ru: "Проверьте название и команду Team Snippet.",
                en: "Check the Team Snippet name and command."
            )
        case .syncConflict:
            UpdateLocalization.text(
                ru: "Team Vault изменился параллельно. Синхронизируйте Vault и повторите.",
                en: "The Team Vault changed concurrently. Synchronize the Vault and try again."
            )
        }
    }
}

enum SelectiveRemoteTeamSnippetDocumentMutation {
    static func isWritable(role: SelectiveRemoteCloudTeamRole) -> Bool {
        role == .owner || role == .admin || role == .editor
    }

    static func create(
        recordID: UUID,
        title: String,
        body: String,
        folder: String = "",
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try create(
            in: .init(),
            recordID: recordID,
            title: title,
            body: body,
            folder: folder,
            role: role,
            deviceID: deviceID,
            modifiedAt: modifiedAt
        )
    }

    static func create(
        in document: SelectiveRemoteVaultDocument,
        recordID: UUID,
        title: String,
        body: String,
        folder: String = "",
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try requireWritable(role)
        guard document.records.allSatisfy({ $0.id != recordID }),
              document.tombstones.allSatisfy({ $0.id != recordID })
        else { throw SelectiveRemoteTeamSnippetMutationError.duplicateSnippet }
        let record = try makeRecord(
            id: recordID,
            priorVersion: nil,
            title: title,
            body: body,
            folder: folder,
            deviceID: deviceID,
            modifiedAt: modifiedAt
        )
        return try .init(records: document.records + [record], tombstones: document.tombstones)
    }

    static func update(
        in document: SelectiveRemoteVaultDocument,
        recordID: UUID,
        title: String,
        body: String,
        folder: String = "",
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        modifiedAt: String
    ) throws -> SelectiveRemoteVaultDocument {
        try requireWritable(role)
        guard let existing = document.records.first(where: { $0.id == recordID }) else {
            throw SelectiveRemoteTeamSnippetMutationError.snippetNotFound
        }
        guard existing.type == .snippet else {
            throw SelectiveRemoteTeamSnippetMutationError.recordIsNotSnippet
        }
        let replacement = try makeRecord(
            id: recordID,
            priorVersion: existing.version,
            title: title,
            body: body,
            folder: folder,
            deviceID: deviceID,
            modifiedAt: modifiedAt,
            previous: existing
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
            throw SelectiveRemoteTeamSnippetMutationError.snippetNotFound
        }
        guard existing.type == .snippet else {
            throw SelectiveRemoteTeamSnippetMutationError.recordIsNotSnippet
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

    private static func makeRecord(
        id: UUID,
        priorVersion: SelectiveRemoteVaultVersion?,
        title: String,
        body: String,
        folder: String,
        deviceID: UUID,
        modifiedAt: String,
        previous: SelectiveRemoteVaultRecord? = nil
    ) throws -> SelectiveRemoteVaultRecord {
        guard validTitle(title), validBody(body), validFolder(folder) else {
            throw SelectiveRemoteTeamSnippetMutationError.invalidSnippet
        }
        return try .init(
            id: id,
            type: .snippet,
            version: try priorVersion?.incrementing(deviceID)
                ?? SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: modifiedAt,
            data: SelectiveRemoteVaultBrowserMetadata.preservingFavorite(in: .object([
                "title": .string(title),
                "body": .string(body),
                "folder": .string(folder)
            ]), from: previous)
        )
    }

    private static func requireWritable(_ role: SelectiveRemoteCloudTeamRole) throws {
        guard isWritable(role: role) else {
            throw SelectiveRemoteTeamSnippetMutationError.readOnlyRole
        }
    }

    private static func validTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && !value.isEmpty && value.count <= 120
            && !value.contains(where: { $0.isNewline })
    }

    private static func validBody(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32_768
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    && $0.value != 9
                    && $0.value != 10
                    && $0.value != 13
            })
    }

    private static func validFolder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && value.count <= 120
            && !value.contains(where: { $0.isNewline })
            && !value.hasPrefix("/")
            && !value.hasSuffix("/")
            && !value.contains("//")
    }
}

enum SelectiveRemoteTeamSnippetMutationChange {
    case create(recordID: UUID, title: String, body: String, folder: String)
    case update(recordID: UUID, title: String, body: String, folder: String)
    case delete(recordID: UUID)
}

@MainActor
final class SelectiveRemoteTeamSnippetMutationService {
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
        _ change: SelectiveRemoteTeamSnippetMutationChange,
        to context: SelectiveRemoteTeamSnippetVaultContext,
        endpoint: URL,
        identity: SelectiveRemoteTeamDeviceIdentity,
        now: Date = Date()
    ) async throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        guard SelectiveRemoteTeamSnippetDocumentMutation.isWritable(role: context.role) else {
            throw SelectiveRemoteTeamSnippetMutationError.readOnlyRole
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
                  case let .create(recordID, title, body, folder) = change
            else { throw SelectiveRemoteTeamSnippetMutationError.snippetNotFound }
            let document = try SelectiveRemoteTeamSnippetDocumentMutation.create(
                recordID: recordID,
                title: title,
                body: body,
                folder: folder,
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
            throw SelectiveRemoteTeamSnippetMutationError.syncConflict
        }
        guard case let .uploaded(uploaded) = outcome else {
            throw SelectiveRemoteTeamSnippetMutationError.syncConflict
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
        change: SelectiveRemoteTeamSnippetMutationChange,
        role: SelectiveRemoteCloudTeamRole,
        deviceID: UUID,
        timestamp: String
    ) throws -> SelectiveRemoteVaultDocument {
        switch change {
        case let .create(recordID, title, body, folder):
            try SelectiveRemoteTeamSnippetDocumentMutation.create(
                in: document,
                recordID: recordID,
                title: title,
                body: body,
                folder: folder,
                role: role,
                deviceID: deviceID,
                modifiedAt: timestamp
            )
        case let .update(recordID, title, body, folder):
            try SelectiveRemoteTeamSnippetDocumentMutation.update(
                in: document,
                recordID: recordID,
                title: title,
                body: body,
                folder: folder,
                role: role,
                deviceID: deviceID,
                modifiedAt: timestamp
            )
        case let .delete(recordID):
            try SelectiveRemoteTeamSnippetDocumentMutation.delete(
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
