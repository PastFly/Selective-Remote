import Foundation

protocol SelectiveRemoteTeamVaultAutoSyncRemote: SelectiveRemoteTeamVaultRemote {
    func publicationSession(endpoint: URL, deviceID: UUID) async throws -> SelectiveRemotePublicationSession?
    func materializePublication(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity, team: SelectiveRemoteCloudTeam, vault: SelectiveRemoteCloudSharedVault, offline: Bool) async throws -> SelectiveRemoteTeamVaultMaterializedSnapshot
    func reopenPublications(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity) async throws -> [SelectiveRemoteTeamVaultMaterializedSnapshot]
    func retirePublications(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) async throws
    func hasStoredSession(endpoint: URL) async -> Bool
    func teams(endpoint: URL) async throws -> [SelectiveRemoteCloudTeam]
    func sharedVaults(endpoint: URL, teamID: UUID) async throws -> [SelectiveRemoteCloudSharedVault]
}

extension SelectiveRemoteTeamVaultAutoSyncRemote {
    func publicationSession(endpoint: URL, deviceID: UUID) async throws -> SelectiveRemotePublicationSession? { nil }
    func materializePublication(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity, team: SelectiveRemoteCloudTeam, vault: SelectiveRemoteCloudSharedVault, offline: Bool) async throws -> SelectiveRemoteTeamVaultMaterializedSnapshot { throw SelectiveRemotePublicationError.invalid }
    func reopenPublications(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity) async throws -> [SelectiveRemoteTeamVaultMaterializedSnapshot] { [] }
    func retirePublications(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) async throws {}
}
extension SelectiveRemoteCloudAPIClient: SelectiveRemoteTeamVaultAutoSyncRemote {}

struct SelectiveRemoteTeamVaultAutoSyncReport: Equatable, Sendable {
    var scannedVaults = 0
    var synchronizedVaults = 0
    var uploadedVaults = 0
    var emptyVaults = 0
    var conflicts = 0
    var pendingWrappers = 0
    var wrappersGranted = 0
    var rotations = 0
    var failures = 0
    var lastFailure: String?
}

typealias SelectiveRemoteTeamVaultSnapshotStoreFactory =
    @Sendable () throws -> any SelectiveRemoteTeamVaultSnapshotStore

typealias SelectiveRemoteTeamVaultMaterializedSnapshotConsumer =
    @Sendable ([SelectiveRemoteTeamVaultMaterializedSnapshot]) async -> Void

