import Foundation

protocol SelectiveRemoteTeamVaultAutoSyncRemote: SelectiveRemoteTeamVaultRemote {
    func hasStoredSession(endpoint: URL) async -> Bool
    func teams(endpoint: URL) async throws -> [SelectiveRemoteCloudTeam]
    func sharedVaults(endpoint: URL, teamID: UUID) async throws -> [SelectiveRemoteCloudSharedVault]
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
}

typealias SelectiveRemoteTeamVaultSnapshotStoreFactory =
    @Sendable () throws -> any SelectiveRemoteTeamVaultSnapshotStore

actor SelectiveRemoteTeamVaultAutoSync {
    private let remote: any SelectiveRemoteTeamVaultAutoSyncRemote
    private let identityManager: SelectiveRemoteTeamDeviceIdentityManager
    private let snapshotStore: SelectiveRemoteTeamVaultSnapshotStoreFactory
    private let pollInterval: Duration
    private var cycle: Task<Void, Never>?

    init(
        remote: any SelectiveRemoteTeamVaultAutoSyncRemote = SelectiveRemoteCloudAPIClient(),
        identityManager: SelectiveRemoteTeamDeviceIdentityManager = .init(),
        snapshotStore: @escaping SelectiveRemoteTeamVaultSnapshotStoreFactory = {
            try SelectiveRemoteTeamVaultFileSnapshotStore()
        },
        pollInterval: Duration = .seconds(15)
    ) {
        self.remote = remote
        self.identityManager = identityManager
        self.snapshotStore = snapshotStore
        self.pollInterval = pollInterval
    }

    func start() {
        guard cycle == nil else { return }
        cycle = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        cycle?.cancel()
        cycle = nil
    }

    func synchronizeOnce(
        endpoint: URL,
        deviceID: UUID
    ) async throws -> SelectiveRemoteTeamVaultAutoSyncReport {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        guard deviceID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        var report = SelectiveRemoteTeamVaultAutoSyncReport()
        guard await remote.hasStoredSession(endpoint: endpoint) else { return report }

        let identity = try await identityManager.identity(endpoint: endpoint, deviceID: deviceID)
        let teams = try await remote.teams(endpoint: endpoint)
        for team in teams {
            try Task.checkCancellation()
            let vaults: [SelectiveRemoteCloudSharedVault]
            do {
                vaults = try await remote.sharedVaults(endpoint: endpoint, teamID: team.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failures += 1
                continue
            }

            for vault in vaults {
                try Task.checkCancellation()
                report.scannedVaults += 1
                guard !vault.rotationRequired else {
                    report.rotations += 1
                    continue
                }
                do {
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
                    case .synchronized:
                        report.synchronizedVaults += 1
                    case .localChanges:
                        let pushed = try await coordinator.push(
                            teamID: team.id,
                            vaultID: vault.id,
                            identity: identity
                        )
                        switch pushed {
                        case .uploaded:
                            report.uploadedVaults += 1
                        case .conflict:
                            report.conflicts += 1
                        }
                    case .conflict:
                        report.conflicts += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch SelectiveRemoteTeamVaultSyncError.missingDeviceWrapper {
                    report.pendingWrappers += 1
                } catch SelectiveRemoteTeamVaultSyncError.rotationRequired {
                    report.rotations += 1
                } catch {
                    report.failures += 1
                }
            }
        }
        return report
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                if let account = configuredAccount() {
                    _ = try await synchronizeOnce(
                        endpoint: account.endpoint,
                        deviceID: account.deviceID
                    )
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
