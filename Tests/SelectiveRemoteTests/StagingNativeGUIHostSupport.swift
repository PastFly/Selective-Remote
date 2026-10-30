import CryptoKit
import Darwin
import Foundation
import Security
import MachO
@testable import SelectiveRemote

/// Public expectations only. Unknown keys (including keys/tokens/passwords) fail closed.
struct StagingNativeManifest: Codable, Equatable, Sendable {
    struct Secret: Codable, Equatable, Sendable { let resourceID: UUID; let sha256: String }
    let formatVersion: Int
    let runID: String
    let testIdentityCreatedForRun: String
    let endpoint: URL
    let accountID: UUID
    let email: String
    let approvedRuntimeConfigPath: String
    let teamID: UUID
    let vaultID: UUID
    let teamName: String
    let vaultName: String
    let rootFingerprint: String
    let checkpointDigest: String
    let generationID: UUID
    let sequence: Int
    let headerHash: String
    let counts: StagingRealProbeConfig.Counts
    let secrets: [Secret]

    static func load(path: String?) throws -> (Self, URL)? {
        guard let loaded = try loadSnapshot(path: path) else { return nil }
        return (loaded.manifest, loaded.directory)
    }
    static func loadSnapshot(path: String?) throws -> StagingNativeLoadedManifest? {
        guard let path else { return nil }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let bytes = try StagingNativeProtectedFile.read(path)
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            let keys: Set<String> = ["formatVersion", "runID", "testIdentityCreatedForRun", "endpoint", "accountID", "email", "approvedRuntimeConfigPath", "teamID", "vaultID", "teamName", "vaultName", "rootFingerprint", "checkpointDigest", "generationID", "sequence", "headerHash", "counts", "secrets"]
            guard let object, Set(object.keys) == keys,
                  let counts = object["counts"] as? [String: Any], Set(counts.keys) == ["hosts", "snippets", "credentials", "forwardings", "folders"],
                  let secrets = object["secrets"] as? [[String: Any]], secrets.allSatisfy({ Set($0.keys) == ["resourceID", "sha256"] }) else { throw StagingRealProbeError.configuration }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard value.formatVersion == 1, value.endpoint.absoluteString == "https://cloud.pastfly.ru",
                  value.runID.range(of: "^TEST-ONLY-CODEX-[A-Za-z0-9][A-Za-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  value.runID == directory.lastPathComponent, value.testIdentityCreatedForRun == value.runID,
                  [value.teamName, value.vaultName].allSatisfy({ $0.hasPrefix(value.runID + "-") && $0.count <= 120 }),
                  value.email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil, value.email.count <= 254,
                  [value.accountID, value.teamID, value.vaultID, value.generationID].allSatisfy(\.isSelectiveRemoteCloudUUID),
                  value.sequence > 0, StagingRealProbeConfig.hash(value.headerHash), StagingRealProbeConfig.hash(value.rootFingerprint),
                  Data(selectiveRemoteBase64URL: value.checkpointDigest, expectedLength: 32) != nil,
                  value.secrets.count <= 100, Set(value.secrets.map(\.resourceID)).count == value.secrets.count,
                  value.secrets.allSatisfy({ $0.resourceID.isSelectiveRemoteCloudUUID && StagingRealProbeConfig.hash($0.sha256) }) else { throw StagingRealProbeError.scope }
            let numbers = [value.counts.hosts, value.counts.snippets, value.counts.credentials, value.counts.forwardings, value.counts.folders]
            guard numbers.allSatisfy({ (1...10_000).contains($0) }), numbers.reduce(0,+) <= 10_000,
                  !value.secrets.isEmpty else { throw StagingRealProbeError.scope }
            try value.validateRuntimeApproval()
            return .init(manifest: value, directory: directory, sha256: StagingRealProbe.sha256(bytes))
        } catch let error as StagingRealProbeError { throw error }
        catch { throw StagingRealProbeError.configuration }
    }
    private func validateRuntimeApproval() throws {
        let bytes = try StagingNativeProtectedFile.read(approvedRuntimeConfigPath)
        guard let approval = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(approval.keys) == ["version", "runID", "origin", "emails", "expectedSourceSHA", "approvedVaultIDs", "moduleHashes", "operator"],
              approval["version"] as? Int == 1, approval["origin"] as? String == endpoint.absoluteString,
              let browserRun = approval["runID"] as? String, runID == "TEST-ONLY-CODEX-" + browserRun,
              browserRun.range(of: "^[a-z0-9][a-z0-9-]{5,39}$", options: .regularExpression) != nil,
              let emails = approval["emails"] as? [String], emails.count == 2,
              Set(emails.map { $0.lowercased() }).count == 2,
              emails.allSatisfy({ $0.count <= 254 && $0.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil }),
              emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }),
              let vaults = approval["approvedVaultIDs"] as? [String], vaults.compactMap(UUID.init(uuidString:)).contains(vaultID)
        else { throw StagingRealProbeError.scope }
    }
    func authorizedTeam(client: SelectiveRemoteCloudAPIClient, stores: StagingNativeStores,
                        identity: SelectiveRemoteTeamDeviceIdentity?, requireLegacyVault: Bool) async throws -> SelectiveRemoteCloudTeam {
        var membership: (UUID, Int)?
        if !requireLegacyVault {
            guard let raw = try stores.read("admission"), let identity else { throw StagingRealProbeError.protection }
            let expectation = try JSONDecoder().decode(StagingNativeAdmissionExpectation.self, from: raw)
            guard expectation.runID == runID, expectation.accountID == accountID,
                  expectation.teamID == teamID, expectation.vaultID == vaultID,
                  expectation.deviceID == stores.deviceID, expectation.publicKey == identity.publicKey else { throw StagingRealProbeError.scope }
            membership = (expectation.membershipID, expectation.membershipEpoch)
        }
        return try await StagingRealProbe.authorizedTeam(client: client, scope: scope(deviceID: stores.deviceID),
            runID: runID, teamName: teamName, vaultName: vaultName,
            requireLegacyVault: requireLegacyVault, membership: membership)
    }

    var service: String { "org.pastfly.SelectiveRemote.NativeGUI.TEST-ONLY." + runID }
    func scope(deviceID: UUID) -> SelectiveRemotePublicationScope {
        .init(endpoint: endpoint, accountID: accountID, deviceID: deviceID, teamID: teamID, vaultID: vaultID)
    }
}

