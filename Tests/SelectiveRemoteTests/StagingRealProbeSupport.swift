import CryptoKit
import Darwin
import Foundation
import Security
@testable import SelectiveRemote

// Test-only input. Never load an app preference, existing credential or default store.
enum StagingRealProbeError: String, Error { case configuration, permissions, protection, scope, trust, acceptance }

struct StagingRealProbeConfig: Decodable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        let hosts: Int; let snippets: Int; let credentials: Int; let forwardings: Int; let folders: Int
    }
    struct Secret: Decodable, Sendable { let resourceID: UUID; let sha256: String }
    let formatVersion: Int
    let runID: String
    let testIdentityCreatedForRun: String
    let endpoint: String
    let accountID: UUID
    let deviceID: UUID
    let teamID: UUID
    let vaultID: UUID
    let teamName: String
    let vaultName: String
    let sessionToken: String
    let devicePrivateKey: String
    let ownPin: SelectiveRemoteDeviceTrustPin
    let publisherPin: SelectiveRemoteDeviceTrustPin
    let generationID: UUID
    let sequence: Int
    let headerHash: String
    let counts: Counts
    let secrets: [Secret]
    let deniedSecrets: [UUID]
    let requireOldClientDenial: Bool

    static func load(path: String?) throws -> (Self, URL)? {
        guard let path else { return nil }
        do {
            let url = URL(fileURLWithPath: path), directory = url.deletingLastPathComponent()
            guard path.hasPrefix("/"), url.standardizedFileURL.path == path,
                  url.resolvingSymlinksInPath().path == path else { throw StagingRealProbeError.permissions }
            try privateDirectory(directory)
            let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parent >= 0 else { throw StagingRealProbeError.permissions }; defer { close(parent) }
            let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw StagingRealProbeError.permissions }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFREG,
                  before.st_mode & 0o777 == 0o600, before.st_nlink == 1, before.st_size > 0, before.st_size <= 65_536
            else { throw StagingRealProbeError.permissions }
            let bytes = try file.read(upToCount: 65_537) ?? Data()
            var after = stat()
            guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  bytes.count == before.st_size else { throw StagingRealProbeError.permissions }
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            let keys: Set<String> = ["formatVersion", "runID", "testIdentityCreatedForRun", "endpoint", "accountID", "deviceID", "teamID", "vaultID", "teamName", "vaultName", "sessionToken", "devicePrivateKey", "ownPin", "publisherPin", "generationID", "sequence", "headerHash", "counts", "secrets", "deniedSecrets", "requireOldClientDenial"]
            guard let object, Set(object.keys) == keys else { throw StagingRealProbeError.configuration }
            for key in ["ownPin", "publisherPin"] {
                guard let pin = object[key] as? [String: Any], Set(pin.keys) == ["accountID", "rootFingerprint", "highWater", "checkpointDigest"] else { throw StagingRealProbeError.configuration }
            }
            guard let counts = object["counts"] as? [String: Any], Set(counts.keys) == ["hosts", "snippets", "credentials", "forwardings", "folders"],
                  let secrets = object["secrets"] as? [[String: Any]], secrets.allSatisfy({ Set($0.keys) == ["resourceID", "sha256"] }) else { throw StagingRealProbeError.configuration }
            let config = try JSONDecoder().decode(Self.self, from: bytes)
            try config.validate(directory: directory)
            return (config, directory)
        } catch let error as StagingRealProbeError { throw error }
        catch { throw StagingRealProbeError.configuration } // Never include file contents, token or decoder diagnostics.
    }

    static func privateDirectory(_ url: URL) throws {
        var info = stat()
        guard url.resolvingSymlinksInPath().path == url.path, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
        else { throw StagingRealProbeError.permissions }
    }
    static func hash(_ text: String) -> Bool { text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private func validate(directory: URL) throws {
        guard formatVersion == 1, endpoint == "https://cloud.pastfly.ru",
              runID.range(of: "^TEST-ONLY-CODEX-[A-Za-z0-9][A-Za-z0-9-]{0,63}$", options: .regularExpression) != nil,
              testIdentityCreatedForRun == runID, directory.lastPathComponent == runID,
              [teamName, vaultName].allSatisfy({ $0.hasPrefix(runID + "-") && $0.count <= 120 }),
              [accountID, deviceID, teamID, vaultID, generationID].allSatisfy(\.isSelectiveRemoteCloudUUID),
              ownPin.accountID == accountID, sequence > 0, Self.hash(headerHash),
              sessionToken.range(of: "^[A-Za-z0-9_-]{32,512}$", options: .regularExpression) != nil,
              let raw = Data(base64Encoded: devicePrivateKey), raw.count == 32,
              (try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw)) != nil
        else { throw StagingRealProbeError.scope }
        for pin in [ownPin, publisherPin] {
            guard pin.accountID.isSelectiveRemoteCloudUUID, Self.hash(pin.rootFingerprint), pin.highWater > 0,
                  Data(selectiveRemoteBase64URL: pin.checkpointDigest, expectedLength: 32) != nil else { throw StagingRealProbeError.trust }
        }
        if publisherPin.accountID == accountID, publisherPin != ownPin { throw StagingRealProbeError.trust }
        let values = [counts.hosts, counts.snippets, counts.credentials, counts.forwardings, counts.folders]
        guard values.allSatisfy({ (0...10_000).contains($0) }), values.reduce(0, +) <= 10_000,
              secrets.count <= 100, deniedSecrets.count <= 100,
              secrets.allSatisfy({ $0.resourceID.isSelectiveRemoteCloudUUID && Self.hash($0.sha256) }),
              deniedSecrets.allSatisfy(\.isSelectiveRemoteCloudUUID),
              Set(secrets.map(\.resourceID)).count == secrets.count, Set(deniedSecrets).count == deniedSecrets.count,
              Set(secrets.map(\.resourceID)).isDisjoint(with: deniedSecrets) else { throw StagingRealProbeError.configuration }
    }
    var scope: SelectiveRemotePublicationScope {
        .init(endpoint: URL(string: endpoint)!, accountID: accountID, deviceID: deviceID, teamID: teamID, vaultID: vaultID)
    }
    var service: String { "org.pastfly.SelectiveRemote.StagingReal." + runID }
}

