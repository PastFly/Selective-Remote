import CryptoKit
import Foundation

enum SelectiveRemoteWholePublicationError: Error, Equatable {
    case invalid, scope, incompletePreview, custodianUnavailable, recipientTrustUnverified
    case checkpointUnavailable, replayConflict, limit, operationInProgress, readbackRequired
}
extension SelectiveRemoteWholePublicationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .custodianUnavailable: CloudAccessLocalization.text("Для публикации нужен доступный доверенный хранитель с ключами всех частей и служебных данных.", "Publication requires an available trusted custodian with keys for every part and administrative data.")
        case .recipientTrustUnverified: CloudAccessLocalization.text("Сначала независимо проверьте ключ получателя или издателя.", "Independently verify the recipient or publisher key first.")
        case .checkpointUnavailable: CloudAccessLocalization.text("Защищённое состояние подготовки недоступно. Требуется новая операция с новыми ключами.", "Protected preparation state is unavailable. A new operation with fresh keys is required.")
        case .readbackRequired: CloudAccessLocalization.text("Результат публикации ещё проверяется. Новые изменения команды заблокированы до подтверждения сохранённого результата.", "The publication result is still being verified. New Team changes are blocked until the saved result is confirmed.")
        case .limit: CloudAccessLocalization.text("Превышен допустимый размер полной публикации команды.", "The complete Team publication exceeds supported limits.")
        case .operationInProgress: CloudAccessLocalization.text("Дождитесь текущей операции публикации.", "Wait for the current publication operation.")
        default: CloudAccessLocalization.text("Данные публикации изменились или не прошли проверку. Обновите данные и подготовьте новый просмотр изменений.", "Publication data changed or failed verification. Refresh and prepare a new preview.")
        }
    }
}

struct SelectiveRemoteWholePublicationScope: Codable, Equatable, Sendable {
    let endpoint: URL
    let accountID: UUID
    let deviceID: UUID
    let teamID: UUID
    let operationID: UUID
    let authorization: String
    init(session: SelectiveRemotePublicationSession, teamID: UUID, operationID: UUID) {
        endpoint = session.endpoint; accountID = session.accountID; deviceID = session.deviceID
        self.teamID = teamID; self.operationID = operationID; authorization = session.authorizationStamp
    }
    var key: String { [endpoint.absoluteString, accountID.canonicalCloudString, deviceID.canonicalCloudString,
        teamID.canonicalCloudString, operationID.canonicalCloudString].joined(separator: "\n") }
    func check(_ session: SelectiveRemotePublicationSession) throws {
        try session.check()
        guard endpoint == session.endpoint, accountID == session.accountID, deviceID == session.deviceID,
              authorization == session.authorizationStamp else { throw SelectiveRemoteWholePublicationError.scope }
    }
}

/// A fresh operation key is held only by the existing device Keychain envelope. The disk file contains sealed immutable bytes.
final class SelectiveRemoteWholePublicationCheckpointStore: @unchecked Sendable {
    private static let lock = NSLock()
    private let directory: URL
    private let protected: any SelectiveRemotePublicationProtectedStorage
    private struct Protection: Codable {
        let scope: SelectiveRemoteWholePublicationScope
        let key: Data
        let generationsHash: String
        let planHash: String
        var file: String?
        var pendingCommit = false
        var receipt: SelectiveRemoteJSONValue?
        var readbackComplete = false
        var discarded: Bool?
    }
    private struct WriteFence: Codable { let endpoint: URL; let accountID: UUID; let deviceID: UUID; let teamID: UUID; var operationID: UUID? }
    init(directory: URL? = nil, protected: any SelectiveRemotePublicationProtectedStorage = SelectiveRemotePublicationKeychainStorage()) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SelectiveRemote/WholePublication")
        self.protected = protected
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func key(_ scope: SelectiveRemoteWholePublicationScope) -> String { "whole-operation/" + SelectiveRemoteWholePublicationWire.digest(Data(scope.key.utf8)) }
    private func fenceKey(_ scope: SelectiveRemoteWholePublicationScope) -> String {
        "whole-write-fence/" + SelectiveRemoteWholePublicationWire.digest(Data([scope.endpoint.absoluteString, scope.accountID.canonicalCloudString, scope.deviceID.canonicalCloudString, scope.teamID.canonicalCloudString].joined(separator: "\n").utf8))
    }
    func pendingOperation(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession) throws -> UUID? {
        try Self.lock.withLock { try pendingUnlocked(scope: scope, session: session) }
    }
    private func pendingUnlocked(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession) throws -> UUID? {
        try scope.check(session)
        guard let bytes = try protected.read(fenceKey(scope)) else { return nil }
        let fence = try JSONDecoder().decode(WriteFence.self, from: bytes)
        guard fence.endpoint == scope.endpoint, fence.accountID == scope.accountID, fence.deviceID == scope.deviceID, fence.teamID == scope.teamID else { throw SelectiveRemoteWholePublicationError.scope }
        try scope.check(session); return fence.operationID
    }
    private func state(_ scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession, receiptRecovery: Bool = false) throws -> Protection? {
        try scope.check(session)
        guard let bytes = try protected.read(key(scope)) else { return nil }
        let state = try JSONDecoder().decode(Protection.self, from: bytes)
        guard state.scope.key == scope.key, receiptRecovery || state.scope == scope, state.key.count == 32 else { throw SelectiveRemoteWholePublicationError.scope }
        try scope.check(session); return state
    }
    private func aad(_ state: Protection) -> Data { Data((state.scope.key + "\n" + state.scope.authorization + "\n" + state.generationsHash + "\n" + state.planHash).utf8) }
    func persist(_ bytes: Data, scope: SelectiveRemoteWholePublicationScope, generationsHash: String, session: SelectiveRemotePublicationSession) throws {
        try Self.lock.withLock {
            try scope.check(session)
            guard bytes.count <= 48 * 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
            if let prior = try state(scope, session: session) {
                guard prior.generationsHash == generationsHash, prior.planHash == SelectiveRemoteWholePublicationWire.digest(bytes), prior.file != nil else { throw SelectiveRemoteWholePublicationError.replayConflict }
                guard try loadUnlocked(scope: scope, generationsHash: generationsHash, session: session) == bytes else { throw SelectiveRemoteWholePublicationError.replayConflict }; return
            }
            var state = Protection(scope: scope, key: SelectiveRemoteResourceCryptoV2.generateCEK(), generationsHash: generationsHash,
                planHash: SelectiveRemoteWholePublicationWire.digest(bytes), file: nil)
            try protected.save(JSONEncoder().encode(state), key: key(scope)); try scope.check(session)
            let box = try AES.GCM.seal(bytes, using: SymmetricKey(data: state.key), authenticating: aad(state))
            guard let combined = box.combined else { throw SelectiveRemoteWholePublicationError.invalid }
            let wire = SelectiveRemoteJSONValue.object(["version": .number(1), "nonce": .string(Data(box.nonce).selectiveRemoteBase64URL),
                "ciphertext": .string((box.ciphertext + box.tag).selectiveRemoteBase64URL)])
            guard try SelectiveRemoteWholePublicationWire.bytes(wire).count <= 64 * 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
            let filename = UUID().uuidString + ".sealed", path = directory.appending(path: filename)
            do {
                try scope.check(session); try combined.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                try scope.check(session); state.file = filename
                try protected.save(JSONEncoder().encode(state), key: key(scope)); try scope.check(session)
            } catch { try? FileManager.default.removeItem(at: path); throw error }
        }
    }
    private func loadUnlocked(scope: SelectiveRemoteWholePublicationScope, generationsHash: String?, session: SelectiveRemotePublicationSession, receiptRecovery: Bool = false) throws -> Data? {
        guard let state = try state(scope, session: session, receiptRecovery: receiptRecovery) else { return nil }
        guard generationsHash == nil || state.generationsHash == generationsHash,
              let file = state.file, !file.contains("/"), !file.contains("..") else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
        let path = directory.appending(path: file)
        guard FileManager.default.fileExists(atPath: path.path) else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
        let sealed = try Data(contentsOf: path)
        guard sealed.count <= 48 * 1024 * 1024 + 28 else { throw SelectiveRemoteWholePublicationError.limit }
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: state.key), authenticating: aad(state))
        guard SelectiveRemoteWholePublicationWire.digest(bytes) == state.planHash else { throw SelectiveRemoteWholePublicationError.replayConflict }
        try scope.check(session); return bytes
    }
    func load(scope: SelectiveRemoteWholePublicationScope, generationsHash: String? = nil, session: SelectiveRemotePublicationSession) throws -> Data? {
        try Self.lock.withLock { try loadUnlocked(scope: scope, generationsHash: generationsHash, session: session) }
    }
    /// Renewal recovery exposes the immutable ciphertext/signature plan only. Preparation/upload still requires the original authorization.
    func loadForReceipt(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession) throws -> Data? {
        try Self.lock.withLock { try loadUnlocked(scope: scope, generationsHash: nil, session: session, receiptRecovery: true) }
    }
    func checkpoint(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession) throws -> SelectiveRemoteJSONValue {
        try Self.lock.withLock {
            guard let state = try state(scope, session: session), let file = state.file else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
            _ = try loadUnlocked(scope: scope, generationsHash: nil, session: session)
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: directory.appending(path: file)))
            return .object(["version": .number(1), "nonce": .string(Data(box.nonce).selectiveRemoteBase64URL), "ciphertext": .string((box.ciphertext + box.tag).selectiveRemoteBase64URL)])
        }
    }
    func commitState(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession, receiptRecovery: Bool = false) throws -> (pending: Bool, receipt: SelectiveRemoteJSONValue?, complete: Bool, discarded: Bool) {
        try Self.lock.withLock { let value = try state(scope, session: session, receiptRecovery: receiptRecovery); return (value?.pendingCommit ?? false, value?.receipt, value?.readbackComplete ?? false, value?.discarded ?? false) }
    }
    func recordCommit(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession, receipt: SelectiveRemoteJSONValue? = nil, complete: Bool = false, receiptRecovery: Bool = false) throws {
        try Self.lock.withLock {
            if let pending = try pendingUnlocked(scope: scope, session: session), pending != scope.operationID { throw SelectiveRemoteWholePublicationError.readbackRequired }
            guard !receiptRecovery || receipt != nil, var state = try state(scope, session: session, receiptRecovery: receiptRecovery), state.file != nil, state.discarded != true else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
            if let prior = state.receipt, let receipt, prior != receipt { throw SelectiveRemoteWholePublicationError.replayConflict }
            state.pendingCommit = true; if let receipt { state.receipt = receipt }; state.readbackComplete = complete
            try scope.check(session); try protected.save(JSONEncoder().encode(state), key: key(scope)); try scope.check(session)
            let fence = WriteFence(endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID, teamID: scope.teamID, operationID: complete ? nil : scope.operationID)
            try protected.save(JSONEncoder().encode(fence), key: fenceKey(scope)); try scope.check(session)
        }
    }
    func recordPreparing(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession) throws {
        try Self.lock.withLock {
            if let pending = try pendingUnlocked(scope: scope, session: session), pending != scope.operationID { throw SelectiveRemoteWholePublicationError.readbackRequired }
            guard let state = try state(scope, session: session), state.file != nil, !state.pendingCommit, state.discarded != true else { throw SelectiveRemoteWholePublicationError.readbackRequired }
            let fence = WriteFence(endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID, teamID: scope.teamID, operationID: scope.operationID)
            try scope.check(session); try protected.save(JSONEncoder().encode(fence), key: fenceKey(scope)); try scope.check(session)
        }
    }
    func recordDiscard(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession, receiptRecovery: Bool = false) throws {
        try Self.lock.withLock {
            guard let pending = try pendingUnlocked(scope: scope, session: session), pending == scope.operationID,
                  var state = try state(scope, session: session, receiptRecovery: receiptRecovery), state.receipt == nil, !state.readbackComplete else { throw SelectiveRemoteWholePublicationError.readbackRequired }
            state.pendingCommit = false; state.discarded = true
            try scope.check(session); try protected.save(JSONEncoder().encode(state), key: key(scope)); try scope.check(session)
            let fence = WriteFence(endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID, teamID: scope.teamID, operationID: nil)
            try protected.save(JSONEncoder().encode(fence), key: fenceKey(scope)); try scope.check(session)
        }
    }
}

