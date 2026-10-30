import CryptoKit
import Foundation
import Security
import Testing
@testable import SelectiveRemote

@Suite("native GUI host isolation")
struct StagingNativeIsolationTests {
    @Test("strict isolated provider cannot fall back after invalidation")
    func strictProvider() async throws {
        let endpoint = URL(string: "https://cloud.pastfly.ru")!
        let storage = PublicationProtectedMemory()
        let stores = StagingNativeStores(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), storage: storage)
        try stores.saveToken(String(repeating: "t", count: 64), for: endpoint)
        let token = try #require(try stores.token(for: endpoint))
        let client = SelectiveRemoteCloudAPIClient(tokenStore: stores, publicationStore: { throw StagingRealProbeError.protection })
        let session = try #require(try stores.isolatedPublicationSession(endpoint: endpoint, token: token, deviceID: stores.deviceID))
        session.invalidate()
        try stores.removeToken(for: endpoint)
        await #expect(throws: Error.self) { try await client.publicationRetirementSession(endpoint: endpoint, token: token) }
        await #expect(throws: Error.self) { try await client.publicationSession(endpoint: endpoint, deviceID: stores.deviceID) }
    }
}

@Suite("native GUI host isolated store boundaries")
struct StagingNativeStoreBoundaryTests {
    @Test("no opt-in has no side effects")
    func absent() throws { #expect(try StagingNativeManifest.load(path: nil) == nil) }

    @Test("native P256 CAS survives reopen; endpoint/device substitution denied")
    func nativeCAS() async throws {
        let endpoint = URL(string: "https://cloud.pastfly.ru")!, account = UUID(), device = UUID()
        let memory = PublicationProtectedMemory()
        let stores = StagingNativeStores(endpoint: endpoint, accountID: account, deviceID: device, storage: memory)
        let first = try await SelectiveRemoteTeamDeviceIdentityManager(store: stores).identity(endpoint: endpoint, deviceID: device)
        let ignored = P256.KeyAgreement.PrivateKey().rawRepresentation
        #expect(try stores.savePrivateKeyIfAbsent(ignored, for: endpoint, deviceID: device) == first.privateKey.rawRepresentation)
        let reopened = StagingNativeStores(endpoint: endpoint, accountID: account, deviceID: device, storage: memory)
        let second = try await SelectiveRemoteTeamDeviceIdentityManager(store: reopened).identity(endpoint: endpoint, deviceID: device)
        #expect(first.publicKey == second.publicKey)
        #expect(throws: Error.self) { try stores.privateKeyRepresentation(for: endpoint, deviceID: UUID()) }
        #expect(throws: Error.self) { try stores.token(for: URL(string: "https://other.invalid")!) }
        #expect(try stores.root(endpoint: endpoint, accountID: account) == nil)
        #expect(try stores.bootstrapBundle(endpoint: endpoint, accountID: account) == nil)
        #expect(throws: Error.self) { try stores.saveRootIfAbsent(P256.Signing.PrivateKey(), endpoint: endpoint, accountID: account) }
    }

    @Test("own-pin CAS rejects rollback, root swap, fork and stale expected state")
    func ownPin() throws {
        let endpoint = URL(string: "https://cloud.pastfly.ru")!, account = UUID()
        let memory = PublicationProtectedMemory()
        let stores = StagingNativeStores(endpoint: endpoint, accountID: account, deviceID: UUID(), storage: memory)
        let first = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: String(repeating: "a", count: 64), highWater: 1, checkpointDigest: Data(repeating: 1, count: 32).selectiveRemoteBase64URL)
        let next = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: first.rootFingerprint, highWater: 2, checkpointDigest: Data(repeating: 2, count: 32).selectiveRemoteBase64URL)
        _ = try stores.savePinIfAbsent(first, endpoint: endpoint)
        try stores.advance(endpoint: endpoint, expected: first, next: next)
        #expect(throws: Error.self) { try stores.savePinIfAbsent(first, endpoint: endpoint) }
        #expect(throws: Error.self) { try stores.advance(endpoint: endpoint, expected: first, next: next) }
        #expect(throws: Error.self) { try stores.advance(endpoint: endpoint, expected: next, next: first) }
        let fork = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: next.rootFingerprint, highWater: 2, checkpointDigest: first.checkpointDigest)
        #expect(throws: Error.self) { try stores.advance(endpoint: endpoint, expected: next, next: fork) }
        let wrong = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: String(repeating: "b", count: 64), highWater: 3, checkpointDigest: first.checkpointDigest)
        #expect(throws: Error.self) { try stores.advance(endpoint: endpoint, expected: next, next: wrong) }
        let malformed = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: next.rootFingerprint, highWater: 3, checkpointDigest: "invalid")
        #expect(throws: Error.self) { try stores.advance(endpoint: endpoint, expected: next, next: malformed) }
        #expect(try stores.pin(endpoint: endpoint, accountID: account) == next)
    }

    @Test("strict provider checks account/device authorization before transport or store fallback")
    func invalidatedAndWrongDevice() async throws {
        let endpoint = URL(string: "https://cloud.pastfly.ru")!
        let stores = StagingNativeStores(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), storage: PublicationProtectedMemory())
        let token = String(repeating: "u", count: 64)
        try stores.saveToken(token, for: endpoint)
        let directory = FileManager.default.temporaryDirectory.appending(path: "TEST-ONLY-CODEX-session-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicationStore = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: stores)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: stores, dataLoader: { _ in throw StagingRealProbeError.acceptance }, publicationStore: { publicationStore })
        let original = try #require(try await client.publicationSession(endpoint: endpoint, deviceID: stores.deviceID))
        try original.check()
        await #expect(throws: Error.self) { try await client.publicationSession(endpoint: endpoint, deviceID: UUID()) }
        try stores.saveToken(String(repeating: "v", count: 64), for: endpoint)
        #expect(throws: Error.self) { try original.check() }
        await #expect(throws: Error.self) { try await client.publicationRetirementSession(endpoint: endpoint, token: token) }
    }
}

