import CryptoKit
import Foundation
import Security
import Testing
@testable import SelectiveRemote

@Suite("native host review regressions")
struct StagingNativeGUIHostRevisionTests {
    @Test("approved ordinary email accepted; outside runtime allowlist denied")
    func approvedEmail() throws {
        let fixture = try NativeRevisionFixture(); defer { fixture.remove() }
        #expect(try StagingNativeManifest.load(path: fixture.path.path)?.0.email == "native.member@example.test")
        var wrong = fixture.object; wrong["email"] = "outside@example.test"
        try fixture.write(wrong)
        #expect(throws: Error.self) { try StagingNativeManifest.load(path: fixture.path.path) }
    }
    @Test("latest attempt failure always clears accepted generation and rendered models", arguments: ["401", "403", "scope", "generation", "SECRET", "publisher"])
    func staleSuccess(_ fault: String) throws {
        var state = StagingNativeAcceptance()
        let first = UUID(), second = UUID()
        state.begin(first)
        try state.accept(first, manifestSHA256: String(repeating: "a", count: 64), sequence: 1, headerHash: String(repeating: "b", count: 64), generationID: UUID(), secretsVerified: 1, requiredSecrets: 1, rows: ["synthetic"])
        #expect(state.canFinish(manifestSHA256: String(repeating: "a", count: 64)))
        state.begin(second)
        #expect(state.accepted == nil)
        #expect(state.rows.isEmpty)
        #expect(!state.canFinish(manifestSHA256: String(repeating: "a", count: 64)))
        state.fail(second)
        #expect(!state.canFinish(manifestSHA256: String(repeating: "a", count: 64)))
        #expect(state.rows.isEmpty)
        #expect(state.accepted == nil)
    }
    @Test("changed intended manifest, incomplete SECRET count and stale attempt cannot Finish")
    func immutableExpectation() throws {
        var state = StagingNativeAcceptance(); let first = UUID(), next = UUID()
        state.begin(first)
        #expect(throws: Error.self) { try state.accept(first, manifestSHA256: String(repeating: "a", count: 64), sequence: 1, headerHash: String(repeating: "b", count: 64), generationID: UUID(), secretsVerified: 0, requiredSecrets: 1, rows: ["synthetic"]) }
        state.begin(next)
        #expect(throws: Error.self) { try state.accept(first, manifestSHA256: String(repeating: "a", count: 64), sequence: 1, headerHash: String(repeating: "b", count: 64), generationID: UUID(), secretsVerified: 1, requiredSecrets: 1, rows: ["synthetic"]) }
        try state.accept(next, manifestSHA256: String(repeating: "a", count: 64), sequence: 2, headerHash: String(repeating: "c", count: 64), generationID: UUID(), secretsVerified: 1, requiredSecrets: 1, rows: ["synthetic"])
        #expect(!state.canFinish(manifestSHA256: String(repeating: "d", count: 64)))
    }
    @Test("recovery reopens original key/token/pin at each persisted checkpoint", arguments: ["identity", "login", "admission", "materialized"])
    func recovery(_ stage: String) async throws {
        let fixture = try NativeRevisionFixture(); defer { fixture.remove() }
        let (manifest, _) = try #require(try StagingNativeManifest.load(path: fixture.path.path))
        let storage = PublicationProtectedMemory()
        let fresh = try StagingNativeCheckpoint.reserve(manifest: manifest, storage: storage, processID: UUID())
        let stores = StagingNativeStores(endpoint: manifest.endpoint, accountID: manifest.accountID, deviceID: fresh.deviceID, storage: storage)
        let identity = try await SelectiveRemoteTeamDeviceIdentityManager(store: stores).identity(endpoint: manifest.endpoint, deviceID: fresh.deviceID)
        if stage != "identity" { try stores.saveToken(String(repeating: "t", count: 64), for: manifest.endpoint) }
        let pin = SelectiveRemoteDeviceTrustPin(accountID: manifest.accountID, rootFingerprint: manifest.rootFingerprint, highWater: 3, checkpointDigest: manifest.checkpointDigest)
        if ["admission", "materialized"].contains(stage) {
            _ = try stores.savePinIfAbsent(pin, endpoint: manifest.endpoint)
            try stores.save(Data("public-admission-marker".utf8), key: "admission")
        }
        try fresh.advanced(stage: stage, publicKey: identity.publicKey, pin: try stores.pin(endpoint: manifest.endpoint, accountID: manifest.accountID)).save(storage: storage)
        let recovered = try StagingNativeCheckpoint.recover(manifest: manifest, storage: storage)
        #expect(recovered.deviceID == identity.deviceID)
        #expect(recovered.publicKey == identity.publicKey)
        #expect(try stores.privateKeyRepresentation(for: manifest.endpoint, deviceID: identity.deviceID) == identity.privateKey.rawRepresentation)
        #expect(try stores.pin(endpoint: manifest.endpoint, accountID: manifest.accountID) == (["admission", "materialized"].contains(stage) ? pin : nil))
    }
    @Test("actual isolated Keychain checkpoint recovery retains original identity and durable high-water",
          .enabled(if: ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_NATIVE_GUI_LOCAL_KEYCHAIN"] == "1"),
          arguments: ["identity", "login", "admission", "materialized"])
    func actualRecovery(_ stage: String) async throws {
        let fixture = try NativeRevisionFixture(); defer { fixture.remove() }
        let (manifest, directory) = try #require(try StagingNativeManifest.load(path: fixture.path.path))
        let service = "org.pastfly.SelectiveRemote.NativeGUI.TEST-ONLY.recovery-" + UUID().uuidString
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                               kSecAttrSynchronizable as String: false] as CFDictionary) }
        let storage = StagingNativeKeychain(service: service, accountID: manifest.accountID)
        let checkpoint = try StagingNativeCheckpoint.reserve(manifest: manifest, storage: storage, processID: UUID())
        let stores = StagingNativeStores(endpoint: manifest.endpoint, accountID: manifest.accountID, deviceID: checkpoint.deviceID, storage: storage)
        let original = try await SelectiveRemoteTeamDeviceIdentityManager(store: stores).identity(endpoint: manifest.endpoint, deviceID: checkpoint.deviceID)
        let token = String(repeating: "synthetic-local-session-", count: 3)
        if stage != "identity" { try stores.saveToken(token, for: manifest.endpoint) }
        let pin = SelectiveRemoteDeviceTrustPin(accountID: manifest.accountID, rootFingerprint: manifest.rootFingerprint,
            highWater: 7, checkpointDigest: manifest.checkpointDigest)
        if ["admission", "materialized"].contains(stage) {
            _ = try stores.savePinIfAbsent(pin, endpoint: manifest.endpoint)
            try stores.save(Data("synthetic-admission-checkpoint".utf8), key: "admission")
        }
        let cache = directory.appending(path: "native-cache")
        let publication = try SelectiveRemoteVaultPublicationStore(directory: cache, protected: stores)
        let scope = manifest.scope(deviceID: checkpoint.deviceID)
        let water = SelectiveRemotePublicationHighWater(sequence: 9, hash: String(repeating: "d", count: 64))
        if stage == "materialized" {
            let session = try #require(try stores.isolatedPublicationSession(endpoint: manifest.endpoint, token: token, deviceID: checkpoint.deviceID))
            try publication.advanceHighWater(water, expected: nil, scope: scope, session: session)
        }
        try checkpoint.advanced(stage: stage, publicKey: original.publicKey, pin: try stores.pin(endpoint: manifest.endpoint, accountID: manifest.accountID)).save(storage: storage)
        let before = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
        let reopenedStorage = StagingNativeKeychain(service: service, accountID: manifest.accountID)
        let recovered = try StagingNativeCheckpoint.recover(manifest: manifest, storage: reopenedStorage)
        let reopened = StagingNativeStores(endpoint: manifest.endpoint, accountID: manifest.accountID, deviceID: recovered.deviceID, storage: reopenedStorage)
        let sameIdentity = try await SelectiveRemoteTeamDeviceIdentityManager(store: reopened).identity(endpoint: manifest.endpoint, deviceID: recovered.deviceID)
        #expect(sameIdentity.deviceID == original.deviceID && sameIdentity.publicKey == original.publicKey)
        #expect(recovered.originatingProcessID == checkpoint.originatingProcessID)
        #expect(try reopened.token(for: manifest.endpoint) == (stage == "identity" ? nil : token))
        #expect(try reopened.pin(endpoint: manifest.endpoint, accountID: manifest.accountID) == (["admission", "materialized"].contains(stage) ? pin : nil))
        let reopenedPublication = try SelectiveRemoteVaultPublicationStore(directory: cache, protected: reopened)
        #expect(try reopenedPublication.highWater(scope: scope) == (stage == "materialized" ? water : nil))
        for (name, bytes) in before { #expect(try Data(contentsOf: cache.appending(path: name)) == bytes) }
        print("NATIVE_GUI_LOCAL_RECOVERY stage=\(stage) originalIdentity=true retainedTrust=true retainedCacheHighWater=true network=false")
    }
    @Test("recovery fails closed on missing identity/token, swapped device and trust rollback/fork", arguments: ["identity", "token", "device", "rollback", "fork"])
    func recoveryRejects(_ fault: String) async throws {
        let fixture = try NativeRevisionFixture(); defer { fixture.remove() }
        let (manifest, _) = try #require(try StagingNativeManifest.load(path: fixture.path.path))
        let storage = PublicationProtectedMemory()
        let checkpoint = try StagingNativeCheckpoint.reserve(manifest: manifest, storage: storage, processID: UUID())
        let stores = StagingNativeStores(endpoint: manifest.endpoint, accountID: manifest.accountID, deviceID: checkpoint.deviceID, storage: storage)
        let key = try await SelectiveRemoteTeamDeviceIdentityManager(store: stores).identity(endpoint: manifest.endpoint, deviceID: checkpoint.deviceID)
        try stores.saveToken(String(repeating: "t", count: 64), for: manifest.endpoint)
        let pin = SelectiveRemoteDeviceTrustPin(accountID: manifest.accountID, rootFingerprint: manifest.rootFingerprint, highWater: 7, checkpointDigest: manifest.checkpointDigest)
        _ = try stores.savePinIfAbsent(pin, endpoint: manifest.endpoint)
        try stores.save(Data("synthetic-admission-checkpoint".utf8), key: "admission")
        try checkpoint.advanced(stage: "admission", publicKey: key.publicKey, pin: pin).save(storage: storage)
        if fault == "identity" { try stores.save(Data(), key: "identity") }
        if fault == "token" { try stores.removeToken(for: manifest.endpoint) }
        if fault == "device" { try storage.save(Data(UUID().uuidString.utf8), key: "device-id") }
        if ["rollback", "fork"].contains(fault) {
            let bad = SelectiveRemoteDeviceTrustPin(accountID: manifest.accountID, rootFingerprint: manifest.rootFingerprint,
                highWater: fault == "rollback" ? 6 : 7, checkpointDigest: Data(repeating: 9, count: 32).selectiveRemoteBase64URL)
            // Simulate corrupt persisted bytes directly; the public CAS itself already rejects these writes.
            try stores.save(JSONEncoder().encode(bad), key: "pin")
        }
        #expect(throws: Error.self) { try StagingNativeCheckpoint.recover(manifest: manifest, storage: storage) }
    }
    @Test("only verified canonical executable SwiftPM test images inside build directory are accepted", arguments: ["SelectiveRemoteTests", "SelectiveRemotePackageTests"])
    func verifiedBundleLayouts(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let build = root.appending(path: ".build")
        let executable = build.appending(path: "debug/" + name + ".xctest/Contents/MacOS/" + name)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic test image".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(try StagingNativeExecutableIdentity.validatedTestBundle(executable.path, buildDirectory: build) == executable)
        #expect(throws: Error.self) { try StagingNativeExecutableIdentity.validatedTestBundle(executable.path, buildDirectory: root.appending(path: "other")) }
        let link = build.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        #expect(throws: Error.self) { try StagingNativeExecutableIdentity.validatedTestBundle(link.path, buildDirectory: build) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        #expect(throws: Error.self) { try StagingNativeExecutableIdentity.validatedTestBundle(executable.path, buildDirectory: build) }
    }
    @Test("executable identity comes from the running process and loaded test image")
    func actualBinary() throws {
        let actual = try StagingNativeExecutableIdentity.current()
        #expect(try StagingNativeExecutableIdentity.validatedTestBundle(actual.testBundlePath,
            buildDirectory: StagingNativeExecutableIdentity.buildDirectory).path == actual.testBundlePath)
        #expect(StagingRealProbeConfig.hash(actual.executableSHA256))
        #expect(StagingRealProbeConfig.hash(actual.testBundleSHA256))
    }
}

