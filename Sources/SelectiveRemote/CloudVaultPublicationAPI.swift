import CryptoKit
import Foundation

/// Process epoch complements private durable-token comparison, including logout/relogin.
enum SelectiveRemotePublicationLifecycle {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var epochs: [String: UUID] = [:]
    nonisolated(unsafe) private static var authenticationLosses: [String: (request: UUID, retired: UUID)] = [:]
    static func epoch(endpoint: URL) -> UUID {
        lock.withLock { if let value = epochs[endpoint.absoluteString] { return value }; let value = UUID(); epochs[endpoint.absoluteString] = value; return value }
    }
    static func invalidate(endpoint: URL) { lock.withLock { epochs[endpoint.absoluteString] = UUID(); authenticationLosses.removeValue(forKey: endpoint.absoluteString) } }
    static func loseAuthentication(endpoint: URL, expectedEpoch: UUID) throws {
        try lock.withLock {
            guard epochs[endpoint.absoluteString] == expectedEpoch else { throw CancellationError() }
            let retired = UUID()
            epochs[endpoint.absoluteString] = retired
            authenticationLosses[endpoint.absoluteString] = (expectedEpoch, retired)
        }
    }
    static func authenticationLossEpoch(endpoint: URL, requestEpoch: UUID) -> UUID? {
        lock.withLock {
            guard let loss = authenticationLosses[endpoint.absoluteString], loss.request == requestEpoch,
                  epochs[endpoint.absoluteString] == loss.retired else { return nil }
            return loss.retired
        }
    }
}