private struct StagingNativeFailingRemote: SelectiveRemoteVaultPublicationRemote {
    let status: Int
    func publicationRead(scope: SelectiveRemotePublicationScope, route: String, generation: String?, hash: String?, cursor: String?) async throws -> SelectiveRemoteJSONValue {
        throw SelectiveRemoteCloudError.serviceError(status, "test_only_denied")
    }
    func publicationOwnTrust(endpoint: URL) async throws -> SelectiveRemoteCloudDeviceTrustSnapshot { throw StagingRealProbeError.acceptance }
}

@Suite("native GUI production dependency injection")
struct StagingNativeInjectionTests {
    @Test("secondary trust coordinator uses injected identity and rootless local store")
    @MainActor func trustInjection() async throws {
        let endpoint = URL(string: "https://cloud.pastfly.ru")!, device = UUID(), account = UUID()
        let stores = StagingNativeStores(endpoint: endpoint, accountID: account, deviceID: device, storage: PublicationProtectedMemory())
        let manager = SelectiveRemoteTeamDeviceIdentityManager(store: stores)
        let expected = try await manager.identity(endpoint: endpoint, deviceID: device)
        try stores.saveToken(String(repeating: "a", count: 64), for: endpoint)
        let directory = FileManager.default.temporaryDirectory.appending(path: "TEST-ONLY-CODEX-trust-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicationStore = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: stores)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: stores, dataLoader: { request in
            guard request.url?.path == "/v1/device-trust" else { throw StagingRealProbeError.acceptance }
            return (Data("{\"state\":\"UNINITIALIZED\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, publicationStore: { publicationStore })
        let trust = SelectiveRemoteCloudDeviceTrustCoordinator(endpoint: endpoint, client: client, accountID: account, deviceID: device, local: stores, identities: manager)
        let result = try await trust.inspect()
        #expect(result.phase == .firstDevice)
        #expect(result.root == nil)
        #expect(result.identity.publicKey == expected.publicKey)
    }

    @Test("authoritative denial/authentication error detaches isolated presentation only", arguments: [403, 401])
    @MainActor func isolatedDetachment(_ status: Int) async throws {
        let endpoint = URL(string: "https://cloud.pastfly.ru")!, account = UUID(), device = UUID()
        let stores = StagingNativeStores(endpoint: endpoint, accountID: account, deviceID: device, storage: PublicationProtectedMemory())
        let token = String(repeating: "b", count: 64)
        try stores.saveToken(token, for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: account, deviceID: device, token: token, tokenStore: stores)
        let scope = SelectiveRemotePublicationScope(endpoint: endpoint, accountID: account, deviceID: device, teamID: UUID(), vaultID: UUID())
        let directory = FileManager.default.temporaryDirectory.appending(path: "TEST-ONLY-CODEX-native-negative-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: stores)
        let identity = try await SelectiveRemoteTeamDeviceIdentityManager(store: stores).identity(endpoint: endpoint, deviceID: device)
        var detachments = 0, allScopes = false
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: scope, session: session,
            remote: StagingNativeFailingRemote(status: status), identity: identity, store: store,
            ownPin: { _, _ in throw StagingRealProbeError.acceptance },
            advanceOwnPin: { _, _, _ in throw StagingRealProbeError.acceptance },
            detachPresentation: { received, receivedSession, all in
                #expect(received == scope); #expect(receivedSession === session)
                detachments += 1; allScopes = allScopes || all
            })
        await #expect(throws: Error.self) { try await reader.load(teamName: "TEST", vaultName: "TEST", role: .editor) }
        #expect(detachments == 2)
        #expect(allScopes == (status == 401))
    }
}

@Suite("explicit local Keychain opt-in")
struct StagingNativeKeychainTests {
    @Test("native identity CAS/reopen in dedicated local Keychain; no network",
          .enabled(if: ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_LOCAL_KEYCHAIN"] == "1"))
    func actualKeychainReopen() async throws {
        let service = "org.pastfly.SelectiveRemote.NativeGUI.TEST-ONLY.local-" + UUID().uuidString
        let endpoint = URL(string: "https://cloud.pastfly.ru")!, account = UUID(), device = UUID()
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrSynchronizable as String: false] as CFDictionary)
        }
        let storage = StagingNativeKeychain(service: service, accountID: account)
        let stores = StagingNativeStores(endpoint: endpoint, accountID: account, deviceID: device, storage: storage)
        let first = try await SelectiveRemoteTeamDeviceIdentityManager(store: stores).identity(endpoint: endpoint, deviceID: device)
        let contender = P256.KeyAgreement.PrivateKey().rawRepresentation
        #expect(try stores.savePrivateKeyIfAbsent(contender, for: endpoint, deviceID: device) == first.privateKey.rawRepresentation)
        let reopened = StagingNativeStores(endpoint: endpoint, accountID: account, deviceID: device,
            storage: StagingNativeKeychain(service: service, accountID: account))
        let second = try await SelectiveRemoteTeamDeviceIdentityManager(store: reopened).identity(endpoint: endpoint, deviceID: device)
        #expect(first.publicKey == second.publicKey)
        print("NATIVE_GUI_LOCAL_KEYCHAIN nativeGenerated=true CAS=true reopened=true network=false")
    }
}

@Suite("public native manifest and admission expectations")
struct StagingNativeManifestTests {
    private func fixture() -> [String: Any] {
        let run = "TEST-ONLY-CODEX-native-manifest"
        return ["formatVersion": 1, "runID": run, "testIdentityCreatedForRun": run, "endpoint": "https://cloud.pastfly.ru",
                "accountID": UUID().uuidString, "email": run.lowercased() + "@example.test", "teamID": UUID().uuidString,
                "vaultID": UUID().uuidString, "teamName": run + "-team", "vaultName": run + "-vault",
                "rootFingerprint": String(repeating: "a", count: 64), "checkpointDigest": Data(repeating: 1, count: 32).selectiveRemoteBase64URL,
                "generationID": UUID().uuidString, "sequence": 1, "headerHash": String(repeating: "b", count: 64),
                "counts": ["hosts": 1, "snippets": 1, "credentials": 1, "forwardings": 1, "folders": 1],
                "secrets": [["resourceID": UUID().uuidString, "sha256": String(repeating: "c", count: 64)]]]
    }
    private func write(_ object: [String: Any]) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        let dir = root.appending(path: "TEST-ONLY-CODEX-native-manifest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appending(path: "manifest.json")
        let runtime = dir.appending(path: "approved-runtime.json")
        let approval: [String: Any] = ["version": 1, "runID": "native-manifest", "origin": "https://cloud.pastfly.ru",
            "emails": ["custodian@example.test", "test-only-codex-native-manifest@example.test"],
            "approvedVaultIDs": [object["vaultID"]!], "expectedSourceSHA": String(repeating: "a", count: 40), "moduleHashes": [:], "operator": [:]]
        try JSONSerialization.data(withJSONObject: approval).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtime.path)
        var protectedObject = object; protectedObject["approvedRuntimeConfigPath"] = runtime.path
        try JSONSerialization.data(withJSONObject: protectedObject).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (file, root)
    }
    @Test("valid public manifest with all record kinds and SECRET digest")
    func valid() throws {
        let (file, root) = try write(fixture()); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, directory) = try #require(try StagingNativeManifest.load(path: file.path))
        #expect(manifest.runID == directory.lastPathComponent)
        #expect(manifest.service.hasPrefix("org.pastfly.SelectiveRemote.NativeGUI.TEST-ONLY."))
    }
    @Test("manifest rejects secret-bearing fields and scope overrides", arguments: ["password", "sessionToken", "devicePrivateKey", "endpoint", "email", "teamName", "runID", "emptySecrets", "emptyKind", "rootFingerprint"])
    func invalid(_ field: String) throws {
        var object = fixture()
        switch field {
        case "endpoint": object[field] = "https://cloud.pastfly.ru/override"
        case "email": object[field] = "owner@example.test"
        case "teamName", "runID": object[field] = "ordinary"
        case "emptySecrets": object["secrets"] = []
        case "emptyKind": object["counts"] = ["hosts": 0, "snippets": 1, "credentials": 1, "forwardings": 1, "folders": 1]
        case "rootFingerprint": object[field] = "unknown"
        default: object[field] = "test-secret-must-not-be-accepted"
        }
        let (file, root) = try write(object); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Error.self) { try StagingNativeManifest.load(path: file.path) }
    }
    @Test("private manifest permissions, symlink and relative path required", arguments: ["permissions", "symlink", "relative"])
    func protected(_ fault: String) throws {
        let (file, root) = try write(fixture()); defer { try? FileManager.default.removeItem(at: root) }
        var path = file.path
        if fault == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        if fault == "symlink" { let link = file.deletingLastPathComponent().appending(path: "link.json"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file); path = link.path }
        if fault == "relative" { path = file.deletingLastPathComponent().appending(path: "../TEST-ONLY-CODEX-native-manifest/manifest.json").path }
        let testedPath = path
        #expect(throws: Error.self) { try StagingNativeManifest.load(path: testedPath) }
    }
    @Test("admission expectation binds exact native key, Team, membership and custodian evidence digest")
    func admission() throws {
        let (file, root) = try write(fixture()); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, directory) = try #require(try StagingNativeManifest.load(path: file.path))
        let device = UUID(), key = try SelectiveRemoteTeamDevicePublicKey(P256.KeyAgreement.PrivateKey().publicKey)
        let value = StagingNativeAdmissionExpectation(source: "BROWSER_CUSTODIAN_HTTPS_ADMISSION_READBACK", runID: manifest.runID,
            accountID: manifest.accountID, teamID: manifest.teamID, vaultID: manifest.vaultID, membershipID: UUID(), membershipEpoch: 1,
            deviceID: device, publicKey: key, browserEvidenceSHA256: String(repeating: "a", count: 64))
        let admissionFile = directory.appending(path: "admission.json")
        try JSONEncoder().encode(value).write(to: admissionFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: admissionFile.path)
        #expect(try StagingNativeAdmissionExpectation.load(directory: directory, manifest: manifest, deviceID: device, publicKey: key).membershipID == value.membershipID)
        #expect(throws: Error.self) { try StagingNativeAdmissionExpectation.load(directory: directory, manifest: manifest, deviceID: UUID(), publicKey: key) }
        let other = try SelectiveRemoteTeamDevicePublicKey(P256.KeyAgreement.PrivateKey().publicKey)
        #expect(throws: Error.self) { try StagingNativeAdmissionExpectation.load(directory: directory, manifest: manifest, deviceID: device, publicKey: other) }
    }
}