/// All keys are scoped to the newly created account/device, even in a multi-user run.
struct StagingRealKeychain: SelectiveRemotePublicationProtectedStorage, SelectiveRemoteCloudTokenStore {
    let service: String
    let prefix: String
    init(_ config: StagingRealProbeConfig) {
        service = config.service; prefix = config.accountID.canonicalCloudString + "/" + config.deviceID.canonicalCloudString + "/"
    }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: prefix + key, kSecAttrSynchronizable as String: false]
    }
    func read(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StagingRealProbeError.protection }
        return data
    }
    func save(_ data: Data, key: String) throws {
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(key); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw StagingRealProbeError.protection }
        } else if status != errSecSuccess { throw StagingRealProbeError.protection }
    }
    func token(for endpoint: URL) throws -> String? {
        guard endpoint.absoluteString == "https://cloud.pastfly.ru" else { throw StagingRealProbeError.scope }
        return try read("token").map { data in
            guard let text = String(data: data, encoding: .utf8) else { throw StagingRealProbeError.protection }; return text
        }
    }
    func saveToken(_ token: String, for endpoint: URL) throws {
        guard endpoint.absoluteString == "https://cloud.pastfly.ru" else { throw StagingRealProbeError.scope }
        try save(Data(token.utf8), key: "token")
    }
    func removeToken(for endpoint: URL) throws {
        guard endpoint.absoluteString == "https://cloud.pastfly.ru" else { throw StagingRealProbeError.scope }
        let status = SecItemDelete(query("token") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StagingRealProbeError.protection }
    }
    func publicationAccountBinding(key: String) throws -> Data? { try read("account/" + key) }
    func savePublicationAccountBinding(_ data: Data, key: String) throws { try save(data, key: "account/" + key) }
}