struct NativeRevisionFixture {
    let root: URL; let directory: URL; let path: URL; var object: [String: Any]
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        directory = root.appending(path: "TEST-ONLY-CODEX-native-review")
        path = directory.appending(path: "manifest.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let vault = UUID().uuidString, runtime = directory.appending(path: "approved-runtime.json")
        let approval: [String: Any] = ["version": 1, "runID": "native-review", "origin": "https://cloud.pastfly.ru", "emails": ["custodian@example.test", "native.member@example.test"], "approvedVaultIDs": [vault], "expectedSourceSHA": String(repeating: "a", count: 40), "moduleHashes": [:], "operator": [:]]
        try JSONSerialization.data(withJSONObject: approval).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtime.path)
        object = ["formatVersion": 1, "runID": "TEST-ONLY-CODEX-native-review", "testIdentityCreatedForRun": "TEST-ONLY-CODEX-native-review", "endpoint": "https://cloud.pastfly.ru", "accountID": UUID().uuidString, "email": "native.member@example.test", "approvedRuntimeConfigPath": runtime.path, "teamID": UUID().uuidString, "vaultID": vault, "teamName": "TEST-ONLY-CODEX-native-review-team", "vaultName": "TEST-ONLY-CODEX-native-review-populated", "rootFingerprint": String(repeating: "a", count: 64), "checkpointDigest": Data(repeating: 1, count: 32).selectiveRemoteBase64URL, "generationID": UUID().uuidString, "sequence": 1, "headerHash": String(repeating: "b", count: 64), "counts": ["hosts": 1, "snippets": 1, "credentials": 1, "forwardings": 1, "folders": 1], "secrets": [["resourceID": UUID().uuidString, "sha256": String(repeating: "c", count: 64)]]]
        try write(object)
    }
    func write(_ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value).write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
