import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

actor PublicationRequestGate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("native publication lifecycle")
struct CloudVaultPublicationPipelineTests {
    @Test("late older account binding cannot overwrite newer login's protected offline identity")
    func accountBinding() async throws {
        let endpoint = URL(string: "https://account-binding-\(UUID()).example.test")!, tokens = SelectiveRemoteCloudMemoryTokenStore()
        let newerAccount = UUID(), olderToken = String(repeating: "o", count: 40), newerToken = String(repeating: "n", count: 40), deviceID = UUID()
        tokens.saveToken(newerToken, for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { _ in throw URLError(.notConnectedToInternet) })
        try await client.rememberPublicationAccount(newerAccount, endpoint: endpoint, token: newerToken)
        // Simulate the older /me protected-storage completion after the newer login's save.
        try await client.rememberPublicationAccount(UUID(), endpoint: endpoint, token: olderToken)
        let session = try #require(try await client.publicationSession(endpoint: endpoint, deviceID: deviceID))
        #expect(session.accountID == newerAccount); try session.check()
    }
    @Test("logout withdraws token before delayed HTTP and cannot clear a later login")
    func logout() async throws {
        let endpoint = URL(string: "https://publication.example.test")!
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(String(repeating: "a", count: 40), for: endpoint)
        let gate = PublicationRequestGate()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            await gate.pause()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })
        let pending = Task { try await client.logout(endpoint: endpoint) }
        while !(await gate.started) { await Task.yield() }
        #expect(store.token(for: endpoint) == nil)
        store.saveToken(String(repeating: "b", count: 40), for: endpoint)
        await gate.release()
        try await pending.value
        #expect(store.token(for: endpoint) == String(repeating: "b", count: 40))
    }
}

@Suite("native linked part materialization")
struct CloudVaultPublicationLinkedPartTests {
    @Test("real source record keeps vector clock and fractional values; cross-generation plaintext is rejected")
    func linkedRecord() throws {
        let url = try #require(Bundle.module.url(forResource: "vault-publication-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: Data(contentsOf: url)).publicationObject()
        let header = fixture["header"]!, descriptor = fixture["descriptor"]!
        let h = try SelectiveRemoteVaultPublicationV1.headerPayload(header), d = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor)
        let id = try d["resourceID"]!.publicationString()
        let record = SelectiveRemoteJSONValue.object(["id": .string(id), "type": .string("host"),
            "version": .object([UUID().canonicalCloudString: .number(2)]), "modifiedAt": .string("2026-10-01T01:00:00.000Z"),
            "data": .object(["title": .string("Linked host"), "address": .string("host.example"), "fraction": .number(1.25)])])
        var link: [String: SelectiveRemoteJSONValue] = ["teamID": h["teamID"]!, "vaultID": h["vaultID"]!, "generationID": h["generationID"]!, "resourceID": d["resourceID"]!, "kind": d["kind"]!, "part": d["part"]!]
        let bytes = try JSONEncoder().encode(SelectiveRemoteJSONValue.object(["link": .object(link), "record": record]))
        let result = try SelectiveRemotePublicationPartDecoder.decode(bytes, descriptor: descriptor, header: header)
        #expect(result.plaintext == bytes)
        link["generationID"] = .string(UUID().canonicalCloudString)
        #expect(throws: SelectiveRemotePublicationError.scope) { try SelectiveRemotePublicationPartDecoder.decode(JSONEncoder().encode(SelectiveRemoteJSONValue.object(["link": .object(link), "record": record])), descriptor: descriptor, header: header) }
    }
}

final class PublicationProtectedMemory: SelectiveRemotePublicationProtectedStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    var fail = false
    var saveHook: (@Sendable (String) -> Void)?
    func read(_ key: String) -> Data? { lock.withLock { data[key] } }
    func save(_ value: Data, key: String) throws { try lock.withLock { if fail { throw CocoaError(.fileWriteUnknown) }; saveHook?(key); data[key] = value } }
}