struct StagingRealPinStore: Sendable {
    let storage: any SelectiveRemotePublicationProtectedStorage
    private static let lock = NSLock()
    func read() throws -> SelectiveRemoteDeviceTrustPin? {
        try storage.read("own-pin").map { try JSONDecoder().decode(SelectiveRemoteDeviceTrustPin.self, from: $0) }
    }
    func seed(_ pin: SelectiveRemoteDeviceTrustPin) throws {
        try Self.lock.withLock {
            if let prior = try read() {
                try Self.compatible(prior, pin)
                if prior.highWater >= pin.highWater { return }
            }
            try storage.save(JSONEncoder().encode(pin), key: "own-pin")
        }
    }
    static func compatible(_ a: SelectiveRemoteDeviceTrustPin, _ b: SelectiveRemoteDeviceTrustPin) throws {
        guard a.accountID == b.accountID, a.rootFingerprint == b.rootFingerprint,
              a.highWater != b.highWater || a.checkpointDigest == b.checkpointDigest else { throw StagingRealProbeError.trust }
    }
    func advance(expected: SelectiveRemoteDeviceTrustPin, next: SelectiveRemoteDeviceTrustPin) throws {
        try Self.lock.withLock {
            guard try read() == expected, next.highWater >= expected.highWater else { throw StagingRealProbeError.trust }
            try Self.compatible(expected, next)
            try storage.save(JSONEncoder().encode(next), key: "own-pin")
        }
    }
}

/// No default-preferences lookup in the production transport's retirement fallback.
extension SelectiveRemoteCloudAPIClient {
    func installStagingProbeSession(_ session: SelectiveRemotePublicationSession) throws {
        try session.check(); publicationRetirementSessions[session.endpoint.absoluteString] = session
    }
}

final class StagingRealNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum StagingRealProbe {
    struct Result: Codable, Sendable {
        let status = "REAL_HTTPS_READER_PASS"
        let generationID: UUID; let sequence: Int; let headerHash: String
        let counts: StagingRealProbeConfig.Counts
        let secretsVerified: Int; let deniedSecretsVerified: Int
        let oldClientDenied: Bool
        let durableCacheReopened = true
        let networkReloadVerified = true
        let guiAcceptance = false
    }
    private struct Reader {
        let client: SelectiveRemoteCloudAPIClient
        let coordinator: SelectiveRemoteVaultPublicationCoordinator
        let store: SelectiveRemoteVaultPublicationStore
        let network: URLSession
    }
    static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    // Shared authenticated scope boundary for the GUI host and separately labeled API probe.
    // Legacy inventory is a preactivation requirement; ACTIVE identity comes from the signed reader.
    static func authorizedTeam(client: SelectiveRemoteCloudAPIClient, scope: SelectiveRemotePublicationScope,
                               runID: String, teamName: String, vaultName: String,
                               requireLegacyVault: Bool, membership: (UUID, Int)? = nil) async throws -> SelectiveRemoteCloudTeam {
        guard try await client.currentUser(endpoint: scope.endpoint).id == scope.accountID else { throw StagingRealProbeError.scope }
        let teams = try await client.teams(endpoint: scope.endpoint)
        guard teams.allSatisfy({ $0.name.hasPrefix(runID + "-") }),
              let team = teams.first(where: { $0.id == scope.teamID && $0.name == teamName }),
              membership.map({ team.membershipID == $0.0 && team.membershipEpoch == $0.1 }) ?? true
        else { throw StagingRealProbeError.scope }
        if requireLegacyVault {
            let vaults = try await client.sharedVaults(endpoint: scope.endpoint, teamID: team.id)
            guard vaults.allSatisfy({ $0.name.hasPrefix(runID + "-") }),
                  vaults.contains(where: { $0.id == scope.vaultID && $0.teamID == team.id && $0.name == vaultName })
            else { throw StagingRealProbeError.scope }
        }
        return team
    }