enum SelectiveRemoteWholePublicationWire {
    static func bytes(_ value: SelectiveRemoteJSONValue) throws -> Data { Data(try SelectiveRemoteVaultPublicationV1.canonical(value).utf8) }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ value: SelectiveRemoteJSONValue) throws -> String { digest(try bytes(value)) }
    /// The actual POST container and hash belong to the part budget. Base64url ciphertext has ceil(4*n/3) bytes without padding.
    static func encodedPartBudget(context: SelectiveRemoteResourceCipherContext, plaintextBytes: Int, wrapperContexts: [SelectiveRemoteResourceWrapperContext], includeHash: Bool) throws -> Int {
        guard plaintextBytes >= 0, plaintextBytes <= 24 * 1024 * 1024, !wrapperContexts.isEmpty, wrapperContexts.count <= 10000 else { throw SelectiveRemoteWholePublicationError.limit }
        _ = try SelectiveRemoteResourceCryptoV2.ciphertextAAD(context)
        let envelope: SelectiveRemoteJSONValue = .object(["formatVersion": .number(2), "algorithm": .string("AES-256-GCM"), "aadVersion": .number(2), "context": try json(context),
            "nonce": .string(String(repeating: "A", count: 16)), "ciphertext": .string(""), "authTag": .string(String(repeating: "A", count: 22))])
        let wrappers = try wrapperContexts.map { w -> SelectiveRemoteJSONValue in
            _ = try SelectiveRemoteResourceCryptoV2.wrapperAAD(w)
            guard w.teamID == context.teamID, w.vaultID == context.vaultID, w.resourceID == context.resourceID, w.part == context.part, w.keyVersion == context.keyVersion else { throw SelectiveRemoteWholePublicationError.scope }
            let point: SelectiveRemoteJSONValue = .object(["kty": .string("EC"), "crv": .string("P-256"), "x": .string(String(repeating: "A", count: 43)), "y": .string(String(repeating: "A", count: 43)), "ext": .boolean(true), "key_ops": .array([])])
            return .object(["wrapperVersion": .number(2), "algorithm": .string("P256-ECDH-HKDF-SHA256-AES-256-GCM"), "aadVersion": .number(2), "context": try json(w), "ephemeralPublicKey": point,
                "nonce": .string(String(repeating: "A", count: 16)), "ciphertext": .string(String(repeating: "A", count: 43)), "authTag": .string(String(repeating: "A", count: 22))])
        }
        var object: [String: SelectiveRemoteJSONValue] = ["resourceID": .string(context.resourceID.canonicalCloudString), "part": .string(context.part.rawValue), "envelope": envelope, "wrappers": .array(wrappers)]
        if includeHash { object["sha256"] = .string(String(repeating: "0", count: 64)) }
        let wire: SelectiveRemoteJSONValue = includeHash ? .object(["object": .object(object)]) : .object(object)
        return try bytes(wire).count + (plaintextBytes * 4 + 2) / 3
    }
    static func projectionChunk(_ data: Data, index: Int, count: Int, sha256: String) throws -> SelectiveRemoteJSONValue {
        guard !data.isEmpty, data.count <= 512 * 1024, (1...256).contains(count), index >= 0, index < count,
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SelectiveRemoteWholePublicationError.limit }
        let body: SelectiveRemoteJSONValue = .object(["version": .number(1), "index": .number(Double(index)), "count": .number(Double(count)), "sha256": .string(sha256), "data": .string(data.selectiveRemoteBase64URL)])
        guard try bytes(body).count <= 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }; return body
    }
    static func json<T: Encodable>(_ value: T) throws -> SelectiveRemoteJSONValue {
        func ids(_ value: SelectiveRemoteJSONValue) -> SelectiveRemoteJSONValue {
            switch value { case let .string(s): return UUID(uuidString: s).map { .string($0.canonicalCloudString) } ?? value
            case let .object(o): return .object(o.mapValues(ids)); case let .array(a): return .array(a.map(ids)); default: return value }
        }
        return ids(try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: JSONEncoder().encode(value)))
    }
    static func id(_ value: SelectiveRemoteJSONValue) throws -> UUID {
        let text = try value.publicationString()
        guard let id = UUID(uuidString: text), id.isSelectiveRemoteCloudUUID, id.canonicalCloudString == text else { throw SelectiveRemoteWholePublicationError.invalid }; return id
    }
    static func migrationBytes(_ value: SelectiveRemoteJSONValue) throws -> Data { Data("selective-remote/vault-migration/v2\0".utf8) + (try bytes(value)) }
    static func signed(_ value: SelectiveRemoteJSONValue, purpose: String?, root: P256.Signing.PrivateKey) throws -> SelectiveRemoteJSONValue {
        let data = try purpose.map { try SelectiveRemoteVaultPublicationV1.bytes($0, value) } ?? migrationBytes(value)
        return .object(["payload": value, "signature": .string(try root.signature(for: data).rawRepresentation.selectiveRemoteBase64URL)])
    }
    static func verifyManifest(_ manifest: SelectiveRemoteJSONValue, root: P256.Signing.PublicKey) throws -> [String: SelectiveRemoteJSONValue] {
        let signed = try manifest.publicationObject(["payload", "signature"])
        guard let raw = Data(selectiveRemoteBase64URL: try signed["signature"]!.publicationString(), expectedLength: 64),
              root.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: try migrationBytes(signed["payload"]!)) else { throw SelectiveRemotePublicationError.signature }
        let payload = try signed["payload"]!.publicationObject()
        guard payload["version"] == .number(2) else { throw SelectiveRemoteWholePublicationError.invalid }; return payload
    }
    static func canonicalRequest(_ value: SelectiveRemoteJSONValue) throws -> SelectiveRemoteJSONValue {
        var request = try value.publicationObject(["version", "teamID", "operationID", "vaults", "groupMutation"])
        var vaults = try request["vaults"]!.publicationArray().map { try $0.publicationObject(["vaultID", "resources", "policy", "contentChanges", "custodianDeviceIDs"]) }
        for i in vaults.indices {
            for field in ["resources", "policy"] {
                let rows = try vaults[i][field]!.publicationArray()
                let keyed = try rows.map { row -> (String, SelectiveRemoteJSONValue) in
                    guard let id = try row.publicationObject()["id"] else { throw SelectiveRemoteWholePublicationError.invalid }
                    return (try id.publicationString(), row)
                }
                vaults[i][field] = .array(keyed.sorted { $0.0 < $1.0 }.map(\.1))
            }
            vaults[i]["contentChanges"] = .array(try vaults[i]["contentChanges"]!.publicationArray().sorted { lhs, rhs in
                let l = try lhs.publicationObject(["resourceID", "part"]), r = try rhs.publicationObject(["resourceID", "part"])
                return try l["resourceID"]!.publicationString() + "/" + l["part"]!.publicationString() < r["resourceID"]!.publicationString() + "/" + r["part"]!.publicationString()
            })
            vaults[i]["custodianDeviceIDs"] = .array(try vaults[i]["custodianDeviceIDs"]!.publicationArray().sorted { try $0.publicationString() < $1.publicationString() })
        }
        vaults = try vaults.sorted { try $0["vaultID"]!.publicationString() < $1["vaultID"]!.publicationString() }
        request["vaults"] = .array(vaults.map(SelectiveRemoteJSONValue.object)); return .object(request)
    }
}

protocol SelectiveRemoteWholePublicationRemote: Sendable {
    func wholePublication(scope: SelectiveRemoteWholePublicationScope, route: String, body: Data?) async throws -> SelectiveRemoteJSONValue
    func wholePublicationReadback(scope: SelectiveRemoteWholePublicationScope, vaultID: UUID) async throws -> SelectiveRemoteJSONValue
}
extension SelectiveRemoteCloudAPIClient: SelectiveRemoteWholePublicationRemote {
    func wholePublication(scope: SelectiveRemoteWholePublicationScope, route: String, body: Data?) async throws -> SelectiveRemoteJSONValue {
        guard body == nil || body!.count <= 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
        let (data, response) = try await authorizedResponse(endpoint: scope.endpoint, path: "v1/teams/\(scope.teamID.canonicalCloudString)/publication/\(route)", method: body == nil ? "GET" : "POST", body: body,
            headers: ["X-Vault-Schema-Version": "2", "X-Vault-Capability": "resource_acl_v2", "X-Publication-Version": "1"])
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw SelectiveRemoteCloudError.serviceError(response.statusCode, code)
        }
        guard data.count <= 64 * 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
        return try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: data)
    }
    func wholePublicationReadback(scope: SelectiveRemoteWholePublicationScope, vaultID: UUID) async throws -> SelectiveRemoteJSONValue {
        try await wholePublication(scope: scope, route: "operations/\(scope.operationID.canonicalCloudString)/readback/\(vaultID.canonicalCloudString)", body: nil)
    }
}

struct SelectiveRemoteWholePublicationPreview: Sendable {
    let scope: SelectiveRemoteWholePublicationScope
    let token: String
    let binding: SelectiveRemoteJSONValue
    let request: SelectiveRemoteJSONValue
    let generations: [SelectiveRemoteJSONValue]
    let rows: [SelectiveRemoteJSONValue]
    var generationsHash: String { get throws { try SelectiveRemoteWholePublicationWire.hash(.array(generations)) } }
}