@Suite("protected publication durability")
struct CloudVaultPublicationDurabilityTests {
    @Test("session change during protected receipt prevents display, preserves HWM and old cleanup cannot remove newer login payload")
    func persistenceSession() async throws {
        let fixture = try PublicationFixture()
        let (reader, _, _, sourceSession, sourceDirectory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner)
        let directory = FileManager.default.temporaryDirectory.appending(path: "task5-cas-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PublicationProtectedMemory(), store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: memory)
        memory.saveHook = { key in if key.hasPrefix("receipt/") { sourceSession.invalidate() } }
        #expect(throws: CancellationError.self) { try store.commit(cache, expected: nil, session: sourceSession) }
        let highWater = try #require(try store.highWater(scope: fixture.scope))
        memory.saveHook = nil
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken(String(repeating: "n", count: 40), for: fixture.scope.endpoint)
        let newer = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: String(repeating: "n", count: 40), tokenStore: tokens)
        #expect(try store.load(scope: fixture.scope, session: newer) == nil)
        let oldStamp = try store.payloadStamp(scope: fixture.scope)
        try store.commit(cache, expected: highWater, session: newer)
        try store.removePayload(scope: fixture.scope, session: sourceSession, expectedStamp: oldStamp)
        #expect(try store.load(scope: fixture.scope, session: newer) == cache)
        #expect(try store.highWater(scope: fixture.scope) == highWater)
        let path = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var bytes = try Data(contentsOf: path); bytes[bytes.count - 1] ^= 1; try bytes.write(to: path)
        #expect(throws: Error.self) { try store.load(scope: fixture.scope, session: newer) }
        #expect(try store.highWater(scope: fixture.scope) == highWater)
    }
    @Test("encrypted durable reopen, CAS and retained high-water survive payload deletion and write failure")
    func durable() throws {
        let f = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "vault-publication-empty-v1", withExtension: "json", subdirectory: "Fixtures")))).publicationObject()
        let subject = try f["subject"]!.publicationObject()
        let scope = SelectiveRemotePublicationScope(endpoint: URL(string: "https://durability.example.test")!, accountID: UUID(uuidString: try subject["accountID"]!.publicationString())!, deviceID: UUID(uuidString: try subject["deviceID"]!.publicationString())!, teamID: UUID(uuidString: try f["teamID"]!.publicationString())!, vaultID: UUID(uuidString: try f["vaultID"]!.publicationString())!)
        let tokenStore = SelectiveRemoteCloudMemoryTokenStore(); tokenStore.saveToken(String(repeating: "a", count: 40), for: scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID, token: String(repeating: "a", count: 40), tokenStore: tokenStore)
        let memory = PublicationProtectedMemory()
        let directory = FileManager.default.temporaryDirectory.appending(path: "task5-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: memory)
        let cache = try SelectiveRemotePublicationCache(scope: scope, teamName: "Private team name", vaultName: "Private vault name", role: .owner, header: f["header"]!, headerHash: SelectiveRemoteVaultPublicationV1.hash("header", f["header"]!), subject: f["subject"]!, inventory: f["inventory"]!, publisher: .null, descriptors: [], readerPublicKey: SelectiveRemoteTeamDevicePublicKey(P256.KeyAgreement.PrivateKey().publicKey), readerKeyVersion: 3, parts: [])
        try store.commit(cache, expected: nil, session: session)
        #expect(try store.load(scope: scope, session: session) == cache)
        let reopened = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: memory)
        #expect(try reopened.load(scope: scope, session: session)?.teamName == "Private team name")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("Private team name"))
        }
        #expect(throws: Error.self) { try store.commit(cache, expected: nil, session: session) }
        let highWater = try #require(try store.highWater(scope: scope))
        try store.removePayload(scope: scope)
        #expect(try reopened.load(scope: scope, session: session) == nil)
        #expect(try reopened.highWater(scope: scope) == highWater)
        memory.fail = true
        #expect(throws: Error.self) { try store.commit(cache, expected: highWater, session: session) }
        #expect(try store.load(scope: scope, session: session) == nil)
        session.invalidate()
        #expect(throws: CancellationError.self) { try store.load(scope: scope, session: session) }
    }
}

actor PublicationPaths { var paths: [String] = []; func append(_ path: String) { paths.append(path) } }
@Suite("actual native publication dispatch")
struct CloudVaultPublicationModeTests {
    @Test("direct native V1 refresh verifies authoritative format before legacy access")
    func mode() async throws {
        let paths = PublicationPaths(), tokens = SelectiveRemoteCloudMemoryTokenStore()
        let endpoint = URL(string: "https://mode.example.test")!, teamID = UUID(), vaultID = UUID()
        tokens.saveToken(String(repeating: "m", count: 40), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            await paths.append(request.url!.path)
            let context = Data(#"{"formatState":"V2_ACTIVE","legacyWholeVault":false,"resource_registry_v2":true,"resource_acl_v2":true,"policyMutationAvailable":false,"groupMutationAvailable":false,"blockers":[]}"#.utf8)
            return (context, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: client, snapshots: SelectiveRemoteTeamVaultMemorySnapshotStore())
        let identity = try SelectiveRemoteTeamDeviceIdentity(deviceID: UUID(), privateKeyRepresentation: P256.KeyAgreement.PrivateKey().rawRepresentation)
        await #expect(throws: Error.self) { try await coordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity) }
        #expect(await paths.paths == ["/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)/access-context"])
    }
}
