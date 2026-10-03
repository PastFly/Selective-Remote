import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("native publication defensive correctness")
struct CloudVaultPublicationDefensiveTests {
    @MainActor
    @Test("reader replacement before display rejects old generation before explicit reads or actions")
    func generationBinding() async throws {
        let first = try PublicationFixture(allKinds: true, transport: "telnet")
        let second = try PublicationFixture(allKinds: true, transport: "telnet", sameAccountAs: first, sameVault: true)
        let (reader, _, store, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(first)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let remote = PublicationFixtureRemote(second), pin = second.ownPin
        let replacement = SelectiveRemoteVaultPublicationCoordinator(scope: second.scope, session: session, remote: remote, identity: second.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        let next = try await replacement.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let reference = try old.reference(try #require(old.parts.first { $0.kind == .credential }))
        let host = try #require(try SelectiveRemoteTeamHostMaterializer.materialize(old.materializedSnapshot()).first)
        let presentation = SelectiveRemotePublicationPresentation()
        try presentation.bind(reader: reader, session: session, scope: first.scope, cache: old)
        presentation.replace(with: [try old.materializedSnapshot()])
        #expect(presentation.valid(reference))
        try presentation.bind(reader: replacement, session: session, scope: second.scope, cache: next)
        #expect(!presentation.valid(reference))
        await #expect(throws: Error.self) { try await presentation.reveal(reference) }
        var acted = false
        await #expect(throws: Error.self) { try await presentation.performHostConnection(host) { _ in acted = true } }
        #expect(!acted)
        #expect(await remote.requests.filter { $0.hasSuffix("/SECRET") }.isEmpty)
        presentation.replace(with: [try next.materializedSnapshot()])
        let current = try next.reference(try #require(next.parts.first { $0.kind == .credential }))
        #expect(presentation.valid(current))
        #expect(try await presentation.reveal(current) == "test-only-secret")
        let matchingHost = try #require(try SelectiveRemoteTeamHostMaterializer.materialize(next.materializedSnapshot()).first)
        try await presentation.performHostConnection(matchingHost) { _ in acted = true }
        #expect(acted)
        _ = try await replacement.offline()
        presentation.replace(with: [try await replacement.offline().materializedSnapshot()])
        #expect(!presentation.valid(current))
        session.invalidate()
        #expect(!presentation.valid(current))
    }

    @MainActor
    @Test("binding replacement during awaited explicit read cancels result and action", arguments: [false, true])
    func bindingChangesDuringRead(_ hostAction: Bool) async throws {
        let fixture = try PublicationFixture(allKinds: true)
        let (reader, remote, store, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let reference = try cache.reference(try #require(cache.parts.first { $0.kind == .credential }))
        let host = try #require(try SelectiveRemoteTeamHostMaterializer.materialize(cache.materializedSnapshot()).first)
        let presentation = SelectiveRemotePublicationPresentation()
        try presentation.bind(reader: reader, session: session, scope: fixture.scope, cache: cache)
        presentation.replace(with: [try cache.materializedSnapshot()])
        let gate = PublicationRequestGate()
        await remote.setHook { route in if route.hasSuffix("/SECRET") { await gate.pause() } }
        var acted = false
        let pending = Task { @MainActor in
            if hostAction { try await presentation.performHostConnection(host) { _ in acted = true } }
            else { _ = try await presentation.reveal(reference) }
        }
        while !(await gate.started) { await Task.yield() }
        let pin = fixture.ownPin
        let replacement = SelectiveRemoteVaultPublicationCoordinator(scope: fixture.scope, session: session, remote: PublicationFixtureRemote(fixture), identity: fixture.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        _ = try await replacement.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        try presentation.bind(reader: replacement, session: session, scope: fixture.scope, cache: cache)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!acted)
        #expect(presentation.secret(reference) == nil)
    }

    @Test("current same-account login retires captured payloads created by previous token")
    func priorLoginOwnedRetirement() async throws {
        let fixture = try PublicationFixture(), (reader, _, _, _, sourceDirectory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let directory = FileManager.default.temporaryDirectory.appending(path: "defensive-prior-login-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: PublicationProtectedMemory())
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), oldToken = String(repeating: "a", count: 40), token = String(repeating: "b", count: 40)
        tokens.saveToken(oldToken, for: fixture.scope.endpoint)
        let prior = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: oldToken, tokenStore: tokens)
        try store.commit(cache, expected: nil, session: prior)
        let highWater = try store.highWater(scope: fixture.scope)
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: fixture.scope.endpoint)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let current = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        #expect(try store.load(scope: fixture.scope, session: current) == cache)
        try store.captureRetirementOwners(session: current)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            (Data(#"{"error":"authentication_required"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) { try await client.teams(endpoint: fixture.scope.endpoint) }
        try current.prepareAuthenticationLossRetirement()
        #expect(try store.retireScopes(session: current, selection: .all) == [fixture.scope])
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let checking = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        #expect(try store.load(scope: fixture.scope, session: checking) == nil)
        #expect(try store.highWater(scope: fixture.scope) == highWater)
    }
    @Test("current authenticated 401 retires every captured account scope including preflight me", arguments: ["me", "sharedVaults", "format", "publication", "secret", "receipt-failure"])
    func accountWideAuthenticationLoss(_ stage: String) async throws {
        let fixture = try PublicationFixture(), other = try PublicationFixture(sameAccountAs: fixture, sameTeam: false)
        let directory = FileManager.default.temporaryDirectory.appending(path: "defensive-current-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PublicationProtectedMemory(), store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: memory)
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), oldToken = String(repeating: "a", count: 40), token = String(repeating: "b", count: 40)
        tokens.saveToken(oldToken, for: fixture.scope.endpoint)
        let prior = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: oldToken, tokenStore: tokens)
        var waters: [SelectiveRemotePublicationHighWater?] = []
        for value in [fixture, other] {
            let pin = value.ownPin
            let reader = SelectiveRemoteVaultPublicationCoordinator(scope: value.scope, session: prior, remote: PublicationFixtureRemote(value), identity: value.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
            _ = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
            waters.append(try store.highWater(scope: value.scope))
        }
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: fixture.scope.endpoint)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let accountID = fixture.scope.accountID
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            let isMe = request.url!.path.hasSuffix("/me"), success = isMe && stage != "me"
            let body: Data = success ? try JSONSerialization.data(withJSONObject: ["id": accountID.canonicalCloudString, "email": "fixture@example.test", "username": "fixture", "displayName": "Fixture", "deviceID": fixture.scope.deviceID.canonicalCloudString]) : Data(#"{"error":"authentication_required"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: success ? 200 : 401, httpVersion: nil, headerFields: nil)!)
        }, publicationStore: { store })
        try await client.rememberPublicationAccount(accountID, endpoint: fixture.scope.endpoint, token: token)
        if stage == "me" {
            await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) { try await client.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) }
        } else {
            let session = try #require(try await client.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID))
            try await client.preparePublicationRetirement(session: session)
            if stage == "receipt-failure" {
                memory.failOnce("receipt/" + SHA256.hash(data: Data(fixture.scope.key.utf8)).map { String(format: "%02x", $0) }.joined())
            }
            await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) {
                switch stage {
                case "sharedVaults", "receipt-failure": _ = try await client.sharedVaults(endpoint: fixture.scope.endpoint, teamID: fixture.scope.teamID)
                case "format": _ = try await client.vaultFormat(endpoint: fixture.scope.endpoint, teamID: fixture.scope.teamID, vaultID: fixture.scope.vaultID)
                case "publication": _ = try await client.publicationRead(scope: fixture.scope, route: "header")
                default: _ = try await client.publicationRead(scope: fixture.scope, route: "resources/" + fixture.resourceID.canonicalCloudString + "/parts/SECRET")
                }
            }
        }
        #expect(tokens.token(for: fixture.scope.endpoint) == nil)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let checking = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        for (index, value) in [fixture, other].enumerated() {
            #expect(try store.load(scope: value.scope, session: checking) == nil)
            #expect(try store.highWater(scope: value.scope) == waters[index])
        }
        #expect(try store.cachedScopes(session: checking).isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(remaining.allSatisfy { $0.pathExtension == "history" })
        for marker in remaining { #expect(try Data(contentsOf: marker) == Data("selective-remote/publication-history/v1".utf8)) }
    }

    @Test("delayed old 401 preserves newer login and all durable scopes", arguments: ["me", "publication"])
    func delayedAuthenticationLoss(_ stage: String) async throws {
        let fixture = try PublicationFixture(), (reader, _, _, _, sourceDirectory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let directory = FileManager.default.temporaryDirectory.appending(path: "defensive-delayed-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: PublicationProtectedMemory())
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "a", count: 40), laterToken = String(repeating: "b", count: 40)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        try store.commit(cache, expected: nil, session: session)
        let water = try store.highWater(scope: fixture.scope), gate = PublicationRequestGate()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            await gate.pause()
            return (Data(#"{"error":"authentication_required"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, publicationStore: { store })
        try await client.rememberPublicationAccount(fixture.scope.accountID, endpoint: fixture.scope.endpoint, token: token)
        try await client.preparePublicationRetirement(session: session)
        let pending = Task {
            if stage == "me" { _ = try await client.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) }
            else { _ = try await client.publicationRead(scope: fixture.scope, route: "header") }
        }
        while !(await gate.started) { await Task.yield() }
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: fixture.scope.endpoint)
        tokens.saveToken(laterToken, for: fixture.scope.endpoint)
        let later = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: laterToken, tokenStore: tokens)
        try store.commit(cache, expected: water, session: later)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(tokens.token(for: fixture.scope.endpoint) == laterToken)
        #expect(try store.load(scope: fixture.scope, session: later) == cache)
        #expect(try store.cachedScopes(session: later) == [fixture.scope])
        #expect(try store.highWater(scope: fixture.scope) == water)
    }

    @Test("autosync current 401 from one Team retires the captured account catalog", arguments: ["vault-auth", "format-auth", "publication-auth"])
    func autosyncAuthenticationLoss(_ stage: String) async throws {
        let fixture = try PublicationFixture(empty: true), other = try PublicationFixture(empty: true, sameAccountAs: fixture, sameTeam: false)
        let directory = FileManager.default.temporaryDirectory.appending(path: "defensive-auto-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PublicationAutoSyncFixture(fixture, directory: directory), sink = PublicationSnapshotSink()
        let auto = SelectiveRemoteTeamVaultAutoSync(remote: remote, identityManager: .init(store: PublicationIdentityMemory(fixture.identity)), snapshotStore: { SelectiveRemoteTeamVaultMemorySnapshotStore() }, snapshotConsumer: { await sink.replace($0) })
        _ = try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID)
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: remote.protected)
        let session = try #require(try await remote.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID)), pin = other.ownPin
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: other.scope, session: session, remote: PublicationFixtureRemote(other), identity: other.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        _ = try await reader.load(teamName: "Other", vaultName: "Other", role: .viewer)
        let waters = try [fixture, other].map { try store.highWater(scope: $0.scope) }
        await remote.includeTeam(other)
        await remote.setListFault(stage)
        await #expect(throws: Error.self) { try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) }
        await remote.restoreAuthentication()
        let checking = try #require(try await remote.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID))
        #expect(try store.cachedScopes(session: checking).isEmpty)
        for (index, value) in [fixture, other].enumerated() {
            #expect(try store.load(scope: value.scope, session: checking) == nil)
            #expect(try store.highWater(scope: value.scope) == waters[index])
        }
    }

    @Test("coordinator current 401 retires all captured owned scopes", arguments: ["load", "secret"])
    func coordinatorAuthenticationLoss(_ stage: String) async throws {
        let fixture = try PublicationFixture(), other = try PublicationFixture(sameAccountAs: fixture, sameTeam: false)
        let directory = FileManager.default.temporaryDirectory.appending(path: "defensive-reader-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: PublicationProtectedMemory())
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "a", count: 40)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        let remote = PublicationFixtureRemote(fixture), pin = fixture.ownPin, otherPin = other.ownPin
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: fixture.scope, session: session, remote: remote, identity: fixture.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        _ = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let otherReader = SelectiveRemoteVaultPublicationCoordinator(scope: other.scope, session: session, remote: PublicationFixtureRemote(other), identity: other.identity, store: store, ownPin: { _, _ in otherPin }, advanceOwnPin: { _, _, _ in })
        _ = try await otherReader.load(teamName: "Other", vaultName: "Other", role: .viewer)
        let waters = try [fixture, other].map { try store.highWater(scope: $0.scope) }
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            (Data(#"{"error":"authentication_required"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        await remote.setFault(stage == "load" ? "authentication" : "authentication-secret")
        await remote.setHook { route in
            if (stage == "load" && route == "header") || (stage == "secret" && route.hasSuffix("/SECRET")) { _ = try? await client.teams(endpoint: fixture.scope.endpoint) }
        }
        await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) {
            if stage == "load" { _ = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer) }
            else { _ = try await reader.secretRecord(resourceID: fixture.resourceID) }
        }
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let checking = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        #expect(try store.cachedScopes(session: checking).isEmpty)
        for (index, value) in [fixture, other].enumerated() {
            #expect(try store.load(scope: value.scope, session: checking) == nil)
            #expect(try store.highWater(scope: value.scope) == waters[index])
        }
    }

    @Test("401 without protected account identity cannot guess a retirement catalog")
    func unknownAccountIsPreserved() async throws {
        let fixture = try PublicationFixture(empty: true), (reader, _, _, _, sourceDirectory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let directory = FileManager.default.temporaryDirectory.appending(path: "defensive-unknown-account-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: PublicationProtectedMemory()), tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "a", count: 40)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        try store.commit(cache, expected: nil, session: session)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            (Data(#"{"error":"authentication_required"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, publicationStore: { store })
        await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) { try await client.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) }
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let checking = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        #expect(try store.load(scope: fixture.scope, session: checking) == cache)
        #expect(try store.cachedScopes(session: checking) == [fixture.scope])
    }

    @Test("pending current 401 preserves a replaced receipt despite shared catalog refresh", arguments: [false, true])
    func replacedReceiptDuringRead(_ sameSession: Bool) async throws {
        let fixture = try PublicationFixture(empty: true), (reader, _, _, _, sourceDirectory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        let directory = FileManager.default.temporaryDirectory.appending(path: "defensive-replaced-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: PublicationProtectedMemory()), tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "a", count: 40)
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        try store.commit(cache, expected: nil, session: session)
        let water = try store.highWater(scope: fixture.scope), gate = PublicationRequestGate()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            await gate.pause()
            return (Data(#"{"error":"authentication_required"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, publicationStore: { store })
        try await client.preparePublicationRetirement(session: session)
        let pending = Task { try await client.teams(endpoint: fixture.scope.endpoint) }
        while !(await gate.started) { await Task.yield() }
        let replacement = sameSession ? session : SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        try store.commit(cache, expected: water, session: replacement)
        // A concurrent reader refreshes the reusable session catalog after the pending request started.
        try store.captureRetirementOwners(session: session)
        await gate.release()
        await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) { try await pending.value }
        tokens.saveToken(token, for: fixture.scope.endpoint)
        let checking = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: token, tokenStore: tokens)
        #expect(try store.load(scope: fixture.scope, session: checking) == cache)
        #expect(try store.cachedScopes(session: checking) == [fixture.scope])
        #expect(try store.highWater(scope: fixture.scope) == water)
    }

}
