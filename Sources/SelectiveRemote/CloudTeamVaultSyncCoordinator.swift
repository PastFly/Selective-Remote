import Foundation

enum SelectiveRemoteTeamVaultSyncError: LocalizedError, Equatable {
    case rotationRequired
    case missingDeviceWrapper
    case noLocalSnapshot
    case noLocalChanges
    case invalidLocalSnapshot
    case remoteRevisionRollback
    case remoteRevisionDivergence
    case invalidWriteAcknowledgement
    case invalidWrapperGrantAcknowledgement
    case invalidConflictResponse
    case staleConflict
    case invalidKeyDevices

    var errorDescription: String? {
        switch self {
        case .rotationRequired:
            UpdateLocalization.text(
                ru: "Для Team Vault требуется ротация ключа. Завершите её в Cloud и повторите операцию.",
                en: "The Team Vault key must be rotated. Complete the rotation in Cloud and try again."
            )
        case .missingDeviceWrapper:
            UpdateLocalization.text(
                ru: "Для этого Mac ещё не выдан ключ выбранного Team Vault. Откройте Vault в уже доверенном браузере или на другом устройстве, выдайте недостающие wrappers и повторите операцию.",
                en: "This Mac does not have a key for the selected Team Vault yet. Open the Vault in an already trusted browser or on another device, grant the missing wrappers, and try again."
            )
        case .noLocalSnapshot:
            UpdateLocalization.text(
                ru: "Локальная копия Team Vault ещё не создана. Обновите Vault и повторите операцию.",
                en: "The local Team Vault snapshot has not been created yet. Refresh the Vault and try again."
            )
        case .noLocalChanges:
            UpdateLocalization.text(
                ru: "В Team Vault нет локальных изменений для отправки.",
                en: "There are no local Team Vault changes to upload."
            )
        case .invalidLocalSnapshot:
            UpdateLocalization.text(
                ru: "Локальная копия Team Vault повреждена или несовместима.",
                en: "The local Team Vault snapshot is invalid or incompatible."
            )
        case .remoteRevisionRollback:
            UpdateLocalization.text(
                ru: "Cloud вернул более старую ревизию Team Vault. Запись остановлена для защиты данных.",
                en: "Cloud returned an older Team Vault revision. The write was stopped to protect your data."
            )
        case .remoteRevisionDivergence:
            UpdateLocalization.text(
                ru: "Ревизия Team Vault расходится с локальной копией. Обновите Vault и разрешите конфликт.",
                en: "The Team Vault revision diverges from the local snapshot. Refresh the Vault and resolve the conflict."
            )
        case .invalidWriteAcknowledgement, .invalidConflictResponse:
            UpdateLocalization.text(
                ru: "Cloud не подтвердил безопасную запись в Team Vault. Данные не были перезаписаны.",
                en: "Cloud did not confirm a safe Team Vault write. No data was overwritten."
            )
        case .invalidWrapperGrantAcknowledgement:
            UpdateLocalization.text(
                ru: "Cloud не подтвердил безопасную выдачу ключа Team Vault этому устройству.",
                en: "Cloud did not confirm the Team Vault key grant to this device."
            )
        case .staleConflict:
            UpdateLocalization.text(
                ru: "Team Vault снова изменился во время разрешения конфликта. Обновите его и повторите выбор.",
                en: "The Team Vault changed again while resolving the conflict. Refresh it and repeat your choice."
            )
        case .invalidKeyDevices:
            UpdateLocalization.text(
                ru: "Cloud вернул неполный список доверенных устройств. Инициализация Team Vault остановлена.",
                en: "Cloud returned an incomplete trusted-device list. Team Vault initialization was stopped."
            )
        }
    }
}

