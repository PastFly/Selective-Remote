import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Personal Vault remote revision checks", .serialized)
@MainActor
struct PersonalVaultAutoSyncCheckTests {
    @Test("A checked unchanged revision confirms Personal alongside a confirmed Team")
    func unchangedRevisionConfirmsPersonal() async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 5)
        let presentation = presentationStore()
        presentation.recordTeamReport(.init(scannedVaults: 1, synchronizedVaults: 1))
        let generation = presentation.generation
        presentation.begin(.personal)

        let result = try await check(fixture)
        switch result {
        case .unavailable:
            presentation.recordPersonalUnknown()
        case let .current(revision):
            presentation.recordPersonalSuccess(revision: revision, generation: generation)
        case .download:
            Issue.record("An unchanged server revision must not request a download")
        case .unconfirmedUpload:
            Issue.record("No outgoing changes were scheduled")
        }

        #expect(fixture.requests.count == 1)
        #expect(fixture.keys.value?.revision == 5)
        #expect(fixture.keys.saveCount == 0)
        #expect(presentation.personal.lifecycle == .synced)
        #expect(presentation.personal.appliedRevision == 5)
        #expect(presentation.personal.lastConfirmedAt != nil)
        #expect(presentation.aggregate == .synced)
    }

    @Test("A lower remote revision is a conflict, never a synchronized revision")
    func lowerRevisionIsRejected() async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 4)
        do {
            _ = try await check(fixture)
            Issue.record("A server rollback must fail closed")
        } catch let error as SelectiveRemotePersonalVaultError {
            guard case let .uploadConflict(revision) = error else {
                Issue.record("Expected a revision conflict, got \(error)")
                return
            }
            #expect(revision == 4)
        }
        #expect(fixture.requests.count == 1)
        #expect(fixture.keys.value?.revision == 5)
        #expect(fixture.keys.saveCount == 0)
    }

    @Test("Missing keys, an initial download, and no session cannot confirm sync",
          arguments: [PersonalCheckPrerequisite.noKey, .initialDownload, .noSession])
    func unavailablePrerequisites(prerequisite: PersonalCheckPrerequisite) async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 5, prerequisite: prerequisite)
        let result = try await check(fixture)
        guard case .unavailable = result else {
            Issue.record("A missing prerequisite must remain unavailable")
            return
        }
        #expect(fixture.requests.count == 0)
        #expect(fixture.keys.saveCount == 0)
    }

    @Test("A decrypted newer download is not accepted by the read operation")
    func newerRevisionWaitsForApplication() async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 6)
        let presentation = presentationStore()
        let generation = presentation.generation
        presentation.begin(.personal)
        let result = try await check(fixture)
        guard case let .download(download) = result else {
            Issue.record("Newer content must be returned for application, not confirmation")
            return
        }
        #expect(download.revision == 6)
        #expect(download.document.records.isEmpty)
        #expect(fixture.requests.count == 1)
        #expect(fixture.keys.value?.revision == 5)
        #expect(fixture.keys.saveCount == 0)
        #expect(presentation.personal.lifecycle == .syncing)
        #expect(presentation.personal.lastConfirmedAt == nil)

        let accepted = try fixture.sync.acceptDownload(
            download, endpoint: Self.endpoint, deviceID: Self.deviceID,
            apply: {
                #expect(fixture.keys.value?.revision == 5)
                return true
            }
        )
        #expect(accepted)
        presentation.recordPersonalSuccess(revision: download.revision, generation: generation)
        #expect(fixture.keys.value?.revision == 6)
        #expect(fixture.keys.value?.documentHash == download.documentHash)
        #expect(fixture.keys.saveCount == 1)
        #expect(presentation.personal.lifecycle == .synced)
        #expect(presentation.personal.appliedRevision == 6)
    }

    @Test("Material removed while GET is in flight cannot confirm an unchanged revision")
    func changedMaterialCannotConfirm() async throws {
        let endpoint = Self.endpoint
        let deviceID = Self.deviceID
        let fixture = try PersonalCheckFixture(remoteRevision: 5, beforeResponse: { keys in
            keys.remove(endpoint: endpoint, deviceID: deviceID)
        })
        let result = try await check(fixture)
        guard case .unavailable = result else {
            Issue.record("The response no longer describes current local key material")
            return
        }
        #expect(fixture.requests.count == 1)
        #expect(fixture.keys.value == nil)
        #expect(fixture.keys.saveCount == 0)
    }

    @Test("A session reset during GET rejects its late unchanged-revision confirmation")
    func staleSessionCompletionIsDenied() async throws {
        let presentation = presentationStore()
        let generation = presentation.generation
        presentation.begin(.personal)
        let fixture = try PersonalCheckFixture(remoteRevision: 5, beforeResponse: { _ in
            await presentation.invalidateSession()
        })
        let result = try await check(fixture)
        guard case let .current(revision) = result else {
            Issue.record("The valid HTTP response should carry its checked revision")
            return
        }
        presentation.recordPersonalSuccess(revision: revision, generation: generation)
        #expect(presentation.generation != generation)
        #expect(presentation.personal.lifecycle == .unknown)
        #expect(presentation.personal.appliedRevision == nil)
        #expect(presentation.personal.lastConfirmedAt == nil)
    }

    @Test("An unchanged GET cannot confirm local changes while their PUT is pending or failed", .timeLimit(.minutes(1)))
    func unacknowledgedUploadCannotConfirm() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let failed = AsyncStream<SyncIssue>.makeStream()
        let fixture = try PersonalCheckFixture(remoteRevision: 5, uploadResponse: { request, _, _ in
            let envelope = try JSONDecoder().decode(
                SelectiveRemotePersonalVaultEnvelope.self, from: #require(request.httpBody)
            )
            #expect(envelope.baseRevision == 5)
            started.continuation.yield(())
            for await _ in release.stream { break }
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            ))
            return (Data("{}".utf8), response)
        })
        let snippet = TerminalCommandTemplate(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            profileID: Self.deviceID, title: "Unacknowledged synthetic change",
            command: "echo synthetic", category: "Synthetic", targets: [.localTerminal],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await fixture.sync.schedule(
            endpoint: Self.endpoint, deviceID: Self.deviceID, profiles: [],
            snippets: [snippet], forwarding: [], sshKeys: [],
            onFailure: { failed.continuation.yield($0) }
        )
        for await _ in started.stream { break }
        let pending = try await check(fixture)
        if case let .unconfirmedUpload(issue) = pending {
            #expect(issue == nil)
        } else {
            Issue.record("An in-flight PUT has not acknowledged the local change")
        }
        release.continuation.yield(())
        for await _ in failed.stream { break }
        let afterFailure = try await check(fixture)
        if case let .unconfirmedUpload(issue) = afterFailure {
            #expect(issue == .unknownFailure)
        } else {
            Issue.record("The same old server revision cannot erase a failed local upload")
        }
        #expect(fixture.keys.value?.revision == 5)
        #expect(fixture.keys.saveCount == 0)
        #expect(fixture.requests.count == 4)
    }

    @Test("Pending outgoing changes remain visible and retryable after an error")
    func pendingPresentationRetainsLocalChanges() {
        let presentation = presentationStore()
        presentation.recordPersonalSuccess(revision: 5)
        presentation.recordPersonalPending()
        #expect(presentation.personal.lifecycle == .pending)
        #expect(presentation.personal.pendingLocalChanges == true)
        presentation.recordPersonalFailure(.unknownFailure)
        #expect(presentation.personal.lifecycle == .error)
        #expect(presentation.personal.pendingLocalChanges == true)
        presentation.recordPersonalPending()
        #expect(presentation.personal.lifecycle == .pending)
        #expect(presentation.personal.issue == nil)
        #expect(presentation.personal.pendingLocalChanges == true)
    }

    @Test("A scheduled unchanged local snapshot releases its pending confirmation", .timeLimit(.minutes(1)))
    func unchangedOutgoingSnapshotConfirms() async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 5)
        await fixture.sync.schedule(
            endpoint: Self.endpoint, deviceID: Self.deviceID, profiles: [],
            snippets: [], forwarding: [], sshKeys: []
        )
        let pending = try await check(fixture)
        guard case .unconfirmedUpload = pending else {
            Issue.record("A queued snapshot must be checked before confirmation")
            return
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if case let .current(revision) = try await check(fixture) {
                #expect(revision == 5)
                #expect(fixture.keys.saveCount == 0)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("An unchanged outgoing snapshot must not remain pending forever")
    }

    @Test("An acknowledged PUT releases only its own pending local snapshot", .timeLimit(.minutes(1)))
    func successfulUploadAllowsConfirmation() async throws {
        let uploaded = AsyncStream<Void>.makeStream()
        let fixture = try PersonalCheckFixture(remoteRevision: 5, uploadResponse: { request, remote, _ in
            let body = try remote.acknowledge(request)
            uploaded.continuation.yield(())
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (body, response)
        })
        await fixture.sync.schedule(
            endpoint: Self.endpoint, deviceID: Self.deviceID, profiles: [],
            snippets: [Self.localSnippet], forwarding: [], sshKeys: []
        )
        for await _ in uploaded.stream { break }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if case let .current(revision) = try await check(fixture) {
                #expect(revision == 6)
                #expect(fixture.keys.value?.revision == 6)
                #expect(fixture.keys.saveCount == 1)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("A successful current PUT must release confirmation")
    }

    @Test("A late successful PUT cannot release a newer pending upload", .timeLimit(.minutes(1)))
    func supersededUploadCannotClearPending() async throws {
        let started = AsyncStream<Void>.makeStream()
        let releaseFirst = PersonalCheckGate()
        let releaseSecond = PersonalCheckGate()
        let failed = AsyncStream<SyncIssue>.makeStream()
        let uploads = PersonalCheckRequests()
        let fixture = try PersonalCheckFixture(remoteRevision: 5, uploadResponse: { request, remote, _ in
            uploads.record()
            let first = uploads.count == 1
            started.continuation.yield(())
            if first {
                await releaseFirst.wait()
                let body = try remote.acknowledge(request)
                return (body, try #require(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            }
            await releaseSecond.wait()
            return (Data("{}".utf8), try #require(HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )))
        })
        var events = started.stream.makeAsyncIterator()
        let firstCompletion = await fixture.sync.schedule(
            endpoint: Self.endpoint, deviceID: Self.deviceID, profiles: [],
            snippets: [Self.localSnippet], forwarding: [], sshKeys: []
        )
        _ = await events.next()
        await fixture.sync.schedule(
            endpoint: Self.endpoint, deviceID: Self.deviceID, profiles: [],
            snippets: [Self.localSnippet], forwarding: [], sshKeys: [],
            onFailure: { failed.continuation.yield($0) }
        )
        _ = await events.next()
        await releaseFirst.open()
        await firstCompletion.value
        #expect(fixture.keys.value?.revision == 5)
        let pending = try await check(fixture)
        if case let .unconfirmedUpload(issue) = pending { #expect(issue == nil) }
        else { Issue.record("A superseded PUT must not confirm the newer local snapshot") }
        await releaseSecond.open()
        for await _ in failed.stream { break }
        let failure = try await check(fixture)
        if case let .unconfirmedUpload(issue) = failure { #expect(issue == .unknownFailure) }
        else { Issue.record("The newer failed PUT must remain unconfirmed") }
    }

    @Test("A late PUT cannot overwrite newer key material in the same session", .timeLimit(.minutes(1)))
    func lateUploadPreservesNewerMaterial() async throws {
        let endpoint = Self.endpoint
        let deviceID = Self.deviceID
        let fixture = try PersonalCheckFixture(remoteRevision: 5, uploadResponse: { request, remote, keys in
            let responseBody = try remote.acknowledge(request)
            var newer = try #require(keys.value)
            newer.revision = 9
            newer.documentHash = Data(repeating: 0x99, count: 32)
            keys.save(newer, endpoint: endpoint, deviceID: deviceID)
            return (responseBody, try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })
        let completion = await fixture.sync.schedule(
            endpoint: Self.endpoint, deviceID: Self.deviceID, profiles: [],
            snippets: [Self.localSnippet], forwarding: [], sshKeys: []
        )
        await completion.value
        #expect(fixture.keys.value?.revision == 9)
        #expect(fixture.keys.value?.documentHash == Data(repeating: 0x99, count: 32))
        #expect(fixture.keys.saveCount == 1)
    }

    @Test("A download rejected by the current UI generation is not acknowledged")
    func rejectedApplicationDoesNotAcknowledge() async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 6)
        guard case let .download(download) = try await check(fixture) else {
            Issue.record("Expected a newer remote document")
            return
        }
        var generation = UUID()
        let expectedGeneration = generation
        let completion = Task { @MainActor in
            try fixture.sync.acceptDownload(
                download, endpoint: Self.endpoint, deviceID: Self.deviceID,
                apply: { generation == expectedGeneration }
            )
        }
        generation = UUID()
        #expect(try await completion.value == false)
        #expect(fixture.keys.value?.revision == 5)
        #expect(fixture.keys.saveCount == 0)
    }

    @Test("A partial local persistence failure cannot acknowledge a downloaded revision")
    func failedApplicationDoesNotAcknowledge() async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 6)
        guard case let .download(download) = try await check(fixture) else {
            Issue.record("Expected a newer remote document")
            return
        }
        var persistedParts = 0
        do {
            _ = try fixture.sync.acceptDownload(
                download, endpoint: Self.endpoint, deviceID: Self.deviceID,
                apply: {
                    persistedParts += 1
                    throw PersonalCheckApplyFailure.persistence
                }
            )
            Issue.record("A partial application must fail")
        } catch PersonalCheckApplyFailure.persistence { }
        #expect(persistedParts == 1)
        #expect(fixture.keys.value?.revision == 5)
        #expect(fixture.keys.saveCount == 0)
        guard case .download = try await check(fixture) else {
            Issue.record("The unapplied revision must remain available for retry")
            return
        }
    }

    @Test("Unconfirmed uploads stay with their Vault and session", .timeLimit(.minutes(1)),
          arguments: [PersonalCheckScopeChange.newSessionAndVault, .sameVaultNewSession, .sameSessionNewMaterial])
    func unconfirmedUploadScope(change: PersonalCheckScopeChange) async throws {
        let fixture = try PersonalCheckFixture(remoteRevision: 5, uploadResponse: { request, _, _ in
            (Data("{}".utf8), try #require(HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )))
        })
        let failedUpload = await fixture.sync.schedule(
            endpoint: Self.endpoint, deviceID: Self.deviceID, profiles: [],
            snippets: [Self.localSnippet], forwarding: [], sshKeys: []
        )
        await failedUpload.value
        let original = try #require(fixture.keys.value)
        let switchesVault = change != .sameVaultNewSession
        if switchesVault {
            let next = try SelectiveRemotePersonalVaultKeyMaterial(
                vaultID: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
                vaultKey: Data(repeating: 0x55, count: 32), wrappedKey: original.wrappedKey,
                revision: 5, documentHash: original.documentHash
            )
            fixture.keys.save(next, endpoint: Self.endpoint, deviceID: Self.deviceID)
            try fixture.remote.replaceVault(next, revision: 6)
        }
        if change != .sameSessionNewMaterial {
            SelectiveRemotePublicationLifecycle.invalidate(endpoint: Self.endpoint)
        }
        let result = try await check(fixture)
        if change == .newSessionAndVault {
            guard case let .download(download) = result else {
                Issue.record("A former account's failed upload must not block the new Vault")
                return
            }
            #expect(download.revision == 6)
            #expect(download.document.records.isEmpty)
            #expect(fixture.keys.value?.revision == 5)
            #expect(fixture.keys.saveCount == 1)
            fixture.keys.save(original, endpoint: Self.endpoint, deviceID: Self.deviceID)
            try fixture.remote.replaceVault(original, revision: 5)
            SelectiveRemotePublicationLifecycle.invalidate(endpoint: Self.endpoint)
            guard case .unconfirmedUpload = try await check(fixture) else {
                Issue.record("Changing accounts must not acknowledge the former Vault's unsent work")
                return
            }
        } else {
            guard case .unconfirmedUpload = result else {
                Issue.record("Unsent work for the same Vault or current session must stay unconfirmed")
                return
            }
            #expect(fixture.keys.value?.revision == 5)
        }
    }

    private static let endpoint = URL(string: "https://personal-check.example.invalid")!
    private static let deviceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static var localSnippet: TerminalCommandTemplate {
        .init(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
              profileID: deviceID, title: "Synthetic local change", command: "echo synthetic",
              category: "Synthetic", targets: [.localTerminal],
              updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func presentationStore() -> SyncPresentationStore {
        let store = SyncPresentationStore()
        store.setAccount(endpoint: Self.endpoint.absoluteString, deviceID: Self.deviceID.uuidString)
        return store
    }

    private func check(_ fixture: PersonalCheckFixture) async throws
        -> SelectiveRemotePersonalVaultAutoSync.CheckResult {
        try await fixture.sync.checkForChanges(
            endpoint: Self.endpoint, deviceID: Self.deviceID
        )
    }
}

enum PersonalCheckPrerequisite: Sendable {
    case available, noKey, initialDownload, noSession
}

private enum PersonalCheckApplyFailure: Error { case persistence }
enum PersonalCheckScopeChange: Sendable {
    case newSessionAndVault, sameVaultNewSession, sameSessionNewMaterial
}

private struct PersonalCheckFixture {
    let sync: SelectiveRemotePersonalVaultAutoSync
    let keys: PersonalCheckKeyStore
    let requests: PersonalCheckRequests
    let remote: PersonalCheckRemote

    init(remoteRevision: Int,
         prerequisite: PersonalCheckPrerequisite = .available,
         beforeResponse: (@Sendable (PersonalCheckKeyStore) async -> Void)? = nil,
         uploadResponse: (@Sendable (URLRequest, PersonalCheckRemote, PersonalCheckKeyStore) async throws -> (Data, URLResponse))? = nil) throws {
        let endpoint = URL(string: "https://personal-check.example.invalid")!
        let vaultID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let key = Data(repeating: 0x11, count: 32)
        let wrapped = try SelectiveRemotePersonalVaultWrappedKey(
            salt: Data(repeating: 0x22, count: 16), value: Data(repeating: 0x33, count: 40)
        )
        let document = try SelectiveRemoteVaultDocument(records: [])
        let material = try SelectiveRemotePersonalVaultKeyMaterial(
            vaultID: vaultID, vaultKey: key, wrappedKey: wrapped, revision: 5,
            documentHash: Data(SHA256.hash(data: try document.encoded())),
            requiresInitialDownload: prerequisite == .initialDownload
        )
        let keys = PersonalCheckKeyStore(prerequisite == .noKey ? nil : material)
        let requests = PersonalCheckRequests()
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        if prerequisite != .noSession { tokens.saveToken(String(repeating: "t", count: 43), for: endpoint) }
        let envelope = try SelectiveRemotePersonalVaultCrypto.reseal(
            document, vaultKey: key, wrappedKey: wrapped, baseRevision: remoteRevision - 1,
            nonce: Data(repeating: 0x44, count: 12)
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "id": vaultID.canonicalCloudString,
            "revision": remoteRevision,
            "envelopeVersion": 1,
            "wrappedKey": ["algorithm": wrapped.algorithm, "iterations": wrapped.iterations,
                           "salt": wrapped.salt, "value": wrapped.value],
            "ciphertext": envelope.ciphertext,
            "nonce": envelope.nonce,
            "authTag": envelope.authTag,
            "contentHash": envelope.contentHash,
            "updatedAt": "2026-10-09T00:00:00.000Z"
        ])
        let remote = PersonalCheckRemote(body: body)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            requests.record()
            #expect(request.url?.path == "/v1/vault")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(String(repeating: "t", count: 43))")
            if request.httpMethod == "PUT", let uploadResponse {
                return try await uploadResponse(request, remote, keys)
            }
            #expect(request.httpMethod == "GET")
            await beforeResponse?(keys)
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (remote.body, response)
        })
        self.keys = keys
        self.requests = requests
        self.remote = remote
        self.sync = SelectiveRemotePersonalVaultAutoSync(client: client, keyStore: keys)
    }
}

private final class PersonalCheckRemote: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data
    init(body: Data) { stored = body }
    var body: Data { lock.withLock { stored } }
    func replaceVault(_ material: SelectiveRemotePersonalVaultKeyMaterial, revision: Int) throws {
        let envelope = try SelectiveRemotePersonalVaultCrypto.reseal(
            SelectiveRemoteVaultDocument(records: []), vaultKey: material.vaultKey,
            wrappedKey: material.wrappedKey, baseRevision: revision - 1,
            nonce: Data(repeating: 0x66, count: 12)
        )
        var next = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(envelope)
        ) as? [String: Any])
        next.removeValue(forKey: "baseRevision")
        next["id"] = material.vaultID.canonicalCloudString
        next["revision"] = revision
        next["updatedAt"] = "2026-10-09T00:00:02.000Z"
        let body = try JSONSerialization.data(withJSONObject: next)
        lock.withLock { stored = body }
    }
    func acknowledge(_ request: URLRequest) throws -> Data {
        try lock.withLock {
            let envelope = try JSONDecoder().decode(
                SelectiveRemotePersonalVaultEnvelope.self, from: #require(request.httpBody)
            )
            let old = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
            #expect(old["revision"] as? Int == envelope.baseRevision)
            var next = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope)
            ) as? [String: Any])
            next.removeValue(forKey: "baseRevision")
            next["id"] = old["id"]
            next["revision"] = envelope.baseRevision + 1
            next["updatedAt"] = "2026-10-09T00:00:01.000Z"
            stored = try JSONSerialization.data(withJSONObject: next)
            return try JSONSerialization.data(withJSONObject: [
                "conflict": false, "revision": envelope.baseRevision + 1
            ])
        }
    }
}

// Model a transport response that can arrive even after its task was cancelled.
private actor PersonalCheckGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class PersonalCheckKeyStore: SelectiveRemotePersonalVaultKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SelectiveRemotePersonalVaultKeyMaterial?
    private var saves = 0
    init(_ material: SelectiveRemotePersonalVaultKeyMaterial?) { stored = material }
    var value: SelectiveRemotePersonalVaultKeyMaterial? { lock.withLock { stored } }
    var saveCount: Int { lock.withLock { saves } }
    func material(endpoint: URL, deviceID: UUID) -> SelectiveRemotePersonalVaultKeyMaterial? { value }
    func save(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID) {
        lock.withLock { stored = material; saves += 1 }
    }
    func remove(endpoint: URL, deviceID: UUID) { lock.withLock { stored = nil } }
}

private final class PersonalCheckRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var count: Int { lock.withLock { requests } }
    func record() { lock.withLock { requests += 1 } }
}
