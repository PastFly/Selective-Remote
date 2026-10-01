import CryptoKit
import Foundation

protocol SelectiveRemotePublicationProtectedStorage: Sendable {
    func read(_ key: String) throws -> Data?
    func save(_ data: Data, key: String) throws
}
struct SelectiveRemotePublicationKeychainStorage: SelectiveRemotePublicationProtectedStorage {
    func read(_ key: String) throws -> Data? { try UnifiedCredentialVault.shared.readProtectedData(namespace: "vault-publication.v1", key: key) }
    func save(_ data: Data, key: String) throws { try UnifiedCredentialVault.shared.saveProtectedData(data, namespace: "vault-publication.v1", key: key) }
}
final class SelectiveRemoteVaultPublicationStore: @unchecked Sendable {
    private static let lock = NSLock()
    private let directory: URL
    private let protected: any SelectiveRemotePublicationProtectedStorage
    init(directory: URL? = nil, protected: any SelectiveRemotePublicationProtectedStorage = SelectiveRemotePublicationKeychainStorage()) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SelectiveRemote/PublicationCache")
        self.protected = protected
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private struct Receipt: Codable { var scope: SelectiveRemotePublicationScope; var key: Data; var highWater: SelectiveRemotePublicationHighWater?; var file: String?; var owner: UUID?; var generation: String?; var authorization: String? }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func receiptKey(_ scope: SelectiveRemotePublicationScope) -> String { "receipt/" + digest(scope.key) }
    private func receipt(_ scope: SelectiveRemotePublicationScope) throws -> Receipt? {
        guard let data = try protected.read(receiptKey(scope)) else { return nil }
        let result = try JSONDecoder().decode(Receipt.self, from: data)
        guard result.scope == scope, result.key.count == 32 else { throw SelectiveRemotePublicationError.scope }
        return result
    }
    func highWater(scope: SelectiveRemotePublicationScope) throws -> SelectiveRemotePublicationHighWater? {
        try Self.lock.withLock { try receipt(scope)?.highWater }
    }
    func commit(_ cache: SelectiveRemotePublicationCache, expected: SelectiveRemotePublicationHighWater?, session: SelectiveRemotePublicationSession) throws {
        try Self.lock.withLock {
            try checkScope(cache.scope, session: session)
            var state = try receipt(cache.scope) ?? Receipt(scope: cache.scope, key: SelectiveRemoteResourceCryptoV2.generateCEK(), highWater: nil, file: nil, owner: nil, generation: nil, authorization: nil)
            guard state.highWater == expected else { throw SelectiveRemotePublicationError.fork }
            let header = try SelectiveRemoteVaultPublicationV1.headerPayload(cache.header)
            let next = SelectiveRemotePublicationHighWater(sequence: try header["sequence"]!.publicationInteger(), hash: cache.headerHash)
            guard next.hash == (try SelectiveRemoteVaultPublicationV1.hash("header", cache.header)) else { throw SelectiveRemotePublicationError.scope }
            if let old = state.highWater {
                guard next.sequence >= old.sequence else { throw SelectiveRemotePublicationError.rollback }
                guard next.sequence != old.sequence || next.hash == old.hash else { throw SelectiveRemotePublicationError.fork }
            }
            let generation = try header["generationID"]!.publicationString()
            let aad = Data((cache.scope.key + "\n" + generation + "\n" + String(next.sequence) + "\n" + next.hash).utf8)
            var plaintext = try JSONEncoder().encode(cache)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: state.key), authenticating: aad)
            let filename = digest(cache.scope.key) + "-" + UUID().uuidString + ".sealed"
            let path = directory.appending(path: filename)
            let oldFile = state.file
            var receiptCommitted = false
            do {
                try session.check()
                try box.combined!.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                try session.check()
                state.highWater = next; state.file = filename; state.owner = session.id; state.generation = generation; state.authorization = session.authorizationStamp
                try protected.save(JSONEncoder().encode(state), key: receiptKey(cache.scope))
                receiptCommitted = true
                let catalogKey = catalogKey(session)
                var scopes = try protected.read(catalogKey).map { try JSONDecoder().decode([SelectiveRemotePublicationScope].self, from: $0) } ?? []
                if !scopes.contains(cache.scope) { scopes.append(cache.scope) }
                try session.check(); try protected.save(JSONEncoder().encode(scopes), key: catalogKey)
                try session.check()
                if let oldFile { try? FileManager.default.removeItem(at: directory.appending(path: oldFile)) }
            } catch {
                try? FileManager.default.removeItem(at: path)
                // If receipt committed, high-water remains advanced even when session invalidates.
                if receiptCommitted { state.file = nil; try? protected.save(JSONEncoder().encode(state), key: receiptKey(cache.scope)) }
                throw error
            }
        }
    }
    private func checkScope(_ scope: SelectiveRemotePublicationScope, session: SelectiveRemotePublicationSession) throws {
        try session.check()
        guard scope.endpoint == session.endpoint, scope.accountID == session.accountID, scope.deviceID == session.deviceID else { throw SelectiveRemotePublicationError.scope }
    }
    func load(scope: SelectiveRemotePublicationScope, session: SelectiveRemotePublicationSession) throws -> SelectiveRemotePublicationCache? {
        try Self.lock.withLock {
            try checkScope(scope, session: session)
            guard let state = try receipt(scope), let highWater = state.highWater, let generation = state.generation, let file = state.file else { return nil }
            guard !file.contains("/"), !file.contains("..") else { throw SelectiveRemotePublicationError.invalid }
            let path = directory.appending(path: file)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let aad = Data((scope.key + "\n" + generation + "\n" + String(highWater.sequence) + "\n" + highWater.hash).utf8)
            let sealed = try Data(contentsOf: path)
            guard sealed.count <= 128 * 1024 * 1024 else { throw SelectiveRemotePublicationError.invalid }
            var bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: state.key), authenticating: aad)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            let cache = try JSONDecoder().decode(SelectiveRemotePublicationCache.self, from: bytes)
            guard cache.scope == scope, cache.headerHash == highWater.hash,
                  try SelectiveRemoteVaultPublicationV1.headerPayload(cache.header)["sequence"]!.publicationInteger() == highWater.sequence else { throw SelectiveRemotePublicationError.scope }
            try session.check()
            return cache
        }
    }
    func removePayload(scope: SelectiveRemotePublicationScope, session: SelectiveRemotePublicationSession? = nil, expectedStamp: SelectiveRemotePublicationPayloadStamp? = nil) throws {
        try Self.lock.withLock {
            guard var state = try receipt(scope) else { return }
            if let expectedStamp { guard state.owner == expectedStamp.owner else { return } }
            else if let session, (try? session.check()) == nil, state.owner != session.id { return }
            try retirePayload(scope: scope, state: &state)
            let key = catalogKey(scope)
            if let data = try protected.read(key) {
                let scopes = try JSONDecoder().decode([SelectiveRemotePublicationScope].self, from: data)
                try protected.save(JSONEncoder().encode(scopes.filter { $0 != scope }), key: key)
            }
        }
    }
    private func retirePayload(scope: SelectiveRemotePublicationScope, state: inout Receipt) throws {
        if let file = state.file {
            guard !file.contains("/"), !file.contains("..") else { throw SelectiveRemotePublicationError.invalid }
            let path = directory.appending(path: file)
            // Delete payload before updating its receipt: a rejected protected write must not resurrect known-revoked data.
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        state.file = nil
        try protected.save(JSONEncoder().encode(state), key: receiptKey(scope))
    }
    func retireScopes(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) throws -> [SelectiveRemotePublicationScope] {
        try Self.lock.withLock {
            try session.checkRetirement()
            let key = catalogKey(session)
            let scopes = try protected.read(key).map { try JSONDecoder().decode([SelectiveRemotePublicationScope].self, from: $0) } ?? []
            for scope in scopes {
                guard scope.endpoint == session.endpoint, scope.accountID == session.accountID, scope.deviceID == session.deviceID else { throw SelectiveRemotePublicationError.scope }
            }
            var retired: [SelectiveRemotePublicationScope] = []
            for scope in scopes where selection.matches(scope) {
                try session.checkRetirement()
                if var state = try receipt(scope) {
                    // A current 401 can retire previous cycles of this authorization, never a newer login's receipt.
                    if session.retiringAuthenticationLoss, let authorization = state.authorization, authorization != session.authorizationStamp { continue }
                    try retirePayload(scope: scope, state: &state)
                }
                retired.append(scope)
            }
            guard !retired.isEmpty else { return [] }
            try session.checkRetirement()
            try protected.save(JSONEncoder().encode(scopes.filter { !retired.contains($0) }), key: key)
            try session.checkRetirement()
            return retired
        }
    }
    func payloadStamp(scope: SelectiveRemotePublicationScope) throws -> SelectiveRemotePublicationPayloadStamp {
        try Self.lock.withLock { .init(owner: try receipt(scope)?.owner) }
    }
    private func catalogKey(_ session: SelectiveRemotePublicationSession) -> String {
        "catalog/" + digest(session.endpoint.absoluteString + "\n" + session.accountID.canonicalCloudString + "\n" + session.deviceID.canonicalCloudString)
    }
    private func catalogKey(_ scope: SelectiveRemotePublicationScope) -> String {
        "catalog/" + digest(scope.endpoint.absoluteString + "\n" + scope.accountID.canonicalCloudString + "\n" + scope.deviceID.canonicalCloudString)
    }
    func cachedScopes(session: SelectiveRemotePublicationSession) throws -> [SelectiveRemotePublicationScope] {
        try Self.lock.withLock {
            try session.check()
            let scopes = try protected.read(catalogKey(session)).map { try JSONDecoder().decode([SelectiveRemotePublicationScope].self, from: $0) } ?? []
            guard scopes.count <= 100 else { throw SelectiveRemotePublicationError.invalid }
            for scope in scopes { try checkScope(scope, session: session) }
            return scopes
        }
    }
    private func pinKey(endpoint: URL, teamID: UUID, accountID: UUID) -> String { "publisher/" + digest(endpoint.absoluteString + "\n" + teamID.canonicalCloudString + "\n" + accountID.canonicalCloudString) }
    func publisherPin(endpoint: URL, teamID: UUID, accountID: UUID) throws -> SelectiveRemoteDeviceTrustPin? {
        try Self.lock.withLock { try protected.read(pinKey(endpoint: endpoint, teamID: teamID, accountID: accountID)).map { try JSONDecoder().decode(SelectiveRemoteDeviceTrustPin.self, from: $0) } }
    }
    func savePublisherPin(_ pin: SelectiveRemoteDeviceTrustPin, expected: SelectiveRemoteDeviceTrustPin?, scope: SelectiveRemotePublicationScope, session: SelectiveRemotePublicationSession) throws {
        try Self.lock.withLock {
            try checkScope(scope, session: session)
            let key = pinKey(endpoint: scope.endpoint, teamID: scope.teamID, accountID: pin.accountID)
            let old = try protected.read(key).map { try JSONDecoder().decode(SelectiveRemoteDeviceTrustPin.self, from: $0) }
            guard old == expected else { throw SelectiveRemoteDeviceTrustError.staleDirectory }
            if let old { guard old.accountID == pin.accountID, old.rootFingerprint == pin.rootFingerprint, pin.highWater >= old.highWater,
                pin.highWater != old.highWater || pin.checkpointDigest == old.checkpointDigest else { throw SelectiveRemoteDeviceTrustError.untrustedRoot } }
            try session.check()
            try protected.save(JSONEncoder().encode(pin), key: key)
            try session.check()
        }
    }
}

struct SelectiveRemotePublicationPayloadStamp: Equatable, Sendable { let owner: UUID? }