protocol SelectiveRemoteTeamVaultRemote: Sendable {
    func teamKeyDevices(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> [SelectiveRemoteCloudTeamKeyDevice]

    func grantSharedVaultWrapper(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int,
        wrapper: SelectiveRemoteTeamVaultKeyWrapper,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWrapperGrant

    func sharedVault(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> SelectiveRemoteCloudSharedVaultEnvelope

    func putSharedVault(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID,
        upload: SelectiveRemoteCloudTeamVaultUpload,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWriteResult
}

extension SelectiveRemoteCloudAPIClient: SelectiveRemoteTeamVaultRemote {}

struct SelectiveRemoteTeamVaultDecryptedSnapshot: Equatable, Sendable {
    let snapshot: SelectiveRemoteTeamVaultSnapshot
    let payload: Data
}

struct SelectiveRemoteTeamVaultRemoteVersion: Equatable, Sendable {
    let revision: Int
    let keyGeneration: Int
    let envelope: SelectiveRemoteTeamVaultPayloadEnvelope
    let wrapper: SelectiveRemoteTeamVaultKeyWrapper
    let payload: Data
}

struct SelectiveRemoteTeamVaultConflict: Equatable, Sendable {
    let local: SelectiveRemoteTeamVaultDecryptedSnapshot
    let remote: SelectiveRemoteTeamVaultRemoteVersion
}

enum SelectiveRemoteTeamVaultRefreshOutcome: Equatable, Sendable {
    case empty(SelectiveRemoteCloudSharedVaultEnvelope)
    case synchronized(SelectiveRemoteTeamVaultDecryptedSnapshot)
    case localChanges(SelectiveRemoteTeamVaultDecryptedSnapshot)
    case conflict(SelectiveRemoteTeamVaultConflict)
}

enum SelectiveRemoteTeamVaultPushOutcome: Equatable, Sendable {
    case uploaded(SelectiveRemoteTeamVaultDecryptedSnapshot)
    case conflict(SelectiveRemoteTeamVaultConflict)
}

actor SelectiveRemoteTeamVaultSyncCoordinator {
    private let endpoint: URL
    private let remote: any SelectiveRemoteTeamVaultRemote
    private let snapshots: any SelectiveRemoteTeamVaultSnapshotStore

    init(
        endpoint: URL,
        remote: any SelectiveRemoteTeamVaultRemote,
        snapshots: any SelectiveRemoteTeamVaultSnapshotStore
    ) throws {
        self.endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        self.remote = remote
        self.snapshots = snapshots
    }

    func provisionMissingWrappers(
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) async throws -> Int {
        let remoteEnvelope = try await remote.sharedVault(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        )
        guard !remoteEnvelope.rotationRequired else {
            throw SelectiveRemoteTeamVaultSyncError.rotationRequired
        }
        guard remoteEnvelope.revision > 0 else { return 0 }

        let remoteVersion = try decryptedRemoteVersion(
            remoteEnvelope,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        let devices = try await remote.teamKeyDevices(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        )
        guard !devices.isEmpty,
              devices.count <= 1_024,
              Set(devices.map(\.deviceID)).count == devices.count,
              devices.allSatisfy({
                  $0.membershipID.isSelectiveRemoteCloudUUID
                      && $0.membershipEpoch > 0
                      && $0.deviceID.isSelectiveRemoteCloudUUID
                      && $0.publicKeyAlgorithm == "p256-ecdh-v1"
              }),
              let actor = devices.first(where: { $0.deviceID == identity.deviceID }),
              actor.hasWrapper,
              actor.membershipID == remoteVersion.wrapper.membershipID,
              actor.membershipEpoch == remoteVersion.wrapper.membershipEpoch
        else { throw SelectiveRemoteTeamVaultSyncError.invalidKeyDevices }

        let vaultKey = try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            remoteVersion.wrapper,
            with: identity,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: remoteVersion.keyGeneration
        )
        var granted = 0
        for recipient in devices where !recipient.hasWrapper {
            try Task.checkCancellation()
            let wrapper = try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
                vaultKey,
                for: recipient.publicKey,
                context: SelectiveRemoteTeamWrapperContext(
                    teamID: teamID,
                    vaultID: vaultID,
                    keyGeneration: remoteVersion.keyGeneration,
                    membershipID: recipient.membershipID,
                    membershipEpoch: recipient.membershipEpoch,
                    deviceID: recipient.deviceID
                )
            )
            let acknowledgement = try await remote.grantSharedVaultWrapper(
                endpoint: endpoint,
                teamID: teamID,
                vaultID: vaultID,
                keyGeneration: remoteVersion.keyGeneration,
                wrapper: wrapper,
                idempotencyKey: "macos:team-vault:grant:\(UUID().canonicalCloudString)"
            )
            guard acknowledgement.granted,
                  acknowledgement.keyGeneration == remoteVersion.keyGeneration,
                  acknowledgement.deviceID == recipient.deviceID
            else {
                throw SelectiveRemoteTeamVaultSyncError.invalidWrapperGrantAcknowledgement
            }
            granted += 1
        }
        return granted
    }

    func initialize(
        payload: Data,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity,
        keyDevices: [SelectiveRemoteCloudTeamKeyDevice]
    ) async throws -> SelectiveRemoteTeamVaultPushOutcome {
        guard try snapshots.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == nil,
              !keyDevices.isEmpty,
              keyDevices.count <= 1_024,
              Set(keyDevices.map(\.deviceID)).count == keyDevices.count,
              keyDevices.contains(where: { $0.deviceID == identity.deviceID })
        else { throw SelectiveRemoteTeamVaultSyncError.invalidKeyDevices }

        var generator = SystemRandomNumberGenerator()
        let vaultKey = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let wrappers = try keyDevices.map { recipient in
            try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
                vaultKey,
                for: recipient.publicKey,
                context: SelectiveRemoteTeamWrapperContext(
                    teamID: teamID,
                    vaultID: vaultID,
                    keyGeneration: 1,
                    membershipID: recipient.membershipID,
                    membershipEpoch: recipient.membershipEpoch,
                    deviceID: recipient.deviceID
                )
            )
        }
        guard let currentWrapper = wrappers.first(where: { $0.deviceID == identity.deviceID }) else {
            throw SelectiveRemoteTeamVaultSyncError.invalidKeyDevices
        }
        let envelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            payload,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: 1,
            baseRevision: 0
        )
        let prepared = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: identity.deviceID,
            keyGeneration: 1,
            localRevision: 1,
            serverRevision: 0,
            syncedLocalRevision: 0,
            envelope: envelope,
            wrapper: currentWrapper
        )
        try snapshots.save(prepared, endpoint: endpoint)

        let write = try await remote.putSharedVault(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID,
            upload: .init(envelope: envelope, wrappers: wrappers),
            idempotencyKey: "macos:team-vault:initialize:\(UUID().canonicalCloudString)"
        )
        if write.conflict {
            let refreshed = try await refresh(
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            )
            guard case let .conflict(conflict) = refreshed else {
                throw SelectiveRemoteTeamVaultSyncError.invalidConflictResponse
            }
            return .conflict(conflict)
        }
        guard write.revision == 1,
              write.keyGeneration == 1,
              write.rotationCompleted == false
        else { throw SelectiveRemoteTeamVaultSyncError.invalidWriteAcknowledgement }

        let uploaded = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: identity.deviceID,
            keyGeneration: 1,
            localRevision: 1,
            serverRevision: 1,
            syncedLocalRevision: 1,
            envelope: envelope,
            wrapper: currentWrapper
        )
        try snapshots.save(uploaded, endpoint: endpoint)
        return .uploaded(.init(snapshot: uploaded, payload: payload))
    }

    func refresh(
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) async throws -> SelectiveRemoteTeamVaultRefreshOutcome {
        let remoteEnvelope = try await remote.sharedVault(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        )
        guard !remoteEnvelope.rotationRequired else {
            throw SelectiveRemoteTeamVaultSyncError.rotationRequired
        }

        let local = try snapshots.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        guard remoteEnvelope.revision > 0 else {
            guard local == nil else {
                throw SelectiveRemoteTeamVaultSyncError.remoteRevisionRollback
            }
            return .empty(remoteEnvelope)
        }

        let remoteVersion = try decryptedRemoteVersion(
            remoteEnvelope,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard let local else {
            return .synchronized(try accept(
                remoteVersion,
                replacing: nil,
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            ))
        }
        guard local.deviceID == identity.deviceID else {
            throw SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper
        }
        try validateLocalCausality(local)
        guard remoteVersion.revision >= local.serverRevision else {
            throw SelectiveRemoteTeamVaultSyncError.remoteRevisionRollback
        }

        let localVersion = try decryptedLocalVersion(
            local,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        let hasLocalChanges = local.localRevision > local.syncedLocalRevision

        if remoteVersion.revision == local.serverRevision {
            if remoteVersion.keyGeneration != local.keyGeneration {
                throw SelectiveRemoteTeamVaultSyncError.remoteRevisionDivergence
            }
            if hasLocalChanges {
                return .localChanges(localVersion)
            }
            guard remoteVersion.envelope.contentHash == local.envelope.contentHash else {
                throw SelectiveRemoteTeamVaultSyncError.remoteRevisionDivergence
            }
            return .synchronized(try accept(
                remoteVersion,
                replacing: local,
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            ))
        }

        if hasLocalChanges {
            return .conflict(.init(local: localVersion, remote: remoteVersion))
        }
        return .synchronized(try accept(
            remoteVersion,
            replacing: local,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        ))
    }

    func stage(
        _ payload: Data,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) throws -> SelectiveRemoteTeamVaultDecryptedSnapshot {
        guard let current = try snapshots.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) else {
            throw SelectiveRemoteTeamVaultSyncError.noLocalSnapshot
        }
        guard current.deviceID == identity.deviceID else {
            throw SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper
        }
        try validateLocalCausality(current)
        let (nextLocalRevision, overflow) = current.localRevision.addingReportingOverflow(1)
        guard !overflow else { throw SelectiveRemoteTeamVaultSyncError.invalidLocalSnapshot }
        let vaultKey = try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            current.wrapper,
            with: identity,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: current.keyGeneration
        )
        let envelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            payload,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: current.keyGeneration,
            baseRevision: current.serverRevision
        )
        let staged = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: identity.deviceID,
            keyGeneration: current.keyGeneration,
            localRevision: nextLocalRevision,
            serverRevision: current.serverRevision,
            syncedLocalRevision: current.syncedLocalRevision,
            envelope: envelope,
            wrapper: current.wrapper
        )
        try snapshots.save(staged, endpoint: endpoint)
        return .init(snapshot: staged, payload: payload)
    }

    func push(
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) async throws -> SelectiveRemoteTeamVaultPushOutcome {
        guard let local = try snapshots.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) else {
            throw SelectiveRemoteTeamVaultSyncError.noLocalSnapshot
        }
        guard local.localRevision > local.syncedLocalRevision else {
            throw SelectiveRemoteTeamVaultSyncError.noLocalChanges
        }
        try validateLocalCausality(local)
        let localVersion = try decryptedLocalVersion(
            local,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        let write = try await remote.putSharedVault(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID,
            upload: .init(envelope: local.envelope, wrappers: nil),
            idempotencyKey: Self.idempotencyKey(vaultID: vaultID, snapshot: local)
        )
        if write.conflict {
            guard write.revision >= local.serverRevision,
                  write.keyGeneration > 0
            else { throw SelectiveRemoteTeamVaultSyncError.invalidConflictResponse }
            let refreshed = try await refresh(teamID: teamID, vaultID: vaultID, identity: identity)
            guard case let .conflict(conflict) = refreshed else {
                throw SelectiveRemoteTeamVaultSyncError.invalidConflictResponse
            }
            return .conflict(conflict)
        }
        let (expectedServerRevision, overflow) = local.serverRevision.addingReportingOverflow(1)
        guard !overflow,
              write.revision == expectedServerRevision,
              write.keyGeneration == local.keyGeneration,
              write.rotationCompleted == false
        else { throw SelectiveRemoteTeamVaultSyncError.invalidWriteAcknowledgement }

        let uploaded = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: identity.deviceID,
            keyGeneration: local.keyGeneration,
            localRevision: local.localRevision,
            serverRevision: write.revision,
            syncedLocalRevision: local.localRevision,
            envelope: local.envelope,
            wrapper: local.wrapper
        )
        try snapshots.save(uploaded, endpoint: endpoint)
        return .uploaded(.init(snapshot: uploaded, payload: localVersion.payload))
    }

    /// Conditionally uploads a caller-resolved payload from the exact remote
    /// revision that produced the conflict. The caller must resolve every
    /// record-level conflict and join both causal histories before calling.
    ///
    /// The existing dirty snapshot is left untouched until the remote version
    /// is revalidated. Once prepared, the resolution remains dirty on disk so
    /// an unknown network outcome can be retried with the same idempotency key.
    func resolveConflict(
        _ conflict: SelectiveRemoteTeamVaultConflict,
        resolvedPayload: Data,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) async throws -> SelectiveRemoteTeamVaultPushOutcome {
        guard let current = try snapshots.load(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        ) else { throw SelectiveRemoteTeamVaultSyncError.noLocalSnapshot }
        guard current == conflict.local.snapshot,
              current.deviceID == identity.deviceID
        else { throw SelectiveRemoteTeamVaultSyncError.staleConflict }
        try validateLocalCausality(current)
        let currentLocal = try decryptedLocalVersion(
            current,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard currentLocal.payload == conflict.local.payload else {
            throw SelectiveRemoteTeamVaultSyncError.staleConflict
        }

        let remoteEnvelope = try await remote.sharedVault(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        )
        guard !remoteEnvelope.rotationRequired else {
            throw SelectiveRemoteTeamVaultSyncError.rotationRequired
        }
        let latestRemote = try decryptedRemoteVersion(
            remoteEnvelope,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard latestRemote.revision > current.serverRevision else {
            throw SelectiveRemoteTeamVaultSyncError.invalidConflictResponse
        }
        guard latestRemote == conflict.remote else {
            return .conflict(.init(local: currentLocal, remote: latestRemote))
        }

        // Actor methods are re-entrant across the remote fetch above. Refuse
        // to replace a newer local edit that was staged while this resolution
        // was waiting for the network.
        guard let revalidated = try snapshots.load(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        ), revalidated == current else {
            throw SelectiveRemoteTeamVaultSyncError.staleConflict
        }

        let (nextLocalRevision, overflow) = current.localRevision.addingReportingOverflow(1)
        guard !overflow else { throw SelectiveRemoteTeamVaultSyncError.invalidLocalSnapshot }
        let vaultKey = try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            latestRemote.wrapper,
            with: identity,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: latestRemote.keyGeneration
        )
        let resolvedEnvelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            resolvedPayload,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: latestRemote.keyGeneration,
            baseRevision: latestRemote.revision
        )
        let prepared = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: identity.deviceID,
            keyGeneration: latestRemote.keyGeneration,
            localRevision: nextLocalRevision,
            serverRevision: latestRemote.revision,
            syncedLocalRevision: current.syncedLocalRevision,
            envelope: resolvedEnvelope,
            wrapper: latestRemote.wrapper
        )
        try snapshots.save(prepared, endpoint: endpoint)
        return try await push(teamID: teamID, vaultID: vaultID, identity: identity)
    }

    private func accept(
        _ remoteVersion: SelectiveRemoteTeamVaultRemoteVersion,
        replacing local: SelectiveRemoteTeamVaultSnapshot?,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) throws -> SelectiveRemoteTeamVaultDecryptedSnapshot {
        let sameRevision = local?.serverRevision == remoteVersion.revision
        let previousLocalRevision = local?.localRevision ?? 0
        let (advancedLocalRevision, overflow) = previousLocalRevision.addingReportingOverflow(1)
        guard !overflow else { throw SelectiveRemoteTeamVaultSyncError.invalidLocalSnapshot }
        let localRevision = sameRevision ? (local?.localRevision ?? 1) : advancedLocalRevision
        let accepted = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: identity.deviceID,
            keyGeneration: remoteVersion.keyGeneration,
            localRevision: localRevision,
            serverRevision: remoteVersion.revision,
            syncedLocalRevision: localRevision,
            envelope: remoteVersion.envelope,
            wrapper: remoteVersion.wrapper
        )
        try snapshots.save(accepted, endpoint: endpoint)
        return .init(snapshot: accepted, payload: remoteVersion.payload)
    }

    private func decryptedRemoteVersion(
        _ value: SelectiveRemoteCloudSharedVaultEnvelope,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) throws -> SelectiveRemoteTeamVaultRemoteVersion {
        guard let envelope = try value.payloadEnvelope,
              let wrapper = value.wrapper,
              wrapper.deviceID == identity.deviceID
        else { throw SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper }
        let vaultKey = try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            wrapper,
            with: identity,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: value.keyGeneration
        )
        let payload = try SelectiveRemoteTeamVaultCrypto.decryptPayload(
            envelope,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID
        )
        return .init(
            revision: value.revision,
            keyGeneration: value.keyGeneration,
            envelope: envelope,
            wrapper: wrapper,
            payload: payload
        )
    }

    private func decryptedLocalVersion(
        _ value: SelectiveRemoteTeamVaultSnapshot,
        teamID: UUID,
        vaultID: UUID,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) throws -> SelectiveRemoteTeamVaultDecryptedSnapshot {
        guard value.teamID == teamID,
              value.vaultID == vaultID,
              value.deviceID == identity.deviceID
        else { throw SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper }
        let vaultKey = try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            value.wrapper,
            with: identity,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: value.keyGeneration
        )
        let payload = try SelectiveRemoteTeamVaultCrypto.decryptPayload(
            value.envelope,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID
        )
        return .init(snapshot: value, payload: payload)
    }

    private func validateLocalCausality(_ value: SelectiveRemoteTeamVaultSnapshot) throws {
        let hasLocalChanges = value.localRevision > value.syncedLocalRevision
        let expectedBaseRevision = hasLocalChanges
            ? value.serverRevision
            : max(0, value.serverRevision - 1)
        guard value.envelope.baseRevision == expectedBaseRevision else {
            throw SelectiveRemoteTeamVaultSyncError.invalidLocalSnapshot
        }
    }

    private static func idempotencyKey(
        vaultID: UUID,
        snapshot: SelectiveRemoteTeamVaultSnapshot
    ) -> String {
        "macos:team-vault:\(vaultID.canonicalCloudString):\(snapshot.localRevision):\(snapshot.envelope.contentHash)"
    }
}
