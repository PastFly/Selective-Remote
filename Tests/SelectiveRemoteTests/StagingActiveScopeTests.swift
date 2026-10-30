import Foundation
import Testing
@testable import SelectiveRemote

private actor StagingScopeTransport {
    let scope: SelectiveRemotePublicationScope
    let accountID: UUID
    let teams: [SelectiveRemoteCloudTeam]
    let vaults: [SelectiveRemoteCloudSharedVault]
    private(set) var paths: [String] = []
    init(scope: SelectiveRemotePublicationScope, accountID: UUID, teams: [SelectiveRemoteCloudTeam], vaults: [SelectiveRemoteCloudSharedVault] = []) {
        self.scope = scope; self.accountID = accountID; self.teams = teams; self.vaults = vaults
    }
    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard request.url?.host == scope.endpoint.host,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "s", count: 40)
        else { throw StagingRealProbeError.acceptance }
        let path = request.url!.path; paths.append(path)
        let data: Data
        switch path {
        case "/v1/me": data = try JSONSerialization.data(withJSONObject: ["id": accountID.canonicalCloudString, "deviceID": scope.deviceID.canonicalCloudString, "email": "test@example.test", "username": "testmember", "displayName": "Test Member"])
        case "/v1/teams": data = try JSONEncoder().encode(["teams": teams])
        case "/v1/teams/\(scope.teamID.canonicalCloudString)/vaults": data = try JSONEncoder().encode(["vaults": vaults])
        default: throw StagingRealProbeError.acceptance
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("staging ACTIVE scope admission")
struct StagingActiveScopeTests {
    private let runID = "TEST-ONLY-CODEX-active-scope"
    private var teamName: String { runID + "-team" }
    private var vaultName: String { runID + "-vault" }
    private func team(_ f: PublicationFixture) throws -> SelectiveRemoteCloudTeam {
        let subject = try f.headerResponse.publicationObject()["subject"]!.publicationObject()
        return .init(id: f.scope.teamID, name: teamName,
            membershipID: UUID(uuidString: try subject["membershipID"]!.publicationString())!, role: .viewer,
            membershipEpoch: 2, createdAt: "2026-10-08T00:00:00Z", updatedAt: "2026-10-08T00:00:00Z")
    }
    private func client(_ f: PublicationFixture, _ transport: StagingScopeTransport) -> SelectiveRemoteCloudAPIClient {
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "s", count: 40), for: f.scope.endpoint)
        return .init(tokenStore: tokens, dataLoader: { try await transport.load($0) })
    }
    private func authorize(_ f: PublicationFixture, _ transport: StagingScopeTransport, legacy: Bool,
                           membership: (UUID, Int)?) async throws -> SelectiveRemoteCloudTeam {
        try await StagingRealProbe.authorizedTeam(client: client(f, transport), scope: f.scope,
            runID: runID, teamName: teamName, vaultName: vaultName, requireLegacyVault: legacy, membership: membership)
    }

    private func manifest(_ f: PublicationFixture) throws -> StagingNativeManifest {
        let header = try SelectiveRemoteVaultPublicationV1.headerPayload(f.headerResponse.publicationObject()["header"]!)
        return .init(formatVersion: 1, runID: runID, testIdentityCreatedForRun: runID, endpoint: f.scope.endpoint,
            accountID: f.scope.accountID, email: "test@example.test", approvedRuntimeConfigPath: "/unused-local-fixture",
            teamID: f.scope.teamID, vaultID: f.scope.vaultID, teamName: teamName, vaultName: vaultName,
            rootFingerprint: f.ownPin.rootFingerprint, checkpointDigest: f.ownPin.checkpointDigest,
            generationID: UUID(uuidString: try header["generationID"]!.publicationString())!, sequence: 1,
            headerHash: try f.headerResponse.publicationObject()["headerHash"]!.publicationString(),
            counts: .init(hosts: 0, snippets: 0, credentials: 1, forwardings: 0, folders: 0), secrets: [])
    }
    private func admission(_ f: PublicationFixture, _ member: SelectiveRemoteCloudTeam) -> StagingNativeAdmissionExpectation {
        .init(source: "BROWSER_CUSTODIAN_HTTPS_ADMISSION_READBACK", runID: runID, accountID: f.scope.accountID,
            teamID: f.scope.teamID, vaultID: f.scope.vaultID, membershipID: member.membershipID,
            membershipEpoch: member.membershipEpoch, deviceID: f.scope.deviceID, publicKey: f.identity.publicKey,
            browserEvidenceSHA256: String(repeating: "a", count: 64))
    }

    @Test("recovered protected checkpoint chooses preadmission inventory or retained ACTIVE admission", arguments: ["login", "approval", "admission", "materialized"])
    func recoveryPhase(_ stage: String) async throws {
        let f = try PublicationFixture(), expected = try team(f), manifest = try manifest(f)
        let memory = PublicationProtectedMemory()
        let stores = StagingNativeStores(endpoint: f.scope.endpoint, accountID: f.scope.accountID, deviceID: f.scope.deviceID, storage: memory)
        _ = try stores.savePrivateKeyIfAbsent(f.identity.privateKey.rawRepresentation, for: f.scope.endpoint, deviceID: f.scope.deviceID)
        try stores.saveToken(String(repeating: "s", count: 40), for: f.scope.endpoint)
        _ = try stores.savePinIfAbsent(f.ownPin, endpoint: f.scope.endpoint)
        let retained = admission(f, expected)
        if ["admission", "materialized"].contains(stage) { try stores.save(JSONEncoder().encode(retained), key: "admission") }
        try memory.save(Data(f.scope.deviceID.uuidString.utf8), key: "device-id")
        try StagingNativeCheckpoint(runID: runID, accountID: f.scope.accountID, teamID: f.scope.teamID,
            vaultID: f.scope.vaultID, email: manifest.email, endpoint: f.scope.endpoint,
            rootFingerprint: f.ownPin.rootFingerprint, deviceID: f.scope.deviceID, originatingProcessID: UUID(),
            stage: stage, publicKey: f.identity.publicKey, ownPin: f.ownPin).save(storage: memory)
        let checkpoint = try StagingNativeCheckpoint.recover(manifest: manifest, storage: memory)
        let transport = StagingScopeTransport(scope: f.scope, accountID: f.scope.accountID, teams: [expected])
        if ["login", "approval"].contains(stage) {
            await #expect(throws: StagingRealProbeError.scope) {
                try await manifest.authorizedTeam(client: client(f, transport), stores: stores,
                    identity: f.identity, requireLegacyVault: checkpoint.recoveryRequiresLegacyVault)
            }
            #expect(await transport.paths.contains("/v1/teams/\(f.scope.teamID.canonicalCloudString)/vaults"))
        } else {
            let current = try await manifest.authorizedTeam(client: client(f, transport), stores: stores,
                identity: f.identity, requireLegacyVault: checkpoint.recoveryRequiresLegacyVault)
            #expect(current.membershipID == expected.membershipID)
            #expect(await transport.paths.allSatisfy { !$0.hasSuffix("/vaults") })
            // Persisted admission must match the protected target/key and live membership epoch.
            let otherKey = try PublicationFixture().identity.publicKey
            for key in ["accountID", "teamID", "vaultID", "deviceID", "publicKey", "membershipID", "membershipEpoch"] {
                var altered = try JSONSerialization.jsonObject(with: JSONEncoder().encode(retained)) as! [String: Any]
                if key == "membershipEpoch" { altered[key] = 3 }
                else if key == "publicKey" { altered[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(otherKey)) }
                else { altered[key] = UUID().canonicalCloudString }
                try stores.save(JSONSerialization.data(withJSONObject: altered), key: "admission")
                await #expect(throws: StagingRealProbeError.scope) {
                    try await manifest.authorizedTeam(client: client(f, transport), stores: stores,
                        identity: f.identity, requireLegacyVault: checkpoint.recoveryRequiresLegacyVault)
                }
            }
        }
    }

    @Test("ACTIVE signed decrypt and reopened recovery succeed when V1 inventory omits target")
    func activeAndRecovery() async throws {
        let f = try PublicationFixture(), expected = try team(f)
        // This is the legitimate legacy response after cutover; the target is absent.
        let transport = StagingScopeTransport(scope: f.scope, accountID: f.scope.accountID, teams: [expected])
        let directory = FileManager.default.temporaryDirectory.appending(path: "TEST-ONLY-CODEX-active-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PublicationProtectedMemory()
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: memory)
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "x", count: 40)
        tokens.saveToken(token, for: f.scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: f.scope.endpoint, accountID: f.scope.accountID,
            deviceID: f.scope.deviceID, token: token, tokenStore: tokens)
        let remote = PublicationFixtureRemote(f), pin = f.ownPin
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: f.scope, session: session, remote: remote,
            identity: f.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        let manifest = try manifest(f)
        let nativeStores = StagingNativeStores(endpoint: f.scope.endpoint, accountID: f.scope.accountID,
            deviceID: f.scope.deviceID, storage: memory)
        try nativeStores.saveToken(String(repeating: "s", count: 40), for: f.scope.endpoint)
        try nativeStores.save(JSONEncoder().encode(admission(f, expected)), key: "admission")
        let current = try await manifest.authorizedTeam(client: client(f, transport), stores: nativeStores,
            identity: f.identity, requireLegacyVault: false)
        let cache = try await reader.load(teamName: current.name, vaultName: vaultName, role: current.role)
        #expect(try cache.credentials().count == 1)
        #expect(try await reader.reveal(resourceID: f.resourceID) == "test-only-secret")
        // The separately labeled API probe has no native retained admission file.
        let auxiliary = try await authorize(f, transport, legacy: false, membership: nil)
        let probed = try await reader.load(teamName: auxiliary.name, vaultName: vaultName, role: auxiliary.role)
        #expect(probed.scope == f.scope); #expect(probed.headerHash == cache.headerHash)
        #expect(await remote.requests.contains("header"))
        #expect(await remote.requests.contains("directory"))
        // New reader/store instances exercise the actual durable cache recovery path.
        let reopenedStore = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: memory)
        let reopened = SelectiveRemoteVaultPublicationCoordinator(scope: f.scope, session: session, remote: remote,
            identity: f.identity, store: reopenedStore, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        let recovered = try await authorize(f, transport, legacy: false, membership: (expected.membershipID, 2))
        let offline = try await reopened.offline()
        #expect(offline.stale); #expect(try offline.credentials().count == 1)
        let fresh = try await reopened.load(teamName: recovered.name, vaultName: vaultName, role: recovered.role)
        #expect(!fresh.stale); #expect(fresh.headerHash == cache.headerHash)
        #expect(await transport.paths.allSatisfy { !$0.hasSuffix("/vaults") })
    }

    @Test("preadmission still requires V1 inventory; ACTIVE never falls back after an identity denial")
    func legacyAndIdentityNegatives() async throws {
        let f = try PublicationFixture(), expected = try team(f)
        let omitted = StagingScopeTransport(scope: f.scope, accountID: f.scope.accountID, teams: [expected])
        await #expect(throws: StagingRealProbeError.scope) {
            try await authorize(f, omitted, legacy: true, membership: nil)
        }
        #expect(await omitted.paths.contains("/v1/teams/\(f.scope.teamID.canonicalCloudString)/vaults"))
        let vault = SelectiveRemoteCloudSharedVault(id: f.scope.vaultID, teamID: f.scope.teamID, name: vaultName,
            revision: 1, keyGeneration: 1, rotationRequired: false, createdAt: "2026-10-08", updatedAt: "2026-10-08")
        let present = StagingScopeTransport(scope: f.scope, accountID: f.scope.accountID, teams: [expected], vaults: [vault])
        #expect(try await authorize(f, present, legacy: true, membership: nil).id == f.scope.teamID)
        for fault in ["account", "missing-team", "team-scope", "team-name", "membership", "epoch"] {
            var changed = expected
            if fault == "team-scope" { changed.id = UUID() }
            if fault == "team-name" { changed.name = runID + "-other" }
            if fault == "membership" { changed.membershipID = UUID() }
            if fault == "epoch" { changed.membershipEpoch = 3 }
            let rejected = StagingScopeTransport(scope: f.scope, accountID: fault == "account" ? UUID() : f.scope.accountID,
                teams: fault == "missing-team" ? [] : [changed])
            await #expect(throws: StagingRealProbeError.scope) {
                try await authorize(f, rejected, legacy: false, membership: (expected.membershipID, 2))
            }
            #expect(await rejected.paths.allSatisfy { !$0.hasSuffix("/vaults") })
        }
    }

    @Test("postactivation target remains bound to signed scope and current trust")
    func signedScopeAndTrustNegatives() async throws {
        let f = try PublicationFixture(), expected = try team(f)
        let transport = StagingScopeTransport(scope: f.scope, accountID: f.scope.accountID, teams: [expected])
        _ = try await authorize(f, transport, legacy: false, membership: (expected.membershipID, 2))
        let (_, remote, store, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(f)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pin = f.ownPin
        let foreign = SelectiveRemotePublicationScope(endpoint: f.scope.endpoint, accountID: f.scope.accountID,
            deviceID: f.scope.deviceID, teamID: f.scope.teamID, vaultID: UUID())
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: foreign, session: session, remote: remote,
            identity: f.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        await #expect(throws: Error.self) { try await reader.load(teamName: expected.name, vaultName: vaultName, role: expected.role) }
        #expect(try store.load(scope: foreign, session: session) == nil)
        let untrusted = SelectiveRemoteVaultPublicationCoordinator(scope: f.scope, session: session, remote: remote,
            identity: f.identity, store: store, ownPin: { _, _ in nil }, advanceOwnPin: { _, _, _ in })
        await #expect(throws: Error.self) { try await untrusted.load(teamName: expected.name, vaultName: vaultName, role: expected.role) }
    }
}