/// Dedicated service; no shared envelope, legacy service, defaults, cookies or root key.
struct StagingNativeKeychain: SelectiveRemotePublicationProtectedStorage {
    let service: String
    let accountID: UUID
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: accountID.canonicalCloudString + "/" + key,
         kSecAttrSynchronizable as String: false, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    func read(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StagingRealProbeError.protection }
        return data
    }
    func save(_ data: Data, key: String) throws {
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(key); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw StagingRealProbeError.protection }
        } else if status != errSecSuccess { throw StagingRealProbeError.protection }
    }
}

/// One process owns the run exclusively (flock). Serialized CAS within that process.
final class StagingNativeStores: SelectiveRemotePublicationProtectedStorage, SelectiveRemoteCloudTokenStore,
    SelectiveRemoteTeamDeviceKeyStore, SelectiveRemoteDeviceTrustLocalStoring,
    SelectiveRemotePublicationSessionProviding, @unchecked Sendable {
    let endpoint: URL
    let accountID: UUID
    let deviceID: UUID
    let storage: any SelectiveRemotePublicationProtectedStorage
    private let lock = NSLock()
    init(endpoint: URL, accountID: UUID, deviceID: UUID, storage: any SelectiveRemotePublicationProtectedStorage) {
        self.endpoint = endpoint; self.accountID = accountID; self.deviceID = deviceID; self.storage = storage
    }
    private func bound(_ endpoint: URL, _ account: UUID? = nil, _ device: UUID? = nil) throws {
        guard endpoint == self.endpoint, account == nil || account == accountID,
              device == nil || device == deviceID else { throw StagingRealProbeError.scope }
    }
    func read(_ key: String) throws -> Data? { try storage.read("device/" + deviceID.canonicalCloudString + "/" + key) }
    func save(_ data: Data, key: String) throws { try storage.save(data, key: "device/" + deviceID.canonicalCloudString + "/" + key) }
    func token(for endpoint: URL) throws -> String? {
        try bound(endpoint)
        return try read("token").flatMap { $0.isEmpty ? nil : String(data: $0, encoding: .utf8) }
    }
    func saveToken(_ token: String, for endpoint: URL) throws { try bound(endpoint); try save(Data(token.utf8), key: "token") }
    func removeToken(for endpoint: URL) throws { try bound(endpoint); try save(Data(), key: "token") }
    func publicationAccountBinding(key: String) throws -> Data? { try read("account/" + key) }
    func savePublicationAccountBinding(_ data: Data, key: String) throws { try save(data, key: "account/" + key) }
    func isolatedPublicationSession(endpoint: URL, token: String, deviceID: UUID?) throws -> SelectiveRemotePublicationSession? {
        try bound(endpoint, nil, deviceID)
        guard try self.token(for: endpoint) == token, !token.isEmpty else { throw CancellationError() }
        return .init(endpoint: endpoint, accountID: accountID, deviceID: self.deviceID, token: token, tokenStore: self, checkConfiguration: false)
    }
    func privateKeyRepresentation(for endpoint: URL, deviceID: UUID) throws -> Data? {
        try bound(endpoint, nil, deviceID); return try read("identity")
    }
    func savePrivateKeyIfAbsent(_ representation: Data, for endpoint: URL, deviceID: UUID) throws -> Data {
        try bound(endpoint, nil, deviceID)
        return try lock.withLock {
            if let old = try read("identity") { return old }
            guard representation.count == 32 else { throw StagingRealProbeError.protection }
            try save(representation, key: "identity"); return representation
        }
    }
    func removePrivateKey(for endpoint: URL, deviceID: UUID) throws { throw StagingRealProbeError.protection }
    func root(endpoint: URL, accountID: UUID) throws -> P256.Signing.PrivateKey? { try bound(endpoint, accountID); return nil }
    func bootstrapBundle(endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustBootstrapBundle? { try bound(endpoint, accountID); return nil }
    func pendingRekey(endpoint: URL, accountID: UUID, deviceID: UUID) throws -> SelectiveRemoteTeamDeviceIdentity? { try bound(endpoint, accountID, deviceID); return nil }
    func saveRootIfAbsent(_ root: P256.Signing.PrivateKey, endpoint: URL, accountID: UUID) throws -> P256.Signing.PrivateKey { throw StagingRealProbeError.protection }
    func saveBootstrapBundleIfAbsent(_ bundle: SelectiveRemoteDeviceTrustBootstrapBundle, endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustBootstrapBundle { throw StagingRealProbeError.protection }
    func savePendingRekeyIfAbsent(_ identity: SelectiveRemoteTeamDeviceIdentity, endpoint: URL, accountID: UUID) throws -> SelectiveRemoteTeamDeviceIdentity { throw StagingRealProbeError.protection }
    func commitPendingRekey(endpoint: URL, accountID: UUID, deviceID: UUID, expectedPublicKey: SelectiveRemoteTeamDevicePublicKey) throws -> SelectiveRemoteTeamDeviceIdentity { throw StagingRealProbeError.protection }
    private func validate(_ pin: SelectiveRemoteDeviceTrustPin) throws {
        guard pin.accountID == accountID, StagingRealProbeConfig.hash(pin.rootFingerprint),
              (1...9_007_199_254_740_991).contains(pin.highWater),
              Data(selectiveRemoteBase64URL: pin.checkpointDigest, expectedLength: 32) != nil
        else { throw StagingRealProbeError.trust }
    }
    func pin(endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustPin? {
        try bound(endpoint, accountID)
        return try read("pin").map {
            let pin = try JSONDecoder().decode(SelectiveRemoteDeviceTrustPin.self, from: $0)
            try validate(pin); return pin
        }
    }
    func savePinIfAbsent(_ pin: SelectiveRemoteDeviceTrustPin, endpoint: URL) throws -> SelectiveRemoteDeviceTrustPin {
        try bound(endpoint, pin.accountID); try validate(pin)
        return try lock.withLock {
            if let old = try self.pin(endpoint: endpoint, accountID: accountID) {
                guard old == pin else { throw StagingRealProbeError.trust }; return old
            }
            try save(JSONEncoder().encode(pin), key: "pin"); return pin
        }
    }
    func advance(endpoint: URL, expected: SelectiveRemoteDeviceTrustPin, next: SelectiveRemoteDeviceTrustPin) throws {
        try bound(endpoint, expected.accountID); try bound(endpoint, next.accountID)
        try validate(expected); try validate(next)
        try lock.withLock {
            guard try pin(endpoint: endpoint, accountID: accountID) == expected,
                  next.highWater >= expected.highWater else { throw StagingRealProbeError.trust }
            try StagingRealPinStore.compatible(expected, next)
            try save(JSONEncoder().encode(next), key: "pin")
        }
    }
}

final class StagingNativeRunLock {
    private let fd: Int32
    init(directory: URL) throws {
        fd = open(directory.appending(path: ".native-host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StagingRealProbeError.protection }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw StagingRealProbeError.protection }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

struct StagingNativeEvidence: Codable {
    let formatVersion: Int
    let nativeGuiTestHost: Bool
    let productGuiAcceptance: Bool
    let runID: String
    let phase: String
    let launchNonce: UUID
    let pid: Int32
    let processID: UUID
    let previousProcessID: String
    let accountID: UUID
    let teamID: UUID
    let vaultID: UUID
    let deviceID: UUID
    let generationID: UUID
    let publicKey: SelectiveRemoteTeamDevicePublicKey
    let publicKeyFingerprint: String
    let status: String
    let sequence: Int
    let headerHash: String
    let manifestSHA256: String
    let acceptedAttemptID: String
    let counts: StagingRealProbeConfig.Counts
    let binary: StagingNativeExecutableIdentity
    let ownPin: SelectiveRemoteDeviceTrustPin?
    let offlineVerified: Bool
    let networkReloadVerified: Bool
    let secretsVerified: Int
    func write(directory: URL, name: String) throws {
        let path = directory.appending(path: name)
        let bytes = try JSONEncoder().encode(self)
        // Create private replacement first; atomic rename never exposes a world-readable intermediate.
        let temp = directory.appending(path: ".evidence-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StagingRealProbeError.permissions }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
            guard rename(temp.path, path.path) == 0 else { throw StagingRealProbeError.permissions }
        } catch { try? FileManager.default.removeItem(at: temp); throw StagingRealProbeError.protection }
    }
}

/// Browser custodian records authoritative HTTPS admission/readback separately.
/// Native consumption records an expectation, never claims that this file is server evidence.
struct StagingNativeAdmissionExpectation: Codable, Sendable {
    let source: String
    let runID: String
    let accountID: UUID
    let teamID: UUID
    let vaultID: UUID
    let membershipID: UUID
    let membershipEpoch: Int
    let deviceID: UUID
    let publicKey: SelectiveRemoteTeamDevicePublicKey
    let browserEvidenceSHA256: String

    static func load(directory: URL, manifest: StagingNativeManifest, deviceID: UUID,
                     publicKey: SelectiveRemoteTeamDevicePublicKey) throws -> Self {
        let url = directory.appending(path: "admission.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw StagingRealProbeError.permissions }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, (1...16_384).contains(info.st_size)
        else { throw StagingRealProbeError.permissions }
        do {
            let data = try handle.read(upToCount: 16_385) ?? Data()
            guard data.count == info.st_size,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["source", "runID", "accountID", "teamID", "vaultID", "membershipID", "membershipEpoch", "deviceID", "publicKey", "browserEvidenceSHA256"],
                  let key = object["publicKey"] as? [String: Any], Set(key.keys) == ["kty", "crv", "x", "y", "ext", "key_ops"] else { throw StagingRealProbeError.configuration }
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.source == "BROWSER_CUSTODIAN_HTTPS_ADMISSION_READBACK", value.runID == manifest.runID,
                  value.accountID == manifest.accountID, value.teamID == manifest.teamID, value.vaultID == manifest.vaultID,
                  value.deviceID == deviceID, value.publicKey == publicKey, value.membershipID.isSelectiveRemoteCloudUUID,
                  value.membershipEpoch > 0, StagingRealProbeConfig.hash(value.browserEvidenceSHA256)
            else { throw StagingRealProbeError.scope }
            return value
        } catch let error as StagingRealProbeError { throw error }
        catch { throw StagingRealProbeError.configuration }
    }
}

struct StagingNativeLoadedManifest {
    let manifest: StagingNativeManifest
    let directory: URL
    let sha256: String
}

enum StagingNativeProtectedFile {
    static func read(_ path: String, limit: Int = 65_536) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.standardizedFileURL.path == path,
              url.resolvingSymlinksInPath().path == path else { throw StagingRealProbeError.permissions }
        try StagingRealProbeConfig.privateDirectory(url.deletingLastPathComponent())
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw StagingRealProbeError.permissions }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o777 == 0o600, before.st_nlink == 1, before.st_size > 0, before.st_size <= limit
        else { throw StagingRealProbeError.permissions }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, bytes.count == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw StagingRealProbeError.permissions }
        return bytes
    }
}

struct StagingNativeAcceptedExpectation: Codable, Equatable {
    let attemptID: UUID
    let manifestSHA256: String
    let sequence: Int
    let headerHash: String
    let generationID: UUID
    let secretsVerified: Int
}

/// The only authority for Finish/rendered HTTPS success. Begin/failure immediately removes previous success.
struct StagingNativeAcceptance {
    private(set) var attemptID: UUID?
    private(set) var accepted: StagingNativeAcceptedExpectation?
    private(set) var rows: [String] = []
    mutating func begin(_ id: UUID) { attemptID = id; accepted = nil; rows = [] }
    mutating func fail(_ id: UUID) { if attemptID == id { accepted = nil; rows = [] } }
    mutating func accept(_ id: UUID, manifestSHA256: String, sequence: Int, headerHash: String,
                         generationID: UUID, secretsVerified: Int, requiredSecrets: Int, rows: [String]) throws {
        guard attemptID == id, requiredSecrets > 0, secretsVerified == requiredSecrets,
              sequence > 0, StagingRealProbeConfig.hash(manifestSHA256), StagingRealProbeConfig.hash(headerHash)
        else { throw StagingRealProbeError.acceptance }
        accepted = .init(attemptID: id, manifestSHA256: manifestSHA256, sequence: sequence, headerHash: headerHash,
                         generationID: generationID, secretsVerified: secretsVerified)
        self.rows = rows
    }
    func canFinish(manifestSHA256: String) -> Bool { accepted?.attemptID == attemptID && accepted?.manifestSHA256 == manifestSHA256 }
}

struct StagingNativeCheckpoint: Codable {
    let runID: String
    let accountID: UUID
    let teamID: UUID
    let vaultID: UUID
    let email: String
    let endpoint: URL
    let rootFingerprint: String
    let deviceID: UUID
    let originatingProcessID: UUID
    let stage: String
    let publicKey: SelectiveRemoteTeamDevicePublicKey?
    let ownPin: SelectiveRemoteDeviceTrustPin?

    var recoveryRequiresLegacyVault: Bool { !["admission", "materialized"].contains(stage) }

    static func reserve(manifest: StagingNativeManifest, storage: any SelectiveRemotePublicationProtectedStorage, processID: UUID) throws -> Self {
        guard try storage.read("device-id") == nil, try storage.read("native-checkpoint") == nil
        else { throw StagingRealProbeError.protection }
        let result = Self(runID: manifest.runID, accountID: manifest.accountID, teamID: manifest.teamID, vaultID: manifest.vaultID,
            email: manifest.email, endpoint: manifest.endpoint, rootFingerprint: manifest.rootFingerprint,
            deviceID: UUID(), originatingProcessID: processID, stage: "reserved", publicKey: nil, ownPin: nil)
        try storage.save(Data(result.deviceID.uuidString.utf8), key: "device-id")
        try result.save(storage: storage)
        return result
    }
    func save(storage: any SelectiveRemotePublicationProtectedStorage) throws { try storage.save(JSONEncoder().encode(self), key: "native-checkpoint") }
    func advanced(stage: String, publicKey: SelectiveRemoteTeamDevicePublicKey, pin: SelectiveRemoteDeviceTrustPin?) -> Self {
        .init(runID: runID, accountID: accountID, teamID: teamID, vaultID: vaultID, email: email, endpoint: endpoint,
            rootFingerprint: rootFingerprint, deviceID: deviceID, originatingProcessID: originatingProcessID,
            stage: stage, publicKey: publicKey, ownPin: pin)
    }
    static func recover(manifest: StagingNativeManifest, storage: any SelectiveRemotePublicationProtectedStorage) throws -> Self {
        guard let data = try storage.read("native-checkpoint"), let id = try storage.read("device-id")
        else { throw StagingRealProbeError.protection }
        let checkpoint = try JSONDecoder().decode(Self.self, from: data)
        guard checkpoint.runID == manifest.runID, checkpoint.accountID == manifest.accountID,
              checkpoint.teamID == manifest.teamID, checkpoint.vaultID == manifest.vaultID,
              checkpoint.email == manifest.email, checkpoint.endpoint == manifest.endpoint,
              checkpoint.rootFingerprint == manifest.rootFingerprint,
              String(data: id, encoding: .utf8).flatMap(UUID.init(uuidString:)) == checkpoint.deviceID,
              ["reserved", "identity", "login", "approval", "admission", "materialized"].contains(checkpoint.stage)
        else { throw StagingRealProbeError.scope }
        let stores = StagingNativeStores(endpoint: manifest.endpoint, accountID: manifest.accountID,
                                        deviceID: checkpoint.deviceID, storage: storage)
        let raw = try stores.privateKeyRepresentation(for: manifest.endpoint, deviceID: checkpoint.deviceID)
        if checkpoint.stage == "reserved", checkpoint.publicKey == nil {
            // A crash after CAS but before the public checkpoint may adopt only that exact persisted key.
            if let raw {
                let key = try SelectiveRemoteTeamDeviceIdentity(deviceID: checkpoint.deviceID, privateKeyRepresentation: raw)
                let adopted = checkpoint.advanced(stage: "identity", publicKey: key.publicKey, pin: nil)
                try adopted.save(storage: storage); return adopted
            }
            return checkpoint // No identity has been generated yet; original reserved UUID is retained.
        }
        guard let raw, try SelectiveRemoteTeamDeviceIdentity(deviceID: checkpoint.deviceID, privateKeyRepresentation: raw).publicKey == checkpoint.publicKey
        else { throw StagingRealProbeError.protection }
        if ["login", "approval", "admission", "materialized"].contains(checkpoint.stage) {
            guard try stores.token(for: manifest.endpoint) != nil else { throw StagingRealProbeError.protection }
        }
        let currentPin = try stores.pin(endpoint: manifest.endpoint, accountID: manifest.accountID)
        if let expected = checkpoint.ownPin {
            guard let currentPin, currentPin.highWater >= expected.highWater else { throw StagingRealProbeError.trust }
            try StagingRealPinStore.compatible(expected, currentPin)
        }
        if let currentPin { guard currentPin.rootFingerprint == manifest.rootFingerprint else { throw StagingRealProbeError.trust } }
        if ["admission", "materialized"].contains(checkpoint.stage) {
            guard currentPin != nil, try stores.read("admission") != nil else { throw StagingRealProbeError.protection }
        }
        return checkpoint
    }
}

@_cdecl("SelectiveRemoteNativeGUIBinaryMarker")
func stagingNativeGUIBinaryMarker() {}

struct StagingNativeExecutableIdentity: Codable, Equatable {
    let executablePath: String
    let executableSHA256: String
    let testBundlePath: String
    let testBundleSHA256: String
    static var buildDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build").resolvingSymlinksInPath()
    }
    static func validatedTestBundle(_ path: String, buildDirectory: URL) throws -> URL {
        let file = URL(fileURLWithPath: path), build = buildDirectory.resolvingSymlinksInPath()
        let name = file.lastPathComponent
        var info = stat()
        guard path.hasPrefix("/"), file.standardizedFileURL.path == path, file.resolvingSymlinksInPath().path == path,
              path.hasPrefix(build.path + "/"), ["SelectiveRemoteTests", "SelectiveRemotePackageTests"].contains(name),
              file.deletingLastPathComponent().lastPathComponent == "MacOS",
              file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == name + ".xctest",
              lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: path) else { throw StagingRealProbeError.protection }
        return file
    }
    static func current() throws -> Self {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw StagingRealProbeError.protection }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        var info = Dl_info()
        let pointer = unsafeBitCast(stagingNativeGUIBinaryMarker as @convention(c) () -> Void, to: UnsafeRawPointer.self)
        guard dladdr(pointer, &info) != 0, let name = info.dli_fname else { throw StagingRealProbeError.protection }
        let loaded = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
        let bundle = try validatedTestBundle(loaded.path, buildDirectory: buildDirectory)
        return .init(executablePath: executable.path, executableSHA256: StagingRealProbe.sha256(try Data(contentsOf: executable)),
                     testBundlePath: bundle.path, testBundleSHA256: StagingRealProbe.sha256(try Data(contentsOf: bundle)))
    }
}

struct StagingNativeInvocation: Codable {
    let formatVersion: Int
    let nonce: UUID
    let runID: String
    let phase: String
    let accountID: UUID
    let teamID: UUID
    let vaultID: UUID
    let binary: StagingNativeExecutableIdentity
    static func load(path: String?, manifest: StagingNativeManifest, phase: String) throws -> Self {
        guard let path else { throw StagingRealProbeError.configuration }
        let bytes = try StagingNativeProtectedFile.read(path)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["formatVersion", "nonce", "runID", "phase", "accountID", "teamID", "vaultID", "binary"],
              let binary = object["binary"] as? [String: Any],
              Set(binary.keys) == ["executablePath", "executableSHA256", "testBundlePath", "testBundleSHA256"]
        else { throw StagingRealProbeError.configuration }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.formatVersion == 1, value.runID == manifest.runID, value.phase == phase,
              value.accountID == manifest.accountID, value.teamID == manifest.teamID, value.vaultID == manifest.vaultID,
              value.binary == (try StagingNativeExecutableIdentity.current()) else { throw StagingRealProbeError.scope }
        return value
    }
}
