import CryptoKit
import Foundation

/// Process epoch complements private durable-token comparison, including logout/relogin.
enum SelectiveRemotePublicationLifecycle {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var epochs: [String: UUID] = [:]
    static func epoch(endpoint: URL) -> UUID {
        lock.withLock { if let value = epochs[endpoint.absoluteString] { return value }; let value = UUID(); epochs[endpoint.absoluteString] = value; return value }
    }
    static func invalidate(endpoint: URL) { lock.withLock { epochs[endpoint.absoluteString] = UUID() } }
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
        guard lock.withLock({ active }), try tokenStore.token(for: endpoint) == nil else { throw CancellationError() }
        lock.withLock { authenticationLossEpoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) }
    }
    var retiringAuthenticationLoss: Bool { lock.withLock { authenticationLossEpoch != nil } }
    func captureRetirementOwners(_ owners: [String: SelectiveRemotePublicationPayloadStamp]) throws {
        try check(); lock.withLock { retirementOwners = owners }; try check()
    }
    func capturedRetirementOwner(scope: SelectiveRemotePublicationScope) -> SelectiveRemotePublicationPayloadStamp? { lock.withLock { retirementOwners[scope.key] } }
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

extension SelectiveRemoteCloudAPIClient: SelectiveRemoteVaultPublicationRemote {
    func publicationRead(scope: SelectiveRemotePublicationScope, route: String, generation: String? = nil, hash: String? = nil, cursor: String? = nil) async throws -> SelectiveRemoteJSONValue {
        var query: [URLQueryItem] = []
        if let generation { query.append(.init(name: "generationID", value: generation)) }
        if let hash { query.append(.init(name: "headerHash", value: hash)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let (data, response) = try await authorizedResponse(endpoint: scope.endpoint,
            path: "v1/teams/\(scope.teamID.canonicalCloudString)/vaults/\(scope.vaultID.canonicalCloudString)/publication/\(route)", queryItems: query)
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
    func publicationSession(endpoint: URL, deviceID: UUID) async throws -> SelectiveRemotePublicationSession? {
        guard let token = try tokenStore.token(for: endpoint) else { throw SelectiveRemoteCloudError.authenticationRequired }
        let epoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        let id: UUID
        do { id = try await currentUser(endpoint: endpoint).id }
        catch {
            guard SelectiveRemoteVaultPublicationCoordinator.transient(error),
                  let data = try tokenStore.publicationAccountBinding(key: publicationAccountBindingKey(endpoint: endpoint, token: token)),
                  let binding = try? JSONDecoder().decode(AccountBinding.self, from: data),
                  binding.tokenHash == SHA256.hash(data: Data(token.utf8)).map({ String(format: "%02x", $0) }).joined()
            else { throw error }
            id = binding.accountID
        }
        guard try tokenStore.token(for: endpoint) == token, SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) == epoch else { throw CancellationError() }
        return .init(endpoint: endpoint, accountID: id, deviceID: deviceID, token: token, tokenStore: tokenStore, checkConfiguration: UserDefaults.standard.string(forKey: "SelectiveRemote.cloud.endpoint.v1").flatMap({ try? SelectiveRemoteCloudEndpoint.normalized($0) }) == endpoint)
    }
}

extension SelectiveRemoteCloudAPIClient {
    func preparePublicationRetirement(session: SelectiveRemotePublicationSession) async throws {
        try SelectiveRemoteVaultPublicationStore().captureRetirementOwners(session: session)
    }
    func retirePublications(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) async throws {
        do {
            _ = try SelectiveRemoteVaultPublicationStore().retireScopes(session: session, selection: selection)
            try session.checkRetirement()
        } catch {
            await detachRetiredPublications(session: session, selection: selection)
            throw error
        }
        await detachRetiredPublications(session: session, selection: selection)
    }
    private func detachRetiredPublications(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) async {
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
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: scope, session: session, remote: self, identity: identity, store: try SelectiveRemoteVaultPublicationStore())
        do {
            let cache = offline ? try await reader.offline() : try await reader.load(teamName: team.name, vaultName: vault.name, role: team.role)
            try session.check()
            try await MainActor.run { try SelectiveRemotePublicationPresentation.shared.bind(reader: reader, session: session, scope: scope) }
            try session.check()
            return try cache.materializedSnapshot()
        } catch let challenge as SelectiveRemotePublisherVerification {
            try session.check()
            await MainActor.run { SelectiveRemotePublisherVerificationSheet.present(challenge: challenge, reader: reader, session: session) }
            throw challenge
        }
    }
    func reopenPublications(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity) async throws -> [SelectiveRemoteTeamVaultMaterializedSnapshot] {
        let store = try SelectiveRemoteVaultPublicationStore()
        var snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot] = []
        for scope in try store.cachedScopes(session: session) {
            try session.check()
            let reader = SelectiveRemoteVaultPublicationCoordinator(scope: scope, session: session, remote: self, identity: identity, store: store)
            if let cache = try? await reader.offline() {
                try session.check()
                try await MainActor.run { try SelectiveRemotePublicationPresentation.shared.bind(reader: reader, session: session, scope: scope) }
                snapshots.append(try cache.materializedSnapshot())
            }
        }
        try session.check()
        return snapshots
    }
}