actor SelectiveRemoteTeamVaultAutoSync {
    enum PresentationEvent: Sendable {
        case started(token: UUID, endpoint: URL, deviceID: UUID)
        case completed(SelectiveRemoteTeamVaultAutoSyncReport, token: UUID, endpoint: URL, deviceID: UUID)
        case failed(token: UUID, endpoint: URL, deviceID: UUID)
    }
    static let shared = SelectiveRemoteTeamVaultAutoSync()

    private let remote: any SelectiveRemoteTeamVaultAutoSyncRemote
    private let identityManager: SelectiveRemoteTeamDeviceIdentityManager
    private let snapshotStore: SelectiveRemoteTeamVaultSnapshotStoreFactory
    private let snapshotConsumer: SelectiveRemoteTeamVaultMaterializedSnapshotConsumer
    private let pollInterval: Duration
    private var cycle: Task<Void, Never>?
    private var eligible = true
    private var generation = UUID()
    private var synchronizationSession: SelectiveRemotePublicationSession?
    private var activeSynchronization: (
        token: UUID,
        task: Task<SelectiveRemoteTeamVaultAutoSyncReport, Error>
    )?
    private var presentationObserver: (@Sendable (PresentationEvent) async -> Void)?

    func observePresentation(_ observer: @escaping @Sendable (PresentationEvent) async -> Void) {
        presentationObserver = observer
    }

    init(
        remote: any SelectiveRemoteTeamVaultAutoSyncRemote = SelectiveRemoteCloudAPIClient(),
        identityManager: SelectiveRemoteTeamDeviceIdentityManager = .init(),
        snapshotStore: @escaping SelectiveRemoteTeamVaultSnapshotStoreFactory = {
            try SelectiveRemoteTeamVaultFileSnapshotStore()
        },
        snapshotConsumer: @escaping SelectiveRemoteTeamVaultMaterializedSnapshotConsumer = { snapshots in
            await MainActor.run {
                let snapshots = snapshots.filter { $0.publicationSession == nil || (try? $0.publicationSession?.check()) != nil }
                SelectiveRemotePublicationPresentation.shared.replace(with: snapshots)
                SelectiveRemoteTeamHostStore.shared.replace(with: snapshots)
                SelectiveRemoteTeamSnippetStore.shared.replace(with: snapshots)
                SelectiveRemoteTeamCredentialStore.shared.replace(with: snapshots)
            }
        },
        pollInterval: Duration = .seconds(15)
    ) {
        self.remote = remote
        self.identityManager = identityManager
        self.snapshotStore = snapshotStore
        self.snapshotConsumer = snapshotConsumer
        self.pollInterval = pollInterval
    }

    func start() {
        eligible = true
        guard cycle == nil else { return }
        cycle = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        eligible = false; generation = UUID(); synchronizationSession?.invalidate(); synchronizationSession = nil
        activeSynchronization?.task.cancel(); activeSynchronization = nil
        let stopGeneration = generation
        cycle?.cancel()
        cycle = nil
        await MainActor.run { SelectiveRemotePublicationPresentation.shared.clearInvalidSessions() }
        guard generation == stopGeneration else { return }
        await snapshotConsumer([])
    }

    func synchronizeOnce(
        endpoint: URL,
        deviceID: UUID
    ) async throws -> SelectiveRemoteTeamVaultAutoSyncReport {
        guard eligible else { throw CancellationError() }
        if let activeSynchronization {
            return try await activeSynchronization.task.value
        }
        let token = UUID()
        let eventGeneration = generation
        await presentationObserver?(.started(token: token, endpoint: endpoint, deviceID: deviceID))
        guard eligible, eventGeneration == generation else { throw CancellationError() }
        let task = Task { [self] in
            try await performSynchronization(endpoint: endpoint, deviceID: deviceID)
        }
        activeSynchronization = (token, task)
        do {
            let report = try await task.value
            if activeSynchronization?.token == token { activeSynchronization = nil }
            var safeReport = report
            safeReport.lastFailure = nil
            guard eligible, eventGeneration == generation else { throw CancellationError() }
            await presentationObserver?(.completed(safeReport, token: token, endpoint: endpoint, deviceID: deviceID))
            return report
        } catch {
            if activeSynchronization?.token == token { activeSynchronization = nil }
            if eligible, eventGeneration == generation { await presentationObserver?(.failed(token: token, endpoint: endpoint, deviceID: deviceID)) }
            throw error
        }
    }

    private func performSynchronization(
        endpoint: URL,
        deviceID: UUID
    ) async throws -> SelectiveRemoteTeamVaultAutoSyncReport {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        guard deviceID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        var report = SelectiveRemoteTeamVaultAutoSyncReport()
        let cycleGeneration = generation
        let hasSession = await remote.hasStoredSession(endpoint: endpoint)
        guard eligible, generation == cycleGeneration else { throw CancellationError() }
        guard hasSession else {
            await snapshotConsumer([])
            return report
        }

        let session = try await remote.publicationSession(endpoint: endpoint, deviceID: deviceID)
        synchronizationSession = session
        try session?.check()
        guard eligible, generation == cycleGeneration else { throw CancellationError() }
        let identity = try await identityManager.identity(endpoint: endpoint, deviceID: deviceID)
        try session?.check()
        let teams: [SelectiveRemoteCloudTeam]
        do { teams = try await remote.teams(endpoint: endpoint) }
        catch {
            if case SelectiveRemoteCloudError.authenticationRequired = error { try session?.prepareAuthenticationLossRetirement() }
            try session?.checkRetirement(); guard eligible, generation == cycleGeneration else { throw CancellationError() }
            if SelectiveRemoteVaultPublicationCoordinator.transient(error), let session {
                var cached = try await remote.reopenPublications(session: session, identity: identity)
                try session.check(); guard eligible, generation == cycleGeneration else { throw CancellationError() }
                for i in cached.indices { cached[i].publicationSession = session }
                await snapshotConsumer(cached); report.synchronizedVaults = cached.count; return report
            }
            if SelectiveRemoteVaultPublicationCoordinator.authoritative(error), let session {
                try await remote.retirePublications(session: session, selection: .all)
            }
            throw error
        }
        try session?.check()
        if let session { try await remote.retirePublications(session: session, selection: .teamsExcept(Set(teams.map(\.id)))) }
        var materialized: [SelectiveRemoteTeamVaultMaterializedSnapshot] = []
        for team in teams {
            try Task.checkCancellation(); try session?.check()
            guard eligible, generation == cycleGeneration else { throw CancellationError() }
            let vaults: [SelectiveRemoteCloudSharedVault]
            do {
                vaults = try await remote.sharedVaults(endpoint: endpoint, teamID: team.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if case SelectiveRemoteCloudError.authenticationRequired = error { try session?.prepareAuthenticationLossRetirement() }
                try session?.checkRetirement(); guard eligible, generation == cycleGeneration else { throw CancellationError() }
                if SelectiveRemoteVaultPublicationCoordinator.transient(error), let session {
                    let cached = try await remote.reopenPublications(session: session, identity: identity)
                    materialized += cached.filter { $0.teamID == team.id }
                }
                if SelectiveRemoteVaultPublicationCoordinator.authoritative(error), let session {
                    try await remote.retirePublications(session: session, selection: .team(team.id, keepingVaults: nil))
                }
                report.failures += 1
                report.lastFailure = error.localizedDescription
                continue
            }

            if let session { try await remote.retirePublications(session: session, selection: .team(team.id, keepingVaults: Set(vaults.map(\.id)))) }
            for vault in vaults {
                try Task.checkCancellation(); try session?.check()
                guard eligible, generation == cycleGeneration else { throw CancellationError() }
                report.scannedVaults += 1
                guard !vault.rotationRequired else {
                    report.rotations += 1
                    continue
                }
                do {
                    let format: CloudAccessFormatState
                    do { format = try await remote.vaultFormat(endpoint: endpoint, teamID: team.id, vaultID: vault.id) }
                    catch {
                        if SelectiveRemoteVaultPublicationCoordinator.transient(error), let session {
                            materialized.append(try await remote.materializePublication(session: session, identity: identity, team: team, vault: vault, offline: true))
                            continue
                        }
                        if SelectiveRemoteVaultPublicationCoordinator.authoritative(error), let session {
                            if case SelectiveRemoteCloudError.authenticationRequired = error { try session.prepareAuthenticationLossRetirement() }
                            try await remote.retirePublications(session: session, selection: .vault(teamID: team.id, vaultID: vault.id))
                        }
                        throw error
                    }
                    try session?.check()
                    if format == .active {
                        guard let session else { throw SelectiveRemoteCloudError.authenticationRequired }
                        materialized.append(try await remote.materializePublication(session: session, identity: identity, team: team, vault: vault, offline: false))
                        report.synchronizedVaults += 1; continue
                    }
                    guard format == .v1Active else { throw SelectiveRemoteTeamVaultSyncError.publicationRequired }
                    let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
                        endpoint: endpoint,
                        remote: remote,
                        snapshots: try snapshotStore()
                    )
                    report.wrappersGranted += try await coordinator.provisionMissingWrappers(
                        teamID: team.id,
                        vaultID: vault.id,
                        identity: identity
                    )
                    try Task.checkCancellation()
                    let refreshed = try await coordinator.refresh(
                        teamID: team.id,
                        vaultID: vault.id,
                        identity: identity
                    )
                    switch refreshed {
                    case .empty:
                        report.emptyVaults += 1
                    case let .synchronized(value):
                        report.synchronizedVaults += 1
                        materialized.append(Self.materializedSnapshot(
                            team: team,
                            vault: vault,
                            value: value
                        ))
                    case .localChanges:
                        let pushed = try await coordinator.push(
                            teamID: team.id,
                            vaultID: vault.id,
                            identity: identity
                        )
                        switch pushed {
                        case let .uploaded(value):
                            report.uploadedVaults += 1
                            materialized.append(Self.materializedSnapshot(
                                team: team,
                                vault: vault,
                                value: value
                            ))
                        case let .conflict(conflict):
                            let resolved = try await coordinator.resolveRecordConflictsKeepingNewest(
                                conflict,
                                resolvedAt: Self.timestamp(Date()),
                                teamID: team.id,
                                vaultID: vault.id,
                                identity: identity
                            )
                            switch resolved {
                            case let .uploaded(value, _):
                                report.uploadedVaults += 1
                                materialized.append(Self.materializedSnapshot(
                                    team: team,
                                    vault: vault,
                                    value: value
                                ))
                            case .conflict:
                                report.conflicts += 1
                            }
                        }
                    case let .conflict(conflict):
                        let resolved = try await coordinator.resolveRecordConflictsKeepingNewest(
                            conflict,
                            resolvedAt: Self.timestamp(Date()),
                            teamID: team.id,
                            vaultID: vault.id,
                            identity: identity
                        )
                        switch resolved {
                        case let .uploaded(value, _):
                            report.uploadedVaults += 1
                            materialized.append(Self.materializedSnapshot(
                                team: team,
                                vault: vault,
                                value: value
                            ))
                        case .conflict:
                            report.conflicts += 1
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper {
                    report.pendingWrappers += 1
                } catch SelectiveRemoteTeamVaultSyncError.rotationRequired {
                    report.rotations += 1
                } catch {
                    report.failures += 1
                    report.lastFailure = error.localizedDescription
                }
            }
        }
        try Task.checkCancellation(); try session?.check()
        guard eligible, generation == cycleGeneration else { throw CancellationError() }
        for i in materialized.indices { materialized[i].publicationSession = session }
        await snapshotConsumer(materialized)
        return report
    }

    func synchronizeConfiguredAccountNow() async throws -> SelectiveRemoteTeamVaultAutoSyncReport {
        guard let account = configuredAccount() else {
            await snapshotConsumer([])
            throw SelectiveRemoteCloudError.invalidRequest
        }
        return try await synchronizeOnce(endpoint: account.endpoint, deviceID: account.deviceID)
    }

    private static func materializedSnapshot(
        team: SelectiveRemoteCloudTeam,
        vault: SelectiveRemoteCloudSharedVault,
        value: SelectiveRemoteTeamVaultDecryptedSnapshot
    ) -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        .init(
            teamID: team.id,
            teamName: team.name,
            role: team.role,
            vaultID: vault.id,
            vaultName: vault.name,
            revision: value.snapshot.serverRevision,
            keyGeneration: value.snapshot.keyGeneration,
            payload: value.payload
        )
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                if let account = configuredAccount() {
                    _ = try await synchronizeOnce(
                        endpoint: account.endpoint,
                        deviceID: account.deviceID
                    )
                } else {
                    await snapshotConsumer([])
                }
                try await Task.sleep(for: pollInterval)
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func configuredAccount() -> (endpoint: URL, deviceID: UUID)? {
        guard let endpointText = UserDefaults.standard.string(
                  forKey: "SelectiveRemote.cloud.endpoint.v1"
              ),
              let endpoint = try? SelectiveRemoteCloudEndpoint.normalized(endpointText),
              let deviceText = UserDefaults.standard.string(
                  forKey: "SelectiveRemote.cloud.device-id.v1"
              ),
              let deviceID = UUID(uuidString: deviceText),
              deviceID.isSelectiveRemoteCloudUUID
        else { return nil }
        return (endpoint, deviceID)
    }
}