final class SelectiveRemotePublicationSession: @unchecked Sendable, Equatable {
    static func == (lhs: SelectiveRemotePublicationSession, rhs: SelectiveRemotePublicationSession) -> Bool { lhs === rhs }
    let id = UUID()
    let endpoint: URL
    let accountID: UUID
    let deviceID: UUID
    private let token: String
    private let tokenStore: any SelectiveRemoteCloudTokenStore
    private let epoch: UUID
    private let checkConfiguration: Bool
    private let lock = NSLock()
    private var active = true
    private var authenticationLossEpoch: UUID?
    private var retirementOwners: [String: SelectiveRemotePublicationPayloadStamp] = [:]
    init(endpoint: URL, accountID: UUID, deviceID: UUID, token: String, tokenStore: any SelectiveRemoteCloudTokenStore, checkConfiguration: Bool = false) {
        self.endpoint = endpoint; self.accountID = accountID; self.deviceID = deviceID
        self.token = token; self.tokenStore = tokenStore; self.checkConfiguration = checkConfiguration; epoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
    }
    func invalidate() { lock.withLock { active = false } }
    /// Protected receipt identity, never exposed in models, UI or logs.
    var authorizationStamp: String {
        SHA256.hash(data: Data((endpoint.absoluteString + "\n" + accountID.canonicalCloudString + "\n" + deviceID.canonicalCloudString + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func prepareAuthenticationLossRetirement() throws {
        guard lock.withLock({ active }), try tokenStore.token(for: endpoint) == nil,
              let lost = SelectiveRemotePublicationLifecycle.authenticationLossEpoch(endpoint: endpoint, requestEpoch: epoch) else { throw CancellationError() }
        lock.withLock { authenticationLossEpoch = lost }
    }
    var retiringAuthenticationLoss: Bool { lock.withLock { authenticationLossEpoch != nil } }
    func captureRetirementOwners(_ owners: [String: SelectiveRemotePublicationPayloadStamp]) throws {
        try check(); lock.withLock { retirementOwners = owners }; try check()
    }
    func capturedRetirementOwner(scope: SelectiveRemotePublicationScope) -> SelectiveRemotePublicationPayloadStamp? { lock.withLock { retirementOwners[scope.key] } }
    /// Freeze receipt ownership before suspension; another reader may refresh the reusable session.
    func retirementSnapshot() throws -> SelectiveRemotePublicationSession {
        try check()
        let snapshot = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: accountID, deviceID: deviceID, token: token, tokenStore: tokenStore, checkConfiguration: checkConfiguration)
        try snapshot.captureRetirementOwners(lock.withLock { retirementOwners })
        try check()
        return snapshot
    }
    func checkRetirement() throws {
        if let lost = lock.withLock({ authenticationLossEpoch }) {
            guard lock.withLock({ active }), SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == lost,
                  try tokenStore.token(for: endpoint) == nil else { throw CancellationError() }
            try Task.checkCancellation()
        } else { try check() }
    }
    func sameAuthorization(as other: SelectiveRemotePublicationSession) -> Bool { endpoint == other.endpoint && accountID == other.accountID && deviceID == other.deviceID && epoch == other.epoch && token == other.token }
    func check() throws {
        guard lock.withLock({ active }), SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == epoch,
              try tokenStore.token(for: endpoint) == token else { throw CancellationError() }
        if checkConfiguration {
            guard UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.endpoint.v1").flatMap({ try? SelectiveRemoteCloudEndpoint.normalized($0) }) == endpoint,
                UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.device-id.v1").flatMap(UUID.init(uuidString:)) == deviceID else { throw CancellationError() }
        }
        try Task.checkCancellation()
    }
}

struct SelectiveRemotePublicationScope: Codable, Equatable, Sendable {
    let endpoint: URL
    let accountID: UUID
    let deviceID: UUID
    let teamID: UUID
    let vaultID: UUID
    var key: String { [endpoint.absoluteString, accountID.canonicalCloudString, deviceID.canonicalCloudString, teamID.canonicalCloudString, vaultID.canonicalCloudString].joined(separator: "\n") }
}

enum SelectiveRemotePublicationRetirement: Sendable {
    case all
    case teamsExcept(Set<UUID>)
    case team(UUID, keepingVaults: Set<UUID>?)
    case vault(teamID: UUID, vaultID: UUID)
    func matches(_ scope: SelectiveRemotePublicationScope) -> Bool {
        switch self {
        case .all: true
        case let .teamsExcept(ids): !ids.contains(scope.teamID)
        case let .team(id, keeping): scope.teamID == id && !(keeping?.contains(scope.vaultID) ?? false)
        case let .vault(teamID, vaultID): scope.teamID == teamID && scope.vaultID == vaultID
        }
    }
}

protocol SelectiveRemoteVaultPublicationRemote: Sendable {
    func publicationRead(scope: SelectiveRemotePublicationScope, route: String, generation: String?, hash: String?, cursor: String?) async throws -> SelectiveRemoteJSONValue
    func publicationOwnTrust(endpoint: URL) async throws -> SelectiveRemoteCloudDeviceTrustSnapshot
}

/// Explicit isolated token stores may own session resolution. This branch never consults app preferences.
/// A provider must bind endpoint/account/device/token and fail closed if its authorization is unavailable.
protocol SelectiveRemotePublicationSessionProviding: Sendable {
    func isolatedPublicationSession(endpoint: URL, token: String, deviceID: UUID?) throws -> SelectiveRemotePublicationSession?
}

extension SelectiveRemoteCloudAPIClient: SelectiveRemoteVaultPublicationRemote {
    func publicationRead(scope: SelectiveRemotePublicationScope, route: String, generation: String? = nil, hash: String? = nil, cursor: String? = nil) async throws -> SelectiveRemoteJSONValue {
        var query: [URLQueryItem] = []
        if let generation { query.append(.init(name: "generationID", value: generation)) }
        if let hash { query.append(.init(name: "headerHash", value: hash)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let (data, response) = try await authorizedResponse(endpoint: scope.endpoint,
            path: "v1/teams/\(scope.teamID.canonicalCloudString)/vaults/\(scope.vaultID.canonicalCloudString)/publication/\(route)",
            headers: ["X-Vault-Schema-Version": "2", "X-Vault-Capability": "resource_acl_v2", "X-Publication-Version": "1"], queryItems: query)
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw SelectiveRemoteCloudError.serviceError(response.statusCode, code)
        }
        guard data.count <= 3 * 1024 * 1024 else { throw SelectiveRemotePublicationError.invalid }
        return try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: data)
    }
    func publicationOwnTrust(endpoint: URL) async throws -> SelectiveRemoteCloudDeviceTrustSnapshot { try await deviceTrustSnapshot(endpoint: endpoint) }

    private struct AccountBinding: Codable { let accountID: UUID; let tokenHash: String }
    private func publicationAccountBindingKey(endpoint: URL, token: String) -> String {
        SHA256.hash(data: Data((endpoint.absoluteString + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func rememberPublicationAccount(_ id: UUID, endpoint: URL, token: String) throws {
        try tokenStore.savePublicationAccountBinding(JSONEncoder().encode(AccountBinding(accountID: id,
            tokenHash: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined())),
            key: publicationAccountBindingKey(endpoint: endpoint, token: token))
    }
    private func protectedPublicationAccount(endpoint: URL, token: String) throws -> UUID? {
        guard let data = try tokenStore.publicationAccountBinding(key: publicationAccountBindingKey(endpoint: endpoint, token: token)),
              let binding = try? JSONDecoder().decode(AccountBinding.self, from: data),
              binding.tokenHash == SHA256.hash(data: Data(token.utf8)).map({ String(format: "%02x", $0) }).joined() else { return nil }
        return binding.accountID
    }
    /// Reuse one captured catalog per authorization, never perform catalog I/O for each part read.
    func publicationRetirementSession(endpoint: URL, token: String, deviceID: UUID? = nil) throws -> SelectiveRemotePublicationSession? {
        if let provider = tokenStore as? any SelectiveRemotePublicationSessionProviding {
            let session = try provider.isolatedPublicationSession(endpoint: endpoint, token: token, deviceID: deviceID)
            try session?.check()
            if let session { try publicationStore().captureRetirementOwners(session: session) }
            return session
        }
        if let current = publicationRetirementSessions[endpoint.absoluteString],
           (try? current.check()) != nil, deviceID == nil || deviceID == current.deviceID { return current }
        let configuredEndpoint = UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.endpoint.v1").flatMap { try? SelectiveRemoteCloudEndpoint.normalized($0) }
        let configuredDevice = configuredEndpoint == endpoint ? UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.device-id.v1").flatMap(UUID.init(uuidString:)) : nil
        guard let device = deviceID ?? configuredDevice, let account = try protectedPublicationAccount(endpoint: endpoint, token: token) else { return nil }
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: account, deviceID: device, token: token, tokenStore: tokenStore, checkConfiguration: configuredEndpoint == endpoint)
        try publicationStore().captureRetirementOwners(session: session)
        publicationRetirementSessions[endpoint.absoluteString] = session
        return session
    }
    func publicationSession(endpoint: URL, deviceID: UUID) async throws -> SelectiveRemotePublicationSession? {
        guard let token = try tokenStore.token(for: endpoint) else { throw SelectiveRemoteCloudError.authenticationRequired }
        if let provider = tokenStore as? any SelectiveRemotePublicationSessionProviding {
            let session = try provider.isolatedPublicationSession(endpoint: endpoint, token: token, deviceID: deviceID)
            try session?.check()
            if let session { try publicationStore().captureRetirementOwners(session: session) }
            return session
        }
        let epoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        let preflight = try publicationRetirementSession(endpoint: endpoint, token: token, deviceID: deviceID)
        let id: UUID
        do { id = try await currentUser(endpoint: endpoint).id }
        catch {
            guard SelectiveRemoteVaultPublicationCoordinator.transient(error),
                  let account = try protectedPublicationAccount(endpoint: endpoint, token: token) else { throw error }
            id = account
        }
        guard try tokenStore.token(for: endpoint) == token, SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == epoch else { throw CancellationError() }
        if let preflight, preflight.accountID == id { try preflight.check(); return preflight }
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: id, deviceID: deviceID, token: token, tokenStore: tokenStore, checkConfiguration: UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.endpoint.v1").flatMap({ try? SelectiveRemoteCloudEndpoint.normalized($0) }) == endpoint)
        try publicationStore().captureRetirementOwners(session: session)
        publicationRetirementSessions[endpoint.absoluteString] = session
        return session
    }
}

extension SelectiveRemoteCloudAPIClient {
    func preparePublicationRetirement(session: SelectiveRemotePublicationSession) async throws {
        try publicationStore().captureRetirementOwners(session: session)
        publicationRetirementSessions[session.endpoint.absoluteString] = session
    }
    func retirePublications(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) async throws {
        do {
            _ = try publicationStore().retireScopes(session: session, selection: selection)
            try session.checkRetirement()
        } catch {
            await detachRetiredPublications(session: session, selection: selection)
            throw error
        }
        await detachRetiredPublications(session: session, selection: selection)
    }
    private func detachRetiredPublications(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) async {
        // Isolated providers own their presentation. Durable retirement above still runs normally.
        if tokenStore is any SelectiveRemotePublicationSessionProviding { return }
        await MainActor.run {
            let presentation = SelectiveRemotePublicationPresentation.shared
            let scopes = presentation.caches.map(\.scope).filter {
                $0.endpoint == session.endpoint && $0.accountID == session.accountID && $0.deviceID == session.deviceID && selection.matches($0)
            }
            scopes.forEach { presentation.detach(scope: $0, expectedSession: session) }
        }
    }
    func vaultFormat(endpoint: URL, teamID: UUID, vaultID: UUID) async throws -> CloudAccessFormatState {
        let reference = try SelectiveRemoteCloudAccessReference(teamID: teamID, vaultID: vaultID, resourceID: vaultID, kind: .vault)
        return try await SelectiveRemoteCloudAccessClient(client: self).context(reference, session: .init(endpoint: endpoint)).formatState
    }
    func materializePublication(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity,
                                team: SelectiveRemoteCloudTeam, vault: SelectiveRemoteCloudSharedVault, offline: Bool) async throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        let scope = SelectiveRemotePublicationScope(endpoint: session.endpoint, accountID: session.accountID, deviceID: session.deviceID, teamID: team.id, vaultID: vault.id)
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: scope, session: session, remote: self, identity: identity, store: try publicationStore())
        do {
            let cache = offline ? try await reader.offline() : try await reader.load(teamName: team.name, vaultName: vault.name, role: team.role)
            try session.check()
            try await MainActor.run { try SelectiveRemotePublicationPresentation.shared.bind(reader: reader, session: session, scope: scope, cache: cache) }
            try session.check()
            return try cache.materializedSnapshot()
        } catch let challenge as SelectiveRemotePublisherVerification {
            try session.check()
            await MainActor.run { SelectiveRemotePublisherVerificationSheet.present(challenge: challenge, reader: reader, session: session) }
            throw challenge
        }
    }
    func reopenPublications(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity) async throws -> [SelectiveRemoteTeamVaultMaterializedSnapshot] {
        let store = try publicationStore()
        var snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot] = []
        for scope in try store.cachedScopes(session: session) {
            try session.check()
            let reader = SelectiveRemoteVaultPublicationCoordinator(scope: scope, session: session, remote: self, identity: identity, store: store)
            if let cache = try? await reader.offline() {
                try session.check()
                try await MainActor.run { try SelectiveRemotePublicationPresentation.shared.bind(reader: reader, session: session, scope: scope, cache: cache) }
                snapshots.append(try cache.materializedSnapshot())
            }
        }
        try session.check()
        return snapshots
    }
}
