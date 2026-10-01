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
    @Test("current 401 cleanup uses protected authorization receipt and cannot erase a later login even after its logout")
    func authenticationLossOwnership() async throws {
        let fixture = try PublicationFixture(), (reader, _, _, _, sourceDirectory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner), directory = FileManager.default.temporaryDirectory.appending(path: "task5-auth-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "o", count: 40)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let old = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: PublicationProtectedMemory())
        try store.commit(cache, expected: nil, session: old)
        let highWater = try store.highWater(scope: fixture.scope)
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: fixture.scope.endpoint); tokens.saveToken(String(repeating: "n", count: 40), for: fixture.scope.endpoint)
        let newer = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: String(repeating: "n", count: 40), tokenStore: tokens)
        try store.commit(cache, expected: highWater, session: newer)
        #expect(throws: CancellationError.self) { try old.prepareAuthenticationLossRetirement() }
        try tokens.removeToken(for: fixture.scope.endpoint); SelectiveRemotePublicationLifecycle.invalidate(endpoint: fixture.scope.endpoint)
        try old.prepareAuthenticationLossRetirement()
        #expect(try store.retireScopes(session: old, selection: .all).isEmpty)
        tokens.saveToken(String(repeating: "n", count: 40), for: fixture.scope.endpoint)
        let checking = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: String(repeating: "n", count: 40), tokenStore: tokens)
        #expect(try store.load(scope: fixture.scope, session: checking) == cache)
        #expect(try store.cachedScopes(session: checking) == [fixture.scope]); #expect(try store.highWater(scope: fixture.scope) == highWater)
        #expect(throws: CancellationError.self) { try store.retireScopes(session: old, selection: .all) }
    }
    @MainActor
    @Test("list retirement is exact, protected-write failure cannot reopen revoked data, and old login cannot retire newer ownership")
    func listRetirementOwnership() async throws {
        let fixture = try PublicationFixture(allKinds: true), (reader, _, _, old, sourceDirectory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner)
        let directory = FileManager.default.temporaryDirectory.appending(path: "task5-retirement-cas-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PublicationProtectedMemory(), store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: memory)
        try store.commit(cache, expected: nil, session: old)
        let highWater = try store.highWater(scope: fixture.scope)
        #expect(try store.retireScopes(session: old, selection: .vault(teamID: UUID(), vaultID: UUID())).isEmpty)
        #expect(try store.retireScopes(session: old, selection: .teamsExcept([fixture.scope.teamID])).isEmpty)
        #expect(try store.load(scope: fixture.scope, session: old) == cache)
        memory.fail = true
        #expect(throws: Error.self) { try store.retireScopes(session: old, selection: .all) }
        #expect(try store.load(scope: fixture.scope, session: old) == nil)
        #expect(try store.highWater(scope: fixture.scope) == highWater)
        memory.fail = false
        try store.commit(cache, expected: highWater, session: old)
        memory.saveHook = { key in if key.hasPrefix("receipt/") { old.invalidate() } }
        #expect(throws: CancellationError.self) { try store.retireScopes(session: old, selection: .all) }
        memory.saveHook = nil
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken(String(repeating: "n", count: 40), for: fixture.scope.endpoint)
        let newer = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: String(repeating: "n", count: 40), tokenStore: tokens)
        try store.commit(cache, expected: highWater, session: newer)
        let presentation = SelectiveRemotePublicationPresentation(), snapshot = try cache.materializedSnapshot()
        defer { presentation.detach(scope: fixture.scope, expectedSession: newer) }
        try presentation.bind(reader: reader, session: newer, scope: fixture.scope); presentation.replace(with: [snapshot])
        SelectiveRemoteTeamHostStore.shared.replaceVault(with: snapshot); SelectiveRemoteTeamSnippetStore.shared.replaceVault(with: snapshot); SelectiveRemoteTeamCredentialStore.shared.replaceVault(with: snapshot)
        #expect(throws: CancellationError.self) { try store.retireScopes(session: old, selection: .all) }
        presentation.detach(scope: fixture.scope, expectedSession: old)
        #expect(try store.load(scope: fixture.scope, session: newer) == cache)
        #expect(presentation.caches.contains { $0.scope == fixture.scope })
        #expect(SelectiveRemoteTeamHostStore.shared.hosts.contains { $0.vaultID == fixture.scope.vaultID })
        #expect(try store.highWater(scope: fixture.scope) == highWater)
        _ = try store.retireScopes(session: newer, selection: .vault(teamID: fixture.scope.teamID, vaultID: fixture.scope.vaultID))
        presentation.detach(scope: fixture.scope, expectedSession: newer)
        #expect(try store.cachedScopes(session: newer).isEmpty)
        #expect(!presentation.caches.contains { $0.scope == fixture.scope })
        #expect(!SelectiveRemoteTeamHostStore.shared.hosts.contains { $0.vaultID == fixture.scope.vaultID })
        #expect(!SelectiveRemoteTeamSnippetStore.shared.snippets.contains { $0.vaultID == fixture.scope.vaultID })
        #expect(!SelectiveRemoteTeamCredentialStore.shared.credentials.contains { $0.vaultID == fixture.scope.vaultID })
    }
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