/// Separate ACTIVE successor coordinator. Existing PREPARING mutations and recipient readers retain their contracts.
actor SelectiveRemoteWholePublicationCoordinator {
    nonisolated let scope: SelectiveRemoteWholePublicationScope
    private let session: SelectiveRemotePublicationSession
    private let remote: any SelectiveRemoteWholePublicationRemote
    private let identity: SelectiveRemoteTeamDeviceIdentity
    private let root: P256.Signing.PrivateKey
    private let store: SelectiveRemoteWholePublicationCheckpointStore
    private let pin: @Sendable (URL, UUID, UUID) throws -> SelectiveRemoteDeviceTrustPin?
    private let advancePin: (@Sendable (URL, UUID, SelectiveRemoteDeviceTrustPin, SelectiveRemoteDeviceTrustPin) throws -> Void)?
    private var busy = false
    private var contextSessionID: UUID?
    private var contextKeyVersion: Int?
    init(scope: SelectiveRemoteWholePublicationScope, session: SelectiveRemotePublicationSession,
         remote: any SelectiveRemoteWholePublicationRemote, identity: SelectiveRemoteTeamDeviceIdentity,
         root: P256.Signing.PrivateKey, store: SelectiveRemoteWholePublicationCheckpointStore,
         pin: @escaping @Sendable (URL, UUID, UUID) throws -> SelectiveRemoteDeviceTrustPin? = { endpoint, teamID, accountID in
             try SelectiveRemoteDeviceTrustLocalStore().pin(endpoint: endpoint, accountID: accountID)
                ?? SelectiveRemoteVaultPublicationStore().publisherPin(endpoint: endpoint, teamID: teamID, accountID: accountID)
         },
         advancePin: (@Sendable (URL, UUID, SelectiveRemoteDeviceTrustPin, SelectiveRemoteDeviceTrustPin) throws -> Void)? = nil) {
        self.scope = scope; self.session = session; self.remote = remote; self.identity = identity; self.root = root; self.store = store
        self.pin = pin; self.advancePin = advancePin
    }
    private func check() throws { try scope.check(session); guard identity.deviceID == scope.deviceID else { throw SelectiveRemoteWholePublicationError.scope } }
    private func enter() throws { try check(); guard !busy else { throw SelectiveRemoteWholePublicationError.operationInProgress }; busy = true }
    private func request(_ route: String, _ body: SelectiveRemoteJSONValue?) async throws -> SelectiveRemoteJSONValue {
        try check(); let encoded = try body.map(SelectiveRemoteWholePublicationWire.bytes)
        guard encoded == nil || encoded!.count <= 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
        let result = try await remote.wholePublication(scope: scope, route: route, body: encoded)
        try check(); return result
    }
    func context() async throws -> SelectiveRemoteJSONValue {
        try enter(); defer { busy = false }
        let value = try await request("context", nil), c = try value.publicationObject()
        guard c["teamID"] == .string(scope.teamID.canonicalCloudString), c["publicationAvailable"] == .boolean(true), c["environment"] == .string("staging"),
              [SelectiveRemoteJSONValue.string("owner"), .string("admin")].contains(c["actorRole"] ?? .null), let rawSession = c["sessionID"], let rawVersion = c["actorKeyVersion"], let current = c["current"] else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        let rows = try current.publicationArray()
        guard !rows.isEmpty, rows.count <= 10 else { throw SelectiveRemoteWholePublicationError.limit }
        var ids = Set<UUID>()
        for raw in rows {
            let v = try raw.publicationObject(["teamID", "vaultID", "generationID", "sequence", "headerHash", "resources", "policy", "custodianDeviceIDs"])
            guard v["teamID"] == c["teamID"], ids.insert(try SelectiveRemoteWholePublicationWire.id(v["vaultID"]!)).inserted else { throw SelectiveRemoteWholePublicationError.scope }
            _ = try SelectiveRemoteWholePublicationWire.id(v["generationID"]!); _ = try v["sequence"]!.publicationInteger()
        }
        contextSessionID = try SelectiveRemoteWholePublicationWire.id(rawSession); contextKeyVersion = try rawVersion.publicationInteger()
        try check(); return value
    }
    func desiredRequest(context: SelectiveRemoteJSONValue, vaultOverrides: [UUID: SelectiveRemoteJSONValue] = [:], groupMutation: SelectiveRemoteJSONValue = .null) throws -> SelectiveRemoteJSONValue {
        try check(); let c = try context.publicationObject()
        guard c["teamID"] == .string(scope.teamID.canonicalCloudString), c["publicationAvailable"] == .boolean(true), c["environment"] == .string("staging"), let current = c["current"] else { throw SelectiveRemoteWholePublicationError.scope }
        let vaults = try current.publicationArray().map { raw -> SelectiveRemoteJSONValue in
            let v = try raw.publicationObject(), id = try SelectiveRemoteWholePublicationWire.id(v["vaultID"]!)
            if let override = vaultOverrides[id] {
                let o = try override.publicationObject(["vaultID", "resources", "policy", "contentChanges", "custodianDeviceIDs"])
                guard o["vaultID"] == v["vaultID"] else { throw SelectiveRemoteWholePublicationError.scope }; return override
            }
            return .object(["vaultID": v["vaultID"]!, "resources": v["resources"]!, "policy": v["policy"]!, "contentChanges": .array([]), "custodianDeviceIDs": v["custodianDeviceIDs"]!])
        }
        guard vaultOverrides.keys.allSatisfy({ id in vaults.contains { (try? $0.publicationObject()["vaultID"]) == .string(id.canonicalCloudString) } }) else { throw SelectiveRemoteWholePublicationError.scope }
        let value = try SelectiveRemoteWholePublicationWire.canonicalRequest(.object(["version": .number(1), "teamID": .string(scope.teamID.canonicalCloudString), "operationID": .string(scope.operationID.canonicalCloudString), "vaults": .array(vaults), "groupMutation": groupMutation]))
        _ = try validateRequest(value); return value
    }
    private func validateRequest(_ value: SelectiveRemoteJSONValue) throws -> [[String: SelectiveRemoteJSONValue]] {
        let r = try value.publicationObject(["version", "teamID", "operationID", "vaults", "groupMutation"])
        guard r["version"] == .number(1), r["teamID"] == .string(scope.teamID.canonicalCloudString), r["operationID"] == .string(scope.operationID.canonicalCloudString) else { throw SelectiveRemoteWholePublicationError.scope }
        let vaults = try r["vaults"]!.publicationArray().map { try $0.publicationObject(["vaultID", "resources", "policy", "contentChanges", "custodianDeviceIDs"]) }
        guard !vaults.isEmpty, vaults.count <= 10 else { throw SelectiveRemoteWholePublicationError.limit }
        var ids = Set<UUID>(), resourceIDs = Set<UUID>(), resourceCount = 0
        for v in vaults {
            guard ids.insert(try SelectiveRemoteWholePublicationWire.id(v["vaultID"]!)).inserted else { throw SelectiveRemoteWholePublicationError.invalid }
            let localResources = try v["resources"]!.publicationArray().map { try $0.publicationObject(["id", "kind", "parentFolderID", "sourceOrdinal"]) }
            var ordinals = Set<Int>()
            for r in localResources {
                guard resourceIDs.insert(try SelectiveRemoteWholePublicationWire.id(r["id"]!)).inserted,
                      ["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].contains(try r["kind"]!.publicationString()) else { throw SelectiveRemoteWholePublicationError.invalid }
                if r["parentFolderID"] != .null { _ = try SelectiveRemoteWholePublicationWire.id(r["parentFolderID"]!) }
                guard ordinals.insert(try r["sourceOrdinal"]!.publicationInteger(min: 0)).inserted else { throw SelectiveRemoteWholePublicationError.invalid }; resourceCount += 1
                var current = r["parentFolderID"]!, visited = Set<String>([try r["id"]!.publicationString()])
                while current != .null {
                    guard visited.insert(try current.publicationString()).inserted, visited.count <= 33,
                          let parent = localResources.first(where: { $0["id"] == current && $0["kind"] == .string("FOLDER") }) else { throw SelectiveRemoteWholePublicationError.invalid }
                    current = parent["parentFolderID"]!
                }
            }
            _ = try v["policy"]!.publicationArray()
            var changes = Set<String>()
            for raw in try v["contentChanges"]!.publicationArray() {
                let change = try raw.publicationObject(["resourceID", "part"])
                guard let resource = localResources.first(where: { $0["id"] == change["resourceID"] }) else { throw SelectiveRemoteWholePublicationError.invalid }
                let part = try change["part"]!.publicationString(), key = try change["resourceID"]!.publicationString() + "/" + part
                guard changes.insert(key).inserted, (resource["kind"] == .string("CREDENTIAL") ? ["METADATA", "SECRET"] : ["GENERAL"]).contains(part) else { throw SelectiveRemoteWholePublicationError.invalid }
            }
            let custodians = try v["custodianDeviceIDs"]!.publicationArray().map(SelectiveRemoteWholePublicationWire.id)
            guard !custodians.isEmpty, custodians.count <= 100, Set(custodians).count == custodians.count, custodians.contains(scope.deviceID) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        }
        guard resourceCount <= 1000 else { throw SelectiveRemoteWholePublicationError.limit }; return vaults
    }
    private func validateToken(_ token: String, binding: SelectiveRemoteJSONValue) throws {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, token.utf8.count <= 16428, let data = Data(selectiveRemoteBase64URL: String(pieces[0])),
              Data(selectiveRemoteBase64URL: String(pieces[1]), expectedLength: 32) != nil else { throw SelectiveRemoteWholePublicationError.invalid }
        let claims = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: data).publicationObject(["version", "instanceID", "issuedAt", "expiresAt", "binding"])
        guard claims["version"] == .number(1), claims["binding"] == binding,
              try claims["expiresAt"]!.publicationInteger() > Int(Date().timeIntervalSince1970 * 1000) else { throw SelectiveRemoteCloudError.serviceError(409, "preview_expired") }
    }
    func preview(request value: SelectiveRemoteJSONValue) async throws -> SelectiveRemoteWholePublicationPreview {
        try enter(); defer { busy = false }
        let value = try SelectiveRemoteWholePublicationWire.canonicalRequest(value)
        guard try !writesDisabled() else { throw SelectiveRemoteWholePublicationError.readbackRequired }
        let vaults = try validateRequest(value)
        var token: String?, binding: SelectiveRemoteJSONValue?, generations: [SelectiveRemoteJSONValue] = [], rows: [SelectiveRemoteJSONValue] = []
        var cursor: String?, seen = Set<String>()
        repeat {
            let response = try await request("preview", .object(["request": value, "token": token.map(SelectiveRemoteJSONValue.string) ?? .null, "cursor": cursor.map(SelectiveRemoteJSONValue.string) ?? .null])).publicationObject(["token", "binding", "request", "generations", "rows", "nextCursor"])
            let pageToken = try response["token"]!.publicationString(), pageGenerations = try response["generations"]!.publicationArray()
            if token == nil { token = pageToken; binding = response["binding"]; generations = pageGenerations }
            guard pageToken == token, response["binding"] == binding, response["request"] == value, pageGenerations == generations else { throw SelectiveRemoteWholePublicationError.scope }
            let pageRows = try response["rows"]!.publicationArray()
            guard pageRows.count <= 100, rows.count + pageRows.count <= 22010 else { throw SelectiveRemoteWholePublicationError.limit }; rows += pageRows
            cursor = response["nextCursor"] == .null ? nil : try response["nextCursor"]!.publicationString()
            if let cursor { guard !cursor.isEmpty, seen.insert(cursor).inserted else { throw SelectiveRemoteWholePublicationError.incompletePreview } }
        } while cursor != nil
        let b = try binding!.publicationObject(["version", "teamID", "operationID", "actorAccountID", "sessionID", "actorDeviceID", "keyVersion", "requestHash", "readSetHash", "successorHash", "policyHash", "recipientHash", "predecessors", "counts", "effectiveAt", "rowsHash", "rowCount"])
        guard b["version"] == .number(1), b["teamID"] == .string(scope.teamID.canonicalCloudString), b["operationID"] == .string(scope.operationID.canonicalCloudString), b["actorAccountID"] == .string(scope.accountID.canonicalCloudString), b["actorDeviceID"] == .string(scope.deviceID.canonicalCloudString),
              b["requestHash"] == .string(try SelectiveRemoteWholePublicationWire.hash(value)), b["rowsHash"] == .string(try SelectiveRemoteWholePublicationWire.hash(.array(rows))), try b["rowCount"]!.publicationInteger(min: 0) == rows.count else { throw SelectiveRemoteWholePublicationError.incompletePreview }
        _ = try SelectiveRemoteWholePublicationWire.id(b["sessionID"]!); _ = try b["keyVersion"]!.publicationInteger()
        if let contextSessionID { guard b["sessionID"] == .string(contextSessionID.canonicalCloudString), b["keyVersion"] == .number(Double(contextKeyVersion!)) else { throw SelectiveRemoteWholePublicationError.scope } }
        let counts = try b["counts"]!.publicationObject(["vaults", "resources", "parts", "wrappers"])
        var rowIDs = Set<String>(), partRows: [SelectiveRemoteJSONValue] = []
        for row in rows {
            let raw = try row.publicationObject(); guard let type = raw["type"] else { throw SelectiveRemoteWholePublicationError.invalid }
            if type == .string("PART") || type == .string("CUSTODY") {
                let r = try row.publicationObject(type == .string("PART") ? ["type", "vaultID", "resourceID", "part", "devices"] : ["type", "vaultID", "devices"])
                let vaultID = try SelectiveRemoteWholePublicationWire.id(r["vaultID"]!)
                guard let vault = vaults.first(where: { $0["vaultID"] == .string(vaultID.canonicalCloudString) }) else { throw SelectiveRemoteWholePublicationError.scope }
                var key = vaultID.canonicalCloudString + "/CUSTODY"
                if type == .string("PART") {
                    let resourceID = try SelectiveRemoteWholePublicationWire.id(r["resourceID"]!), part = try r["part"]!.publicationString()
                    guard let resource = try vault["resources"]!.publicationArray().first(where: { try $0.publicationObject()["id"] == .string(resourceID.canonicalCloudString) }) else { throw SelectiveRemoteWholePublicationError.scope }
                    let kind = try resource.publicationObject()["kind"]!.publicationString()
                    guard (kind == "CREDENTIAL" ? ["METADATA", "SECRET"] : ["GENERAL"]).contains(part) else { throw SelectiveRemoteWholePublicationError.invalid }
                    key = vaultID.canonicalCloudString + "/" + resourceID.canonicalCloudString + "/" + part
                }
                guard rowIDs.insert(key).inserted else { throw SelectiveRemoteWholePublicationError.incompletePreview }; _ = try r["devices"]!.publicationArray(); partRows.append(row)
            } else {
                let r = try row.publicationObject(["type", "vaultID", "membershipID", "accountID", "membershipEpoch", "resourceID", "beforeMask", "afterMask"])
                guard type == .string("DELTA") else { throw SelectiveRemoteWholePublicationError.invalid }
                for key in ["vaultID", "membershipID", "accountID", "resourceID"] { _ = try SelectiveRemoteWholePublicationWire.id(r[key]!) }
                _ = try r["membershipEpoch"]!.publicationInteger(); _ = try r["beforeMask"]!.publicationInteger(min: 0, max: 63); _ = try r["afterMask"]!.publicationInteger(min: 0, max: 63)
            }
        }
        let wrappers = try partRows.reduce(0) { try $0 + $1.publicationObject()["devices"]!.publicationArray().count }
        let resources = try vaults.reduce(0) { try $0 + $1["resources"]!.publicationArray().count }
        guard counts["vaults"] == .number(Double(vaults.count)), counts["resources"] == .number(Double(resources)), counts["parts"] == .number(Double(partRows.count)), counts["wrappers"] == .number(Double(wrappers)), wrappers <= 10000,
              generations.count == vaults.count, try b["predecessors"]!.publicationArray().count == vaults.count else { throw SelectiveRemoteWholePublicationError.incompletePreview }
        let expectedParts = try vaults.reduce(vaults.count) { count, vault in
            try count + vault["resources"]!.publicationArray().reduce(0) { n, resource in try n + (resource.publicationObject()["kind"] == .string("CREDENTIAL") ? 2 : 1) }
        }
        guard partRows.count == expectedParts else { throw SelectiveRemoteWholePublicationError.incompletePreview }
        let predecessors = try b["predecessors"]!.publicationArray().map { try $0.publicationObject(["vaultID", "generationID", "sequence", "headerHash"]) }
        var generationIDs = Set<UUID>(), generationVaults = Set<UUID>(), verifiedDevices: [String: Target] = [:]
        for raw in generations {
            let g = try raw.publicationObject(["vaultID", "generationID", "sequence", "previousHash", "scope", "snapshot"])
            let vaultID = try SelectiveRemoteWholePublicationWire.id(g["vaultID"]!), generationID = try SelectiveRemoteWholePublicationWire.id(g["generationID"]!), sequence = try g["sequence"]!.publicationInteger(min: 2)
            guard generationVaults.insert(vaultID).inserted, generationIDs.insert(generationID).inserted,
                  let prior = predecessors.first(where: { $0["vaultID"] == g["vaultID"] }), let vault = vaults.first(where: { $0["vaultID"] == g["vaultID"] }),
                  sequence == (try prior["sequence"]!.publicationInteger()) + 1, g["previousHash"] == prior["headerHash"], g["generationID"] != prior["generationID"] else { throw SelectiveRemoteWholePublicationError.scope }
            let gs = try g["scope"]!.publicationObject(["teamID", "vaultID", "attemptID", "sourceRevision", "sourceHash", "snapshotHash", "policyVersion"]), snapshot = try g["snapshot"]!.publicationObject()
            guard gs["teamID"] == b["teamID"], gs["vaultID"] == g["vaultID"], gs["attemptID"] == g["generationID"], snapshot["teamID"] == b["teamID"], snapshot["vaultID"] == g["vaultID"], let devicesJSON = snapshot["devices"] else { throw SelectiveRemoteWholePublicationError.scope }
            _ = try gs["sourceRevision"]!.publicationInteger(); _ = try gs["policyVersion"]!.publicationInteger()
            let devices = try devicesJSON.publicationArray()
            for rawRow in partRows where try rawRow.publicationObject()["vaultID"] == g["vaultID"] {
                let row = try rawRow.publicationObject(), rowDevices = try row["devices"]!.publicationArray()
                var ids = Set<UUID>(), own: Target?
                for device in rowDevices {
                    guard devices.contains(device) else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
                    let cacheKey = vaultID.canonicalCloudString + "/" + (try SelectiveRemoteWholePublicationWire.hash(device))
                    let target: Target
                    if let cached = verifiedDevices[cacheKey] { target = cached }
                    else { target = try trustedTarget(device, vaultID: vaultID); verifiedDevices[cacheKey] = target }
                    guard ids.insert(target.deviceID).inserted else { throw SelectiveRemoteWholePublicationError.incompletePreview }
                    if target.accountID == scope.accountID && target.deviceID == scope.deviceID { own = target }
                }
                guard let own, own.keyVersion == (try b["keyVersion"]!.publicationInteger()) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
                if row["type"] == .string("CUSTODY") { guard ids == Set(try vault["custodianDeviceIDs"]!.publicationArray().map(SelectiveRemoteWholePublicationWire.id)) else { throw SelectiveRemoteWholePublicationError.scope } }
            }
        }
        try validateToken(token!, binding: binding!); try check()
        return .init(scope: scope, token: token!, binding: binding!, request: value, generations: generations, rows: rows)
    }
    private struct Target {
        let accountID: UUID; let deviceID: UUID; let membershipID: UUID; let epoch: Int; let keyVersion: Int
        let publicKey: SelectiveRemoteTeamDevicePublicKey
        var recipientKey: String { membershipID.canonicalCloudString + "/" + deviceID.canonicalCloudString }
    }
    private func trustedTarget(_ value: SelectiveRemoteJSONValue, vaultID: UUID) throws -> Target {
        try check()
        let t = try value.publicationObject()
        guard let rawAccount = t["accountID"], let rawDevice = t["deviceID"], let rawMembership = t["membershipID"], let rawEpoch = t["membershipEpoch"],
              let certificateJSON = t["certificate"], let directoryJSON = t["checkpoint"], let rootJSON = t["rootPublicKey"], let publicJSON = t["publicKey"] else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
        let account = try SelectiveRemoteWholePublicationWire.id(rawAccount), device = try SelectiveRemoteWholePublicationWire.id(rawDevice), membership = try SelectiveRemoteWholePublicationWire.id(rawMembership), epoch = try rawEpoch.publicationInteger()
        let certificate = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceCertificate.self, from: certificateJSON)
        let directory = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceDirectory.self, from: directoryJSON)
        guard let rootBytes = Data(selectiveRemoteBase64URL: try rootJSON.publicationString(), expectedLength: 65),
              let prior = try pin(scope.endpoint, scope.teamID, account), prior.accountID == account,
              certificate.payload.accountID == account, directory.payload.accountID == account else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
        let key = try P256.Signing.PublicKey(x963Representation: rootBytes)
        let verified = try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: key, certificate: certificate, directory: directory, pin: prior, expectedDeviceID: device)
        guard verified.publicKey == (try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteTeamDevicePublicKey.self, from: publicJSON)) else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
        if device == scope.deviceID {
            guard account == scope.accountID, verified.publicKey == identity.publicKey, rootBytes == root.publicKey.x963Representation else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        }
        let next = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: prior.rootFingerprint, highWater: verified.highWater, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        try check()
        if let advancePin { try advancePin(scope.endpoint, scope.teamID, prior, next) }
        else if try SelectiveRemoteDeviceTrustLocalStore().pin(endpoint: scope.endpoint, accountID: account) != nil {
            try SelectiveRemoteDeviceTrustLocalStore().advance(endpoint: scope.endpoint, expected: prior, next: next)
        } else {
            try SelectiveRemoteVaultPublicationStore().savePublisherPin(next, expected: prior,
                scope: .init(endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID, teamID: scope.teamID, vaultID: vaultID), session: session)
        }
        try check()
        return Target(accountID: account, deviceID: device, membershipID: membership, epoch: epoch, keyVersion: certificate.payload.keyVersion, publicKey: verified.publicKey)
    }
    private func publisherRoot(_ value: SelectiveRemoteJSONValue, header: SelectiveRemoteJSONValue, vaultID: UUID) throws -> P256.Signing.PublicKey {
        let p = try value.publicationObject(), h = try SelectiveRemoteVaultPublicationV1.headerPayload(header)
        guard let accountJSON = p["accountID"], let deviceJSON = p["deviceID"], let certificateJSON = p["certificate"], let checkpointJSON = p["checkpoint"], let rootJSON = p["rootPublicKey"],
              accountJSON == h["publisherAccountID"], deviceJSON == h["publisherDeviceID"],
              let bytes = Data(selectiveRemoteBase64URL: try rootJSON.publicationString(), expectedLength: 65) else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
        let account = try SelectiveRemoteWholePublicationWire.id(accountJSON), device = try SelectiveRemoteWholePublicationWire.id(deviceJSON)
        let cert = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceCertificate.self, from: certificateJSON)
        let directory = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteSignedDeviceDirectory.self, from: checkpointJSON)
        guard let prior = try pin(scope.endpoint, scope.teamID, account), cert.payload.keyVersion == (try h["publisherKeyVersion"]!.publicationInteger()) else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
        let key = try P256.Signing.PublicKey(x963Representation: bytes)
        let verified: (publicKey: SelectiveRemoteTeamDevicePublicKey, highWater: Int)
        do { verified = try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: key, certificate: cert, directory: directory, pin: prior, expectedDeviceID: device) }
        catch SelectiveRemoteDeviceTrustError.staleDirectory {
            // An old publisher authenticates immutable predecessor signatures only. It never becomes a wrapping target or advances trust.
            guard directory.payload.version < prior.highWater, prior.accountID == account,
                  prior.rootFingerprint == SelectiveRemoteDeviceTrustV1.fingerprint(key), cert.payload.accountID == account,
                  cert.payload.deviceID == device, cert.payload.issuerFingerprint == prior.rootFingerprint,
                  directory.payload.accountID == account,
                  let certSignature = Data(selectiveRemoteBase64URL: cert.signature, expectedLength: 64),
                  let directorySignature = Data(selectiveRemoteBase64URL: directory.signature, expectedLength: 64) else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
            let certificateBytes = try SelectiveRemoteDeviceTrustV1.certificateBytes(cert.payload), directoryBytes = try SelectiveRemoteDeviceTrustV1.directoryBytes(directory.payload)
            guard key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: certSignature), for: certificateBytes),
                  key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: directorySignature), for: directoryBytes),
                  directory.payload.entries.contains(where: { $0.deviceID == device && $0.keyVersion == cert.payload.keyVersion && $0.certificateDigest == Data(SHA256.hash(data: certificateBytes + certSignature)).selectiveRemoteBase64URL }) else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
            try check(); return key
        }
        let next = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: prior.rootFingerprint, highWater: verified.highWater, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        try check()
        if let advancePin { try advancePin(scope.endpoint, scope.teamID, prior, next) }
        else if try SelectiveRemoteDeviceTrustLocalStore().pin(endpoint: scope.endpoint, accountID: account) != nil { try SelectiveRemoteDeviceTrustLocalStore().advance(endpoint: scope.endpoint, expected: prior, next: next) }
        else { try SelectiveRemoteVaultPublicationStore().savePublisherPin(next, expected: prior, scope: .init(endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID, teamID: scope.teamID, vaultID: vaultID), session: session) }
        try check(); return key
    }
    private func unwrap(_ envelopeJSON: SelectiveRemoteJSONValue, entry: SelectiveRemoteJSONValue, target: Target, sequence: Int, policyVersion: Int, vaultID: UUID) throws -> Data {
        let e = try entry.publicationObject(["accountID", "deviceKeyVersion", "wrapper"])
        let wrapper = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceKeyWrapper.self, from: e["wrapper"]!)
        let envelope = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceCipherEnvelope.self, from: envelopeJSON)
        let c = envelope.context, w = wrapper.context
        guard target.accountID == scope.accountID, target.deviceID == scope.deviceID,
              e["accountID"] == .string(scope.accountID.canonicalCloudString), e["deviceKeyVersion"] == .number(Double(target.keyVersion)),
              w.deviceID == scope.deviceID, w.membershipID == target.membershipID, w.membershipEpoch == target.epoch,
              w.teamID == scope.teamID, w.vaultID == vaultID, w.resourceID == c.resourceID, w.part == c.part, w.keyVersion == sequence,
              c.teamID == scope.teamID, c.vaultID == vaultID, c.keyVersion == sequence, c.registryVersion == sequence, c.resourceVersion == sequence, c.manifestVersion == sequence, c.policyVersion == policyVersion else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        var cek = try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: identity.privateKey, context: w)
        defer { cek.resetBytes(in: 0..<cek.count) }
        try check(); return try SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: cek, context: c)
    }
    private struct Custody { let parts: [String: Data]; let administrative: SelectiveRemoteJSONValue; let header: SelectiveRemoteJSONValue }
    private func custody(preview: SelectiveRemoteWholePublicationPreview, vaultID: UUID, target: Target) async throws -> Custody {
        let b = try preview.binding.publicationObject()
        guard let predecessor = try b["predecessors"]!.publicationArray().first(where: { try $0.publicationObject()["vaultID"] == .string(vaultID.canonicalCloudString) }) else { throw SelectiveRemoteWholePublicationError.scope }
        let old = try predecessor.publicationObject(["vaultID", "generationID", "sequence", "headerHash"])
        var baseline: [String: SelectiveRemoteJSONValue]?, descriptors: [SelectiveRemoteJSONValue] = [], cursor: String?, cursors = Set<String>()
        repeat {
            let page = try await request("repairDirectory", .object(["token": .string(preview.token), "request": preview.request, "vaultID": .string(vaultID.canonicalCloudString), "cursor": cursor.map(SelectiveRemoteJSONValue.string) ?? .null])).publicationObject()
            guard ["header", "headerHash", "generationID", "inventory", "manifest", "scope", "publisher", "administrativeResourceID", "descriptors", "nextCursor"].allSatisfy({ page[$0] != nil }) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
            if baseline == nil { baseline = page }
            guard ["header", "headerHash", "generationID", "inventory", "manifest", "scope", "publisher", "administrativeResourceID"].allSatisfy({ page[$0] == baseline![$0] }),
                  page["headerHash"] == old["headerHash"], page["generationID"] == old["generationID"] else { throw SelectiveRemoteWholePublicationError.scope }
            let items = try page["descriptors"]!.publicationArray()
            guard items.count <= 100, descriptors.count + items.count <= 2000 else { throw SelectiveRemoteWholePublicationError.limit }; descriptors += items
            cursor = page["nextCursor"] == .null ? nil : try page["nextCursor"]!.publicationString()
            if let cursor { guard cursors.insert(cursor).inserted else { throw SelectiveRemoteWholePublicationError.custodianUnavailable } }
        } while cursor != nil
        let page = baseline!, header = page["header"]!, hp = try SelectiveRemoteVaultPublicationV1.headerPayload(header)
        let publisher = try publisherRoot(page["publisher"]!, header: header, vaultID: vaultID)
        let water = try SelectiveRemoteVaultPublicationStore().highWater(scope: .init(endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID, teamID: scope.teamID, vaultID: vaultID))
        let verified = try SelectiveRemoteVaultPublicationV1.verifyHeader(header, rootPublicKey: publisher.x963Representation.selectiveRemoteBase64URL, teamID: scope.teamID.canonicalCloudString, vaultID: vaultID.canonicalCloudString, highWater: water)
        guard verified.hash == (try old["headerHash"]!.publicationString()), hp["generationID"] == old["generationID"], hp["sequence"] == old["sequence"] else { throw SelectiveRemoteWholePublicationError.scope }
        let manifest = try SelectiveRemoteWholePublicationWire.verifyManifest(page["manifest"]!, root: publisher), manifestScope = try manifest["scope"]!.publicationObject()
        guard manifest["scope"] == page["scope"], manifestScope["attemptID"] == old["generationID"], manifestScope["teamID"] == .string(scope.teamID.canonicalCloudString), manifestScope["vaultID"] == .string(vaultID.canonicalCloudString) else { throw SelectiveRemoteWholePublicationError.scope }
        let reader = try manifest["reader"]!.publicationObject(), custodyIDs = try reader["custodianDeviceIDs"]!.publicationArray()
        guard custodyIDs.contains(.string(scope.deviceID.canonicalCloudString)), let sidecarCommitment = reader["sidecarCommitment"] else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        let subject: SelectiveRemoteJSONValue = .object(["accountID": .string(scope.accountID.canonicalCloudString), "deviceID": .string(scope.deviceID.canonicalCloudString), "membershipID": .string(target.membershipID.canonicalCloudString), "membershipEpoch": .number(Double(target.epoch))])
        try SelectiveRemoteVaultPublicationV1.verifyInventory(page["inventory"]!, descriptors: descriptors, header: header, rootPublicKey: publisher.x963Representation.selectiveRemoteBase64URL, subject: subject)
        let sequence = try hp["sequence"]!.publicationInteger(), policyVersion = try manifestScope["policyVersion"]!.publicationInteger()
        var parts: [String: Data] = [:]
        for descriptor in descriptors {
            let d = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor), resourceID = try d["resourceID"]!.publicationString(), part = try d["part"]!.publicationString(), key = resourceID + "/" + part
            guard parts[key] == nil else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
            let response = try await request("repairPart", .object(["token": .string(preview.token), "request": preview.request, "vaultID": .string(vaultID.canonicalCloudString), "resourceID": .string(resourceID), "part": .string(part)])).publicationObject(["headerHash", "generationID", "descriptor", "envelope", "entry", "proof"])
            guard response["headerHash"] == old["headerHash"], response["generationID"] == old["generationID"], response["descriptor"] == descriptor else { throw SelectiveRemoteWholePublicationError.scope }
            try SelectiveRemoteVaultPublicationV1.verifyDescriptor(descriptor, header: header, rootPublicKey: publisher.x963Representation.selectiveRemoteBase64URL, envelope: response["envelope"], entry: response["entry"], proof: response["proof"])
            var plaintext = try unwrap(response["envelope"]!, entry: response["entry"]!, target: target, sequence: sequence, policyVersion: policyVersion, vaultID: vaultID)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            _ = try SelectiveRemotePublicationPartDecoder.decode(plaintext, descriptor: descriptor, header: header)
            parts[key] = plaintext
        }
        let administrative = try await request("repairPart", .object(["token": .string(preview.token), "request": preview.request, "vaultID": .string(vaultID.canonicalCloudString), "resourceID": page["administrativeResourceID"]!, "part": .string("ADMINISTRATIVE")])).publicationObject()
        guard ["envelope", "entry", "proof", "resourceID", "manifest", "scope", "publisher"].allSatisfy({ administrative[$0] != nil }), administrative["headerHash"] == old["headerHash"], administrative["generationID"] == old["generationID"], administrative["manifest"] == page["manifest"], administrative["scope"] == page["scope"], administrative["publisher"] == page["publisher"] else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        let commitment = try sidecarCommitment.publicationObject(["resourceID", "envelopeHash", "wrapperRoot"])
        guard commitment["resourceID"] == administrative["resourceID"], commitment["resourceID"] == page["administrativeResourceID"], commitment["envelopeHash"] == .string(try SelectiveRemoteVaultPublicationV1.hash("ciphertext", administrative["envelope"]!)) else { throw SelectiveRemotePublicationError.ciphertext }
        let administrativeEnvelope = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceCipherEnvelope.self, from: administrative["envelope"]!)
        guard administrative["part"] == .string("SECRET"), administrativeEnvelope.context.resourceID == (try SelectiveRemoteWholePublicationWire.id(commitment["resourceID"]!)), administrativeEnvelope.context.part == .secret else { throw SelectiveRemoteWholePublicationError.scope }
        try SelectiveRemoteVaultPublicationV1.verifyWrapper(entry: administrative["entry"]!, proof: administrative["proof"]!, root: commitment["wrapperRoot"]!.publicationString())
        var plaintext = try unwrap(administrative["envelope"]!, entry: administrative["entry"]!, target: target, sequence: sequence, policyVersion: policyVersion, vaultID: vaultID)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let data = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: plaintext), metadata = try data.publicationObject()
        guard metadata["version"] == .number(1), metadata["generationID"] == old["generationID"],
              metadata["scope"] == nil || metadata["scope"] == .object(["teamID": .string(scope.teamID.canonicalCloudString), "vaultID": .string(vaultID.canonicalCloudString)]),
              metadata["mapping"] != nil, metadata["sourceMetadata"] != nil else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        try check(); return Custody(parts: parts, administrative: data, header: header)
    }
    private func encrypted(_ plaintext: Data, context: SelectiveRemoteResourceCipherContext, targets: [Target], includeHash: Bool = false) throws -> SelectiveRemoteJSONValue {
        guard Set(targets.map(\.deviceID)).count == targets.count, let own = targets.first(where: { $0.deviceID == scope.deviceID && $0.accountID == scope.accountID }) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        let wrapperContexts = targets.map { target in SelectiveRemoteResourceWrapperContext(teamID: scope.teamID, vaultID: context.vaultID, resourceID: context.resourceID, part: context.part, keyVersion: context.keyVersion, membershipID: target.membershipID, membershipEpoch: target.epoch, deviceID: target.deviceID) }
        guard try SelectiveRemoteWholePublicationWire.encodedPartBudget(context: context, plaintextBytes: plaintext.count, wrapperContexts: wrapperContexts, includeHash: includeHash) <= 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
        var cek = SelectiveRemoteResourceCryptoV2.generateCEK(); defer { cek.resetBytes(in: 0..<cek.count) }
        let envelope = try SelectiveRemoteResourceCryptoV2.encrypt(plaintext, cek: cek, context: context)
        let wrappers = try zip(targets, wrapperContexts).map { target, wrapperContext in
            try SelectiveRemoteResourceCryptoV2.wrap(cek, for: target.publicKey, context: wrapperContext)
        }
        guard let wrapper = wrappers.first(where: { $0.context.deviceID == own.deviceID }) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        var opened = try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: identity.privateKey, context: wrapper.context); defer { opened.resetBytes(in: 0..<opened.count) }
        var roundtrip = try SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: opened, context: context); defer { roundtrip.resetBytes(in: 0..<roundtrip.count) }
        guard roundtrip == plaintext else { throw SelectiveRemotePublicationError.ciphertext }; try check()
        return .object(["resourceID": .string(context.resourceID.canonicalCloudString), "part": .string(context.part.rawValue), "envelope": try SelectiveRemoteWholePublicationWire.json(envelope), "wrappers": .array(try wrappers.map(SelectiveRemoteWholePublicationWire.json))])
    }
    private struct Commitment { let root: String; let items: [(SelectiveRemoteJSONValue, SelectiveRemoteJSONValue)] }
    private func commitment(_ entries: [SelectiveRemoteJSONValue]) throws -> Commitment {
        func key(_ entry: SelectiveRemoteJSONValue) throws -> String {
            let c = try entry.publicationObject()["wrapper"]!.publicationObject()["context"]!.publicationObject()
            return try c["membershipID"]!.publicationString() + "/" + c["deviceID"]!.publicationString()
        }
        let entries = try entries.sorted { try key($0) < key($1) }
        guard !entries.isEmpty, entries.count <= 10000, Set(try entries.map(key)).count == entries.count else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
        var levels = [try entries.map { try SelectiveRemoteVaultPublicationV1.hash("wrapper-leaf", $0) }]
        while levels.last!.count > 1 {
            let previous = levels.last!; var next: [String] = []
            for n in stride(from: 0, to: previous.count, by: 2) { next.append(try SelectiveRemoteVaultPublicationV1.hash("wrapper-parent", .object(["left": .string(previous[n]), "right": .string(previous[min(n + 1, previous.count - 1)])]))) }
            levels.append(next)
        }
        let items = try entries.enumerated().map { index, entry in
            var position = index, siblings: [SelectiveRemoteJSONValue] = []
            for level in levels.dropLast() { siblings.append(.string(level[min(position ^ 1, level.count - 1)])); position /= 2 }
            let proof: SelectiveRemoteJSONValue = .object(["index": .number(Double(index)), "total": .number(Double(entries.count)), "siblings": .array(siblings)])
            try SelectiveRemoteVaultPublicationV1.verifyWrapper(entry: entry, proof: proof, root: levels.last![0]); return (entry, proof)
        }
        return .init(root: levels.last![0], items: items)
    }
    private func entries(_ object: SelectiveRemoteJSONValue, targets: [String: Target]) throws -> [SelectiveRemoteJSONValue] {
        try object.publicationObject()["wrappers"]!.publicationArray().map { wrapper in
            let w = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceKeyWrapper.self, from: wrapper)
            let key = w.context.membershipID.canonicalCloudString + "/" + w.context.deviceID.canonicalCloudString
            guard let t = targets[key], w.context.membershipEpoch == t.epoch else { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
            return .object(["accountID": .string(t.accountID.canonicalCloudString), "deviceKeyVersion": .number(Double(t.keyVersion)), "wrapper": wrapper])
        }
    }
    private func projection(resources: [SelectiveRemoteJSONValue], objects: [SelectiveRemoteJSONValue], targets: [String: Target], generation: [String: SelectiveRemoteJSONValue], keyVersion: Int) throws -> SelectiveRemoteJSONValue {
        var cores: [SelectiveRemoteJSONValue] = [], commitments: [Commitment] = []
        for object in objects {
            let o = try object.publicationObject(), r = try resources.first { try $0.publicationObject()["id"] == o["resourceID"] }!.publicationObject()
            let bound = try commitment(entries(object, targets: targets)); commitments.append(bound)
            cores.append(.object(["resourceID": o["resourceID"]!, "kind": r["kind"]!, "part": o["part"]!, "parentFolderID": r["parentFolderID"]!, "context": try o["envelope"]!.publicationObject()["context"]!, "ciphertextHash": .string(try SelectiveRemoteVaultPublicationV1.hash("ciphertext", o["envelope"]!)), "wrapperRoot": .string(bound.root)]))
        }
        func partKey(_ value: SelectiveRemoteJSONValue) throws -> String { let p = try value.publicationObject(); return try p["resourceID"]!.publicationString() + "/" + p["part"]!.publicationString() }
        let order = try cores.indices.sorted { try partKey(cores[$0]) < partKey(cores[$1]) }
        let payload: SelectiveRemoteJSONValue = .object(["version": .number(1), "teamID": .string(scope.teamID.canonicalCloudString), "vaultID": generation["vaultID"]!, "generationID": generation["generationID"]!, "sequence": generation["sequence"]!, "previousHash": generation["previousHash"]!, "descriptorCommitment": .string(try SelectiveRemoteVaultPublicationV1.hash("descriptors", .array(order.map { cores[$0] }))), "publisherAccountID": .string(scope.accountID.canonicalCloudString), "publisherDeviceID": .string(scope.deviceID.canonicalCloudString), "publisherKeyVersion": .number(Double(keyVersion))])
        let header = try SelectiveRemoteWholePublicationWire.signed(payload, purpose: "header", root: root), headerHash = try SelectiveRemoteVaultPublicationV1.hash("header", header)
        _ = try SelectiveRemoteVaultPublicationV1.verifyHeader(header, rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL, teamID: scope.teamID.canonicalCloudString, vaultID: generation["vaultID"]!.publicationString(), highWater: nil)
        var descriptors: [SelectiveRemoteJSONValue] = [], recipientDescriptors: [String: [SelectiveRemoteJSONValue]] = [:], recipientProofs: [String: [SelectiveRemoteJSONValue]] = [:]
        if resources.isEmpty { for key in targets.keys { recipientDescriptors[key] = []; recipientProofs[key] = [] } }
        for i in order {
            var core = try cores[i].publicationObject(); core["headerHash"] = .string(headerHash)
            let descriptor = try SelectiveRemoteWholePublicationWire.signed(.object(core), purpose: "descriptor", root: root); descriptors.append(descriptor)
            for (entry, proof) in commitments[i].items {
                let w = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceKeyWrapper.self, from: entry.publicationObject()["wrapper"]!)
                let key = w.context.membershipID.canonicalCloudString + "/" + w.context.deviceID.canonicalCloudString
                recipientDescriptors[key, default: []].append(descriptor)
                recipientProofs[key, default: []].append(.object(["resourceID": core["resourceID"]!, "part": core["part"]!, "entry": entry, "proof": proof]))
                try SelectiveRemoteVaultPublicationV1.verifyDescriptor(descriptor, header: header, rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL, envelope: try objects[i].publicationObject()["envelope"], entry: entry, proof: proof)
            }
        }
        let recipients = try recipientDescriptors.keys.sorted().map { key -> SelectiveRemoteJSONValue in
            let t = targets[key]!, ds = recipientDescriptors[key]!
            let identities = try ds.map { descriptor -> SelectiveRemoteJSONValue in
                let d = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor)
                return .object(["resourceID": d["resourceID"]!, "part": d["part"]!, "descriptorHash": .string(try SelectiveRemoteVaultPublicationV1.hash("descriptor", descriptor))])
            }
            let subject: SelectiveRemoteJSONValue = .object(["accountID": .string(t.accountID.canonicalCloudString), "deviceID": .string(t.deviceID.canonicalCloudString), "membershipID": .string(t.membershipID.canonicalCloudString), "membershipEpoch": .number(Double(t.epoch))])
            var p = try subject.publicationObject(); p["headerHash"] = .string(headerHash); p["count"] = .number(Double(ds.count)); p["digest"] = .string(try SelectiveRemoteVaultPublicationV1.hash("inventory-items", .array(identities)))
            let inventory = try SelectiveRemoteWholePublicationWire.signed(.object(p), purpose: "inventory", root: root)
            try SelectiveRemoteVaultPublicationV1.verifyInventory(inventory, descriptors: ds, header: header, rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL, subject: subject)
            return .object(["inventory": inventory, "proofs": .array(recipientProofs[key]!)])
        }
        return .object(["version": .number(1), "header": header, "descriptors": .array(descriptors), "recipients": .array(recipients)])
    }
    func prepare(preview: SelectiveRemoteWholePublicationPreview, changedParts: [String: Data] = [:], administrativeChanges: [UUID: Data] = [:]) async throws {
        try enter(); defer { busy = false }; try check()
        guard preview.scope == scope, try !writesDisabled() else { throw SelectiveRemoteWholePublicationError.scope }
        guard try !store.commitState(scope: scope, session: session).discarded else { throw SelectiveRemoteWholePublicationError.replayConflict }
        try validateToken(preview.token, binding: preview.binding)
        let vaults = try validateRequest(preview.request)
        var expectedChanges = Set<String>()
        for vault in vaults {
            for raw in try vault["contentChanges"]!.publicationArray() {
                let change = try raw.publicationObject(["resourceID", "part"])
                expectedChanges.insert(try vault["vaultID"]!.publicationString() + "/" + change["resourceID"]!.publicationString() + "/" + change["part"]!.publicationString())
            }
        }
        guard Set(changedParts.keys) == expectedChanges, administrativeChanges.keys.allSatisfy({ id in vaults.contains { $0["vaultID"] == .string(id.canonicalCloudString) } }), changedParts.values.allSatisfy({ $0.count <= 1024 * 1024 }) else { throw SelectiveRemoteWholePublicationError.invalid }
        let changeHashes = SelectiveRemoteJSONValue.object(changedParts.mapValues { .string(SelectiveRemoteWholePublicationWire.digest($0)) }.merging(administrativeChanges.reduce(into: [:]) { $0[$1.key.canonicalCloudString + "/ADMINISTRATIVE"] = .string(SelectiveRemoteWholePublicationWire.digest($1.value)) }) { _, rhs in rhs })
        if let bytes = try store.load(scope: scope, generationsHash: preview.generationsHash, session: session) {
            let plan = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject()
            guard plan["request"] == preview.request, plan["binding"] == preview.binding, plan["changeHashes"] == changeHashes else { throw SelectiveRemoteWholePublicationError.replayConflict }
            try await upload(plan: plan, preview: preview); return
        }
        let binding = try preview.binding.publicationObject(), keyVersion = try binding["keyVersion"]!.publicationInteger()
        var uploads: [SelectiveRemoteJSONValue] = [], manifests: [SelectiveRemoteJSONValue] = [], headers: [SelectiveRemoteJSONValue] = []
        var aggregate = 0, nonces = Set<String>(), targetsByIdentity: [String: SelectiveRemoteJSONValue] = [:]
        for vault in vaults {
            let vaultID = try SelectiveRemoteWholePublicationWire.id(vault["vaultID"]!)
            guard let rawGeneration = try preview.generations.first(where: { try $0.publicationObject()["vaultID"] == vault["vaultID"] }) else { throw SelectiveRemoteWholePublicationError.scope }
            let generation = try rawGeneration.publicationObject(["vaultID", "generationID", "sequence", "previousHash", "scope", "snapshot"]), sequence = try generation["sequence"]!.publicationInteger(min: 2), genScope = try generation["scope"]!.publicationObject(), policyVersion = try genScope["policyVersion"]!.publicationInteger()
            guard genScope["teamID"] == .string(scope.teamID.canonicalCloudString), genScope["vaultID"] == vault["vaultID"], genScope["attemptID"] == generation["generationID"] else { throw SelectiveRemoteWholePublicationError.scope }
            let rows = try preview.rows.filter { try $0.publicationObject()["vaultID"] == vault["vaultID"] && $0.publicationObject()["type"] != .string("DELTA") }
            var targets: [String: Target] = [:], rowTargets: [String: [Target]] = [:]
            for row in rows {
                let r = try row.publicationObject(), type = try r["type"]!.publicationString()
                guard type == "PART" || type == "CUSTODY", let devices = r["devices"] else { throw SelectiveRemoteWholePublicationError.invalid }
                var verified: [Target] = []
                for device in try devices.publicationArray() {
                    let target = try trustedTarget(device, vaultID: vaultID)
                    if let prior = targetsByIdentity[target.recipientKey], prior != device { throw SelectiveRemoteWholePublicationError.recipientTrustUnverified }
                    targetsByIdentity[target.recipientKey] = device; targets[target.recipientKey] = target; verified.append(target)
                }
                let key = type == "CUSTODY" ? "ADMINISTRATIVE" : try r["resourceID"]!.publicationString() + "/" + r["part"]!.publicationString()
                guard rowTargets[key] == nil, !verified.isEmpty else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }; rowTargets[key] = verified
            }
            guard let custodians = rowTargets["ADMINISTRATIVE"], Set(custodians.map { $0.deviceID.canonicalCloudString }) == Set(try vault["custodianDeviceIDs"]!.publicationArray().map { try $0.publicationString() }),
                  let own = custodians.first(where: { $0.deviceID == scope.deviceID && $0.accountID == scope.accountID }), own.keyVersion == keyVersion else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
            let source: Custody
            do { source = try await custody(preview: preview, vaultID: vaultID, target: own) }
            catch is CancellationError { throw CancellationError() }
            catch { if let error = error as? SelectiveRemoteWholePublicationError, error == .recipientTrustUnverified { throw error }; throw SelectiveRemoteWholePublicationError.custodianUnavailable }
            let resources = try vault["resources"]!.publicationArray()
            var objects: [SelectiveRemoteJSONValue] = []
            for resource in resources {
                let r = try resource.publicationObject(), resourceID = try SelectiveRemoteWholePublicationWire.id(r["id"]!), kind = try r["kind"]!.publicationString()
                for part in kind == "CREDENTIAL" ? [SelectiveRemoteResourcePart.metadata, .secret] : [.general] {
                    let partKey = resourceID.canonicalCloudString + "/" + part.rawValue
                    let changeKey = vaultID.canonicalCloudString + "/" + partKey
                    guard let original = changedParts[changeKey] ?? source.parts[partKey], let partTargets = rowTargets[partKey] else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
                    var payload = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: original).publicationObject()
                    guard let rawLink = payload["link"] else { throw SelectiveRemoteWholePublicationError.scope }
                    var link = try rawLink.publicationObject(["teamID", "vaultID", "generationID", "resourceID", "kind", "part"])
                    guard link["teamID"] == .string(scope.teamID.canonicalCloudString), link["vaultID"] == vault["vaultID"], link["resourceID"] == r["id"], link["kind"] == r["kind"], link["part"] == .string(part.rawValue),
                          link["generationID"] == (try SelectiveRemoteVaultPublicationV1.headerPayload(source.header)["generationID"]) else { throw SelectiveRemoteWholePublicationError.scope }
                    link["generationID"] = generation["generationID"]; payload["link"] = .object(link)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    var plaintext = try encoder.encode(SelectiveRemoteJSONValue.object(payload)); defer { plaintext.resetBytes(in: 0..<plaintext.count) }
                    let context = SelectiveRemoteResourceCipherContext(teamID: scope.teamID, vaultID: vaultID, resourceID: resourceID, part: part, keyVersion: sequence, policyVersion: policyVersion, registryVersion: sequence, resourceVersion: sequence, manifestVersion: sequence)
                    var object = try encrypted(plaintext, context: context, targets: partTargets, includeHash: true).publicationObject()
                    object["sha256"] = .string(try SelectiveRemoteWholePublicationWire.hash(.object(object)))
                    let wrapped: SelectiveRemoteJSONValue = .object(["object": .object(object)]), objectBytes = try SelectiveRemoteWholePublicationWire.bytes(wrapped)
                    guard objectBytes.count <= 1024 * 1024, nonces.insert(try object["envelope"]!.publicationObject()["nonce"]!.publicationString()).inserted else { throw SelectiveRemoteWholePublicationError.limit }
                    aggregate += objectBytes.count; objects.append(.object(object))
                    uploads.append(.object(["route": .string("operations/\(scope.operationID.canonicalCloudString)/parts/\(vaultID.canonicalCloudString)"), "body": wrapped]))
                }
            }
            guard rowTargets.count == objects.count + 1 else { throw SelectiveRemoteWholePublicationError.incompletePreview }
            var metadata = try source.administrative.publicationObject()
            if let replacement = administrativeChanges[vaultID] {
                let proposed = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: replacement).publicationObject()
                let priorMapping = try metadata["mapping"]!.publicationObject(), nextMapping = try proposed["mapping"]!.publicationObject()
                let previousIDs = Set(try priorMapping.values.map { try SelectiveRemoteWholePublicationWire.id($0) }), nextIDs = try nextMapping.values.map(SelectiveRemoteWholePublicationWire.id)
                guard proposed["scope"] == metadata["scope"], proposed["version"] == metadata["version"], proposed["sourceMetadata"] == metadata["sourceMetadata"], previousIDs.isSubset(of: Set(nextIDs)), Set(nextIDs).count == nextIDs.count else { throw SelectiveRemoteWholePublicationError.scope }; metadata = proposed
            }
            let mappedIDs = Set(try metadata["mapping"]!.publicationObject().values.map { try $0.publicationString() })
            guard resources.allSatisfy({ (try? $0.publicationObject()["id"]?.publicationString()).map(mappedIDs.contains) ?? false }) else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
            metadata["generationID"] = generation["generationID"]
            let sidecarID = UUID(), context = SelectiveRemoteResourceCipherContext(teamID: scope.teamID, vaultID: vaultID, resourceID: sidecarID, part: .secret, keyVersion: sequence, policyVersion: policyVersion, registryVersion: sequence, resourceVersion: sequence, manifestVersion: sequence)
            var sidecarPlaintext = try JSONEncoder().encode(SelectiveRemoteJSONValue.object(metadata)); defer { sidecarPlaintext.resetBytes(in: 0..<sidecarPlaintext.count) }
            let sidecar = try encrypted(sidecarPlaintext, context: context, targets: custodians), sidecarObject = try sidecar.publicationObject()
            guard try SelectiveRemoteWholePublicationWire.bytes(sidecar).count <= 1024 * 1024, nonces.insert(try sidecarObject["envelope"]!.publicationObject()["nonce"]!.publicationString()).inserted else { throw SelectiveRemoteWholePublicationError.limit }
            aggregate += try SelectiveRemoteWholePublicationWire.bytes(sidecar).count
            guard aggregate <= 128 * 1024 * 1024 else { throw SelectiveRemoteWholePublicationError.limit }
            let projection = try projection(resources: resources, objects: objects, targets: targets, generation: generation, keyVersion: keyVersion)
            let header = try projection.publicationObject()["header"]!, headerHash = try SelectiveRemoteVaultPublicationV1.hash("header", header)
            let descriptors = try projection.publicationObject()["descriptors"]!.publicationArray()
            for descriptor in descriptors {
                let d = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor), key = try d["resourceID"]!.publicationString() + "/" + d["part"]!.publicationString()
                guard let original = changedParts[vaultID.canonicalCloudString + "/" + key] ?? source.parts[key] else { throw SelectiveRemoteWholePublicationError.custodianUnavailable }
                var payload = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: original).publicationObject(); var link = try payload["link"]!.publicationObject(); link["generationID"] = generation["generationID"]; payload["link"] = .object(link)
                _ = try SelectiveRemotePublicationPartDecoder.decode(JSONEncoder().encode(SelectiveRemoteJSONValue.object(payload)), descriptor: descriptor, header: header)
            }
            let sidecarRoot = try commitment(entries(sidecar, targets: targets)).root
            let reader: SelectiveRemoteJSONValue = .object(["projectionHash": .string(try SelectiveRemoteVaultPublicationV1.hash("projection", projection)), "sidecarHash": .string(try SelectiveRemoteVaultPublicationV1.hash("sidecar", sidecar)), "custodianDeviceIDs": vault["custodianDeviceIDs"]!, "sidecarCommitment": .object(["resourceID": .string(sidecarID.canonicalCloudString), "envelopeHash": .string(try SelectiveRemoteVaultPublicationV1.hash("ciphertext", sidecarObject["envelope"]!)), "wrapperRoot": .string(sidecarRoot)])])
            let partHashes = try objects.map { object -> SelectiveRemoteJSONValue in let o = try object.publicationObject(); return .object(["resourceID": o["resourceID"]!, "part": o["part"]!, "sha256": o["sha256"]!]) }
            let manifest = try SelectiveRemoteWholePublicationWire.signed(.object(["version": .number(2), "scope": generation["scope"]!, "policyHash": .string(try SelectiveRemoteWholePublicationWire.hash(vault["policy"]!)), "resources": vault["resources"]!, "parts": .array(partHashes), "reader": reader]), purpose: nil, root: root)
            _ = try SelectiveRemoteWholePublicationWire.verifyManifest(manifest, root: root.publicKey)
            uploads.append(.object(["route": .string("operations/\(scope.operationID.canonicalCloudString)/projections/\(vaultID.canonicalCloudString)"), "body": .object(["projection": projection, "sidecar": sidecar])]))
            manifests.append(.object(["vaultID": vault["vaultID"]!, "manifest": manifest])); headers.append(.object(["vaultID": vault["vaultID"]!, "header": header, "headerHash": .string(headerHash), "manifest": manifest]))
        }
        let plan: SelectiveRemoteJSONValue = .object(["version": .number(1), "request": preview.request, "binding": preview.binding, "generations": .array(preview.generations), "uploads": .array(uploads), "manifests": .array(manifests), "headers": .array(headers), "changeHashes": changeHashes])
        try check(); try store.persist(SelectiveRemoteWholePublicationWire.bytes(plan), scope: scope, generationsHash: preview.generationsHash, session: session); try check()
        guard let persisted = try store.load(scope: scope, generationsHash: preview.generationsHash, session: session) else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
        try await upload(plan: JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: persisted).publicationObject(), preview: preview)
    }
    private func upload(plan: [String: SelectiveRemoteJSONValue], preview: SelectiveRemoteWholePublicationPreview) async throws {
        guard plan["request"] == preview.request, plan["binding"] == preview.binding, plan["generations"] == .array(preview.generations) else { throw SelectiveRemoteWholePublicationError.replayConflict }
        try check(); try store.recordPreparing(scope: scope, session: session); try check()
        _ = try await request("start", .object(["request": preview.request, "token": .string(preview.token)]))
        let checkpoint = try store.checkpoint(scope: scope, session: session)
        var checkpointAttached = false
        for raw in try plan["uploads"]!.publicationArray() {
            let upload = try raw.publicationObject(["route", "body"]), route = try upload["route"]!.publicationString()
            var body = try upload["body"]!.publicationObject()
            // The protected plan covers the whole operation; one opaque copy avoids multiplying the aggregate by Vault count.
            if route.contains("/projections/"), !checkpointAttached { body["checkpoint"] = checkpoint; checkpointAttached = true }
            if route.contains("/projections/"), try SelectiveRemoteWholePublicationWire.bytes(.object(body)).count > 1024 * 1024 {
                let bytes = try SelectiveRemoteWholePublicationWire.bytes(.object(body)), count = (bytes.count + 512 * 1024 - 1) / (512 * 1024), sha = SelectiveRemoteWholePublicationWire.digest(bytes)
                guard count <= 256 else { throw SelectiveRemoteWholePublicationError.limit }
                for index in 0..<count {
                    let chunk = bytes.subdata(in: index * 512 * 1024..<min((index + 1) * 512 * 1024, bytes.count))
                    let response = try await request(route.replacingOccurrences(of: "/projections/", with: "/projection-chunks/"), SelectiveRemoteWholePublicationWire.projectionChunk(chunk, index: index, count: count, sha256: sha))
                    if index == count - 1 { guard try response.publicationObject()["complete"] == .boolean(true) else { throw SelectiveRemoteWholePublicationError.incompletePreview } }
                }
            } else { _ = try await request(route, .object(body)) }
        }
        _ = try await request("operations/\(scope.operationID.canonicalCloudString)/validate", .object(["manifests": plan["manifests"]!]))
        try check()
    }
    func resume(request value: SelectiveRemoteJSONValue) async throws {
        guard try !store.commitState(scope: scope, session: session).discarded else { throw SelectiveRemoteWholePublicationError.replayConflict }
        let fresh = try await preview(request: value)
        try enter(); defer { busy = false }
        guard let bytes = try store.load(scope: scope, generationsHash: fresh.generationsHash, session: session) else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
        let plan = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject()
        try await upload(plan: plan, preview: fresh)
    }
    private func frozenPlan(request value: SelectiveRemoteJSONValue, receiptRecovery: Bool = false) throws -> [String: SelectiveRemoteJSONValue] {
        let value = try SelectiveRemoteWholePublicationWire.canonicalRequest(value)
        _ = try validateRequest(value)
        guard let bytes = try receiptRecovery ? store.loadForReceipt(scope: scope, session: session) : store.load(scope: scope, session: session) else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
        let plan = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject(["version", "request", "binding", "generations", "uploads", "manifests", "headers", "changeHashes"])
        guard plan["version"] == .number(1), plan["request"] == value else { throw SelectiveRemoteWholePublicationError.replayConflict }; return plan
    }
    private func verifyReceipt(_ receipt: SelectiveRemoteJSONValue, plan: [String: SelectiveRemoteJSONValue]) throws {
        let r = try receipt.publicationObject(["operationID", "teamID", "requestHash", "actorAccountID", "actorDeviceID", "vaults", "committedAt"]), b = try plan["binding"]!.publicationObject()
        guard r["operationID"] == .string(scope.operationID.canonicalCloudString), r["teamID"] == .string(scope.teamID.canonicalCloudString), r["requestHash"] == b["requestHash"], r["actorAccountID"] == .string(scope.accountID.canonicalCloudString), r["actorDeviceID"] == .string(scope.deviceID.canonicalCloudString),
              try !r["committedAt"]!.publicationString().isEmpty else { throw SelectiveRemoteWholePublicationError.scope }
        let expected = try plan["headers"]!.publicationArray().map { raw -> SelectiveRemoteJSONValue in
            let value = try raw.publicationObject(), h = try SelectiveRemoteVaultPublicationV1.headerPayload(value["header"]!)
            return .object(["vaultID": value["vaultID"]!, "generationID": h["generationID"]!, "sequence": h["sequence"]!, "headerHash": value["headerHash"]!])
        }
        guard r["vaults"] == .array(expected) else { throw SelectiveRemoteWholePublicationError.replayConflict }
    }
    private func resolve(plan: [String: SelectiveRemoteJSONValue], candidate: SelectiveRemoteJSONValue? = nil, receiptRecovery: Bool = false) async throws -> SelectiveRemoteJSONValue {
        try check()
        let state = try store.commitState(scope: scope, session: session, receiptRecovery: receiptRecovery)
        let receipt: SelectiveRemoteJSONValue
        if let candidate { receipt = candidate }
        else if let saved = state.receipt { receipt = saved }
        else { receipt = try await request("operations/\(scope.operationID.canonicalCloudString)/receipt", nil) }
        try verifyReceipt(receipt, plan: plan); try check()
        try store.recordCommit(scope: scope, session: session, receipt: receipt, receiptRecovery: receiptRecovery)
        do {
            for raw in try plan["headers"]!.publicationArray() {
                let expected = try raw.publicationObject(["vaultID", "header", "headerHash", "manifest"]), vaultID = try SelectiveRemoteWholePublicationWire.id(expected["vaultID"]!)
                try check(); let response = try await remote.wholePublicationReadback(scope: scope, vaultID: vaultID); try check()
                let actual = try response.publicationObject(["vaultID", "header", "headerHash", "manifest"])
                guard actual == expected, actual["headerHash"] == .string(try SelectiveRemoteVaultPublicationV1.hash("header", actual["header"]!)) else { throw SelectiveRemoteWholePublicationError.replayConflict }
                _ = try SelectiveRemoteWholePublicationWire.verifyManifest(actual["manifest"]!, root: root.publicKey)
                _ = try SelectiveRemoteVaultPublicationV1.verifyHeader(actual["header"]!, rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL, teamID: scope.teamID.canonicalCloudString, vaultID: vaultID.canonicalCloudString, highWater: nil)
            }
            try check(); try store.recordCommit(scope: scope, session: session, receipt: receipt, complete: true, receiptRecovery: receiptRecovery); try check(); return receipt
        } catch is CancellationError { throw CancellationError() }
        catch { throw SelectiveRemoteWholePublicationError.readbackRequired }
    }
    func commit(preview: SelectiveRemoteWholePublicationPreview) async throws -> SelectiveRemoteJSONValue {
        try enter(); defer { busy = false }
        guard preview.scope == scope else { throw SelectiveRemoteWholePublicationError.scope }
        let plan = try frozenPlan(request: preview.request), state = try store.commitState(scope: scope, session: session)
        guard !state.discarded else { throw SelectiveRemoteWholePublicationError.replayConflict }
        if state.pending { return try await resolve(plan: plan) }
        guard plan["binding"] == preview.binding, plan["generations"] == .array(preview.generations) else { throw SelectiveRemoteWholePublicationError.replayConflict }
        try validateToken(preview.token, binding: preview.binding)
        try check(); try store.recordCommit(scope: scope, session: session); try check()
        let receipt: SelectiveRemoteJSONValue
        do { receipt = try await request("operations/\(scope.operationID.canonicalCloudString)/commit", .object(["request": preview.request, "token": .string(preview.token)])) }
        catch {
            try check()
            if case let SelectiveRemoteCloudError.serviceError(status, code) = error, status == 409,
               ["preview_invalidated", "preview_expired", "publication_stale", "publication_not_ready", "publication_ready_attempt_exists", "publication_custodian_unavailable", "publication_successor_mismatch"].contains(code ?? "") {
                // These authenticated failures occur only before commit. Keep the fence through receipt lookup and atomic server discard.
                try await discardUncommitted(); throw error
            }
            guard SelectiveRemoteVaultPublicationCoordinator.transient(error) else { throw error }
            return try await resolve(plan: plan)
        }
        return try await resolve(plan: plan, candidate: receipt)
    }
    private func discardUncommitted(receiptRecovery: Bool = false) async throws {
        let state = try store.commitState(scope: scope, session: session, receiptRecovery: receiptRecovery)
        guard state.receipt == nil, !state.complete else { throw SelectiveRemoteWholePublicationError.readbackRequired }
        guard try await request("operations/\(scope.operationID.canonicalCloudString)/receipt", nil) == .null else { throw SelectiveRemoteWholePublicationError.readbackRequired }
        let result = try await request("operations/\(scope.operationID.canonicalCloudString)/discard", .object([:])).publicationObject(["operationID", "state"])
        guard result["operationID"] == .string(scope.operationID.canonicalCloudString), result["state"] == .string("DISCARDED"),
              try await request("operations/\(scope.operationID.canonicalCloudString)/receipt", nil) == .null else { throw SelectiveRemoteWholePublicationError.readbackRequired }
        try check(); try store.recordDiscard(scope: scope, session: session, receiptRecovery: receiptRecovery); try check()
    }
    func discardAfterFailedCommit() async throws {
        try enter(); defer { busy = false }
        let state = try store.commitState(scope: scope, session: session, receiptRecovery: true)
        guard state.receipt == nil, try store.pendingOperation(scope: scope, session: session) == scope.operationID else { throw SelectiveRemoteWholePublicationError.readbackRequired }
        // The server's locked discard refuses COMMITTED and is idempotent after a lost discard response.
        try await discardUncommitted(receiptRecovery: true)
    }
    func resolveReceipt(request value: SelectiveRemoteJSONValue) async throws -> SelectiveRemoteJSONValue {
        try enter(); defer { busy = false }; return try await resolve(plan: frozenPlan(request: value, receiptRecovery: true), receiptRecovery: true)
    }
    func savedRequest() throws -> SelectiveRemoteJSONValue? {
        try check()
        guard let bytes = try store.loadForReceipt(scope: scope, session: session) else { return nil }
        guard let value = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject()["request"] else { throw SelectiveRemoteWholePublicationError.checkpointUnavailable }
        _ = try validateRequest(value); try check(); return value
    }
    func canDiscardUncommitted() throws -> Bool {
        let state = try store.commitState(scope: scope, session: session, receiptRecovery: true)
        return try store.pendingOperation(scope: scope, session: session) == scope.operationID && state.receipt == nil && !state.complete
    }
    func writesDisabled() throws -> Bool {
        let state = try store.commitState(scope: scope, session: session, receiptRecovery: true), pending = try store.pendingOperation(scope: scope, session: session)
        return (state.pending && !state.complete) || (pending != nil && pending != scope.operationID)
    }
}