    static func run(_ config: StagingRealProbeConfig, directory: URL) async throws -> Result {
        // All callers must have completed protected input validation first.
        do {
            let first = try await reader(config, directory: directory)
            defer { first.network.invalidateAndCancel() }
            let team = try await authorizedTeam(client: first.client, scope: config.scope, runID: config.runID,
                teamName: config.teamName, vaultName: config.vaultName, requireLegacyVault: false)
            let online = try await first.coordinator.load(teamName: team.name, vaultName: config.vaultName, role: team.role)
            try check(online, config: config, stale: false)
            try verifyWater(first.store, config: config)
            for secret in config.secrets {
                let value = try await first.coordinator.reveal(resourceID: secret.resourceID, expectedHeaderHash: config.headerHash)
                guard sha256(Data(value.utf8)) == secret.sha256 else { throw StagingRealProbeError.acceptance }
            }
            // New instances reopen the actual encrypted disk cache and dedicated Keychain receipts.
            let second = try await reader(config, directory: directory)
            defer { second.network.invalidateAndCancel() }
            let cached = try await second.coordinator.offline()
            try check(cached, config: config, stale: true); try verifyWater(second.store, config: config)
            let reloaded = try await second.coordinator.load(teamName: team.name, vaultName: config.vaultName, role: team.role)
            try check(reloaded, config: config, stale: false); try verifyWater(second.store, config: config)
            for resourceID in config.deniedSecrets {
                // Only absent SECRET permission in a complete authenticated inventory is accepted.
                // A timeout, signature error or arbitrary HTTP failure can never count as a denial.
                guard try !reloaded.descriptors.contains(where: { descriptor in
                    let value = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor)
                    return value["resourceID"] == .string(resourceID.canonicalCloudString) && value["part"] == .string("SECRET")
                }) else { throw StagingRealProbeError.acceptance }
                do {
                    _ = try await second.coordinator.reveal(resourceID: resourceID, expectedHeaderHash: config.headerHash)
                    throw StagingRealProbeError.acceptance
                } catch SelectiveRemotePublicationError.subject { }
                // Denial intentionally detaches the reader. Restore only through the real HTTPS load.
                let next = try await second.coordinator.load(teamName: team.name, vaultName: config.vaultName, role: team.role)
                try check(next, config: config, stale: false)
            }
            if config.requireOldClientDenial {
                let path = "v1/teams/\(config.teamID.canonicalCloudString)/vaults/\(config.vaultID.canonicalCloudString)"
                let (data, response) = try await second.client.authorizedResponse(endpoint: config.scope.endpoint, path: path)
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard response.statusCode == 409, body?["error"] as? String == "vault_upgrade_required" else { throw StagingRealProbeError.acceptance }
            }
            return Result(generationID: config.generationID, sequence: config.sequence, headerHash: config.headerHash,
                          counts: config.counts, secretsVerified: config.secrets.count, deniedSecretsVerified: config.deniedSecrets.count,
                          oldClientDenied: config.requireOldClientDenial)
        } catch { throw StagingRealProbeError.acceptance } // Redact all transport/server/decode/keychain diagnostics.
    }
    private static func verifyWater(_ store: SelectiveRemoteVaultPublicationStore, config: StagingRealProbeConfig) throws {
        guard try store.highWater(scope: config.scope) == .init(sequence: config.sequence, hash: config.headerHash) else { throw StagingRealProbeError.acceptance }
    }
    static func check(_ cache: SelectiveRemotePublicationCache, config: StagingRealProbeConfig, stale: Bool) throws {
        let header = try SelectiveRemoteVaultPublicationV1.headerPayload(cache.header)
        guard cache.scope == config.scope, cache.headerHash == config.headerHash, cache.stale == stale,
              header["generationID"] == .string(config.generationID.canonicalCloudString),
              header["sequence"] == .number(Double(config.sequence)),
              header["publisherAccountID"] == .string(config.publisherPin.accountID.canonicalCloudString)
        else { throw StagingRealProbeError.acceptance }
        let snapshot = try cache.materializedSnapshot()
        let counts = StagingRealProbeConfig.Counts(hosts: try SelectiveRemoteTeamHostMaterializer.materialize(snapshot).count,
            snippets: try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot).count,
            credentials: try cache.credentials().count, forwardings: try cache.forwardings().count, folders: try cache.folders().count)
        guard counts == config.counts else { throw StagingRealProbeError.acceptance }
    }
    private static func reader(_ config: StagingRealProbeConfig, directory: URL) async throws -> Reader {
        try StagingRealProbeConfig.privateDirectory(directory)
        let storage = StagingRealKeychain(config)
        let pins = StagingRealPinStore(storage: storage)
        let identity = try SelectiveRemoteTeamDeviceIdentity(deviceID: config.deviceID, privateKeyRepresentation: Data(base64Encoded: config.devicePrivateKey)!)
        let cacheDirectory = directory.appending(path: "cache-" + config.accountID.canonicalCloudString + "-" + config.deviceID.canonicalCloudString)
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try StagingRealProbeConfig.privateDirectory(cacheDirectory)
        for file in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600
            else { throw StagingRealProbeError.permissions }
        }
        let binding = Data((config.scope.key + "\n" + config.runID + "\n" + sha256(try JSONEncoder().encode(identity.publicKey))).utf8)
        let bindingKey = "probe/" + sha256(Data(config.scope.key.utf8))
        let marker = cacheDirectory.appending(path: sha256(Data(bindingKey.utf8)) + ".probe")
        let prior = try storage.read(bindingKey)
        if let prior { guard prior == binding else { throw StagingRealProbeError.scope } }
        if FileManager.default.fileExists(atPath: marker.path) {
            guard prior != nil, try pins.read() != nil else { throw StagingRealProbeError.protection }
        }
        try pins.seed(config.ownPin)
        try storage.saveToken(config.sessionToken, for: config.scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: config.scope.endpoint, accountID: config.accountID,
            deviceID: config.deviceID, token: config.sessionToken, tokenStore: storage, checkConfiguration: false)
        let store = try SelectiveRemoteVaultPublicationStore(directory: cacheDirectory, protected: storage)
        if config.publisherPin.accountID != config.accountID {
            let old = try store.publisherPin(endpoint: config.scope.endpoint, teamID: config.teamID, accountID: config.publisherPin.accountID)
            if FileManager.default.fileExists(atPath: marker.path), old == nil { throw StagingRealProbeError.protection }
            if let old { try StagingRealPinStore.compatible(old, config.publisherPin) }
            if old == nil || old!.highWater < config.publisherPin.highWater {
                try store.savePublisherPin(config.publisherPin, expected: old, scope: config.scope, session: session)
            }
        }
        try storage.save(binding, key: bindingKey)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data("test-only-scope-present/v1".utf8).write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120
        let network = URLSession(configuration: configuration, delegate: StagingRealNoRedirect(), delegateQueue: nil)
        let client = SelectiveRemoteCloudAPIClient(session: network, tokenStore: storage, publicationStore: { store })
        try await client.installStagingProbeSession(session)
        let coordinator = SelectiveRemoteVaultPublicationCoordinator(scope: config.scope, session: session, remote: client,
            identity: identity, store: store, ownPin: { endpoint, account in
                guard endpoint == config.scope.endpoint, account == config.accountID else { throw StagingRealProbeError.scope }
                return try pins.read()
            }, advanceOwnPin: { endpoint, expected, next in
                guard endpoint == config.scope.endpoint, next.accountID == config.accountID else { throw StagingRealProbeError.scope }
                try pins.advance(expected: expected, next: next)
            })
        return Reader(client: client, coordinator: coordinator, store: store, network: network)
    }
}
