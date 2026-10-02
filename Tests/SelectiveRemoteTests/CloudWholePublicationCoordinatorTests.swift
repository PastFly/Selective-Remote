import CryptoKit
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SelectiveRemote

@Suite("Whole publication native edit intent")
struct CloudWholePublicationEditingTests {
    func inputs() throws -> (SelectiveRemotePublishedModelReference, SelectiveRemoteJSONValue, [SelectiveRemotePublishedPart]) {
        let team = UUID(), vault = UUID(), resource = UUID(), folder = UUID(), scope = SelectiveRemotePublicationScope(endpoint: URL(string: "https://edit.example.test")!, accountID: UUID(), deviceID: UUID(), teamID: team, vaultID: vault)
        let reference = SelectiveRemotePublishedModelReference(scope: scope, resourceID: resource, kind: .host, generationID: UUID().canonicalCloudString, headerHash: String(repeating: "a", count: 64), part: .general, stale: false)
        let profile: SelectiveRemoteJSONValue = .object(["friendlyName": .string("Original"), "group": .string(""), "secret": .string("keep-secret"), "unknown": .number(1.25)])
        let link: SelectiveRemoteJSONValue = .object(["teamID": .string(team.canonicalCloudString), "vaultID": .string(vault.canonicalCloudString), "resourceID": .string(resource.canonicalCloudString), "generationID": .string(reference.generationID), "kind": .string("HOST"), "part": .string("GENERAL")])
        let record: SelectiveRemoteJSONValue = .object(["id": .string(UUID().canonicalCloudString), "type": .string("HOST"), "clock": .object(["legacy-device": .number(7)]), "modifiedAt": .string("2026-10-01T00:00:00Z"), "data": .object(["title": .string("Original"), "address": .string("example.test"), "profile": .string(try JSONEncoder().encode(profile).selectiveRemoteBase64URL), "description": .string("keep-description")])])
        let host = SelectiveRemotePublishedPart(resourceID: resource, kind: .host, part: .general, parentFolderID: nil, plaintext: try JSONEncoder().encode(SelectiveRemoteJSONValue.object(["link": link, "record": record])))
        let folderLink = SelectiveRemoteJSONValue.object(try link.publicationObject().merging(["resourceID": .string(folder.canonicalCloudString), "kind": .string("FOLDER")]) { _, rhs in rhs })
        let folderPart = SelectiveRemotePublishedPart(resourceID: folder, kind: .folder, part: .general, parentFolderID: nil, plaintext: try JSONEncoder().encode(SelectiveRemoteJSONValue.object(["link": folderLink, "folder": .object(["type": .string("host"), "path": .string("Production"), "component": .string("Production")])])))
        let resources: [SelectiveRemoteJSONValue] = [(.object(["id": .string(resource.canonicalCloudString), "kind": .string("HOST"), "parentFolderID": .null, "sourceOrdinal": .number(0)])), (.object(["id": .string(folder.canonicalCloudString), "kind": .string("FOLDER"), "parentFolderID": .null, "sourceOrdinal": .number(1)]))]
        return (reference, .object(["vaultID": .string(vault.canonicalCloudString), "resources": .array(resources), "policy": .array([]), "contentChanges": .array([]), "custodianDeviceIDs": .array([.string(scope.deviceID.canonicalCloudString)])]), [host, folderPart])
    }
    @Test("title edit preserves original record, clocks, unknown profile data and secrets")
    func content() throws {
        let (reference, vault, parts) = try inputs()
        let result = try SelectiveRemoteWholePublicationEditing.draft(vault: vault, reference: reference, parts: parts, intent: .content(title: "Renamed", body: nil))
        let bytes = try #require(result.changedParts[reference.scope.vaultID.canonicalCloudString + "/" + reference.resourceID.canonicalCloudString + "/GENERAL"])
        let original = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: parts[0].plaintext).publicationObject()
        let changed = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject(), record = try changed["record"]!.publicationObject(), data = try record["data"]!.publicationObject()
        #expect(changed["link"] == original["link"])
        let originalRecord = try original["record"]!.publicationObject()
        for field in ["id", "clock", "modifiedAt"] { #expect(record[field] == originalRecord[field]) }
        #expect(data["address"] == .string("example.test") && data["description"] == .string("keep-description"))
        let profile = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: #require(Data(selectiveRemoteBase64URL: data["profile"]!.publicationString()))).publicationObject()
        #expect(profile["friendlyName"] == .string("Renamed") && profile["secret"] == .string("keep-secret") && profile["unknown"] == .number(1.25))
        #expect(try result.vault.publicationObject()["contentChanges"]!.publicationArray().count == 1)
    }
    @Test("move binds exact folder ID, rewrites path and rejects a folder cycle or missing plaintext")
    func move() throws {
        let (reference, vault, parts) = try inputs(), folder = parts[1].resourceID
        let result = try SelectiveRemoteWholePublicationEditing.draft(vault: vault, reference: reference, parts: parts, intent: .move(parent: folder))
        let resources = try result.vault.publicationObject()["resources"]!.publicationArray()
        #expect(try resources[0].publicationObject()["parentFolderID"] == .string(folder.canonicalCloudString))
        let bytes = try #require(result.changedParts.values.first), data = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject()["record"]!.publicationObject()["data"]!.publicationObject()
        #expect(data["folder"] == .string("Production"))
        #expect(throws: Error.self) { try SelectiveRemoteWholePublicationEditing.draft(vault: vault, reference: reference, parts: [], intent: .move(parent: folder)) }
        let folderRef = SelectiveRemotePublishedModelReference(scope: reference.scope, resourceID: folder, kind: .folder, generationID: reference.generationID, headerHash: reference.headerHash, part: .general, stale: false)
        #expect(throws: Error.self) { try SelectiveRemoteWholePublicationEditing.draft(vault: vault, reference: folderRef, parts: parts, intent: .move(parent: folder)) }
    }
    @Test("direct access uses exact identity and membership epoch, preserves other grants, and removes only selected direct grants")
    func grants() throws {
        let (reference, vault, _) = try inputs(), selected = SelectiveRemoteWholePublicationEditing.Principal(id: UUID(), kind: "USER", name: "Named participant", membershipID: UUID(), epoch: 2)
        let inherited: SelectiveRemoteJSONValue = .object(["id": .string(UUID().canonicalCloudString), "principalKind": .string("GROUP"), "principalID": .string(UUID().canonicalCloudString), "targetKind": .string("VAULT"), "targetID": .string(reference.scope.vaultID.canonicalCloudString), "mask": .number(1)])
        var initial = try vault.publicationObject(); initial["policy"] = .array([inherited])
        let first = try SelectiveRemoteWholePublicationEditing.grant(vault: .object(initial), reference: reference, principal: selected, mask: 5)
        let firstRows = try first.publicationObject()["policy"]!.publicationArray(), grant = try firstRows[1].publicationObject()
        #expect(grant["targetID"] == .string(reference.resourceID.canonicalCloudString) && grant["membershipEpoch"] == .number(2) && grant["membershipID"] == .string(selected.membershipID!.canonicalCloudString))
        let changed = try SelectiveRemoteWholePublicationEditing.grant(vault: first, reference: reference, principal: selected, mask: 9)
        #expect(try changed.publicationObject()["policy"]!.publicationArray()[1].publicationObject()["id"] == grant["id"])
        let removed = try SelectiveRemoteWholePublicationEditing.grant(vault: changed, reference: reference, principal: selected, mask: 0)
        #expect(try removed.publicationObject()["policy"] == .array([inherited]))
        let rejoined = SelectiveRemoteWholePublicationEditing.Principal(id: selected.id, kind: "USER", name: selected.name, membershipID: UUID(), epoch: 3)
        let replacement = try SelectiveRemoteWholePublicationEditing.grant(vault: first, reference: reference, principal: rejoined, mask: 5)
        let replacementGrant = try replacement.publicationObject()["policy"]!.publicationArray()[1].publicationObject()
        #expect(replacementGrant["id"] != grant["id"] && replacementGrant["membershipID"] == .string(rejoined.membershipID!.canonicalCloudString) && replacementGrant["membershipEpoch"] == .number(3))
    }
}

private actor WholeUIProbe {
    var calls = 0
    func load(_ request: URLRequest) throws -> (Data, URLResponse) { calls += 1; throw URLError(.notConnectedToInternet) }
}
@Suite("Whole publication native entrypoint")
@MainActor struct CloudWholePublicationViewTests {
    @Test("mounted stale publication edit cannot prepare or send a mutation")
    func staleMountedView() async throws {
        let scope = SelectiveRemotePublicationScope(endpoint: URL(string: "https://ui.example.test")!, accountID: UUID(), deviceID: UUID(), teamID: UUID(), vaultID: UUID())
        let reference = SelectiveRemotePublishedModelReference(scope: scope, resourceID: UUID(), kind: .host, generationID: UUID().canonicalCloudString, headerHash: String(repeating: "a", count: 64), part: .general, stale: true)
        let probe = WholeUIProbe(), client = SelectiveRemoteCloudAPIClient(dataLoader: { try await probe.load($0) })
        let model = SelectiveRemoteWholePublicationModel(reference: reference, title: "Verified identity required", section: .edit, client: client)
        let access = try SelectiveRemoteCloudAccessReference(teamID: scope.teamID, vaultID: scope.vaultID, resourceID: reference.resourceID, kind: .host, displayName: "Verified identity required")
        let host = NSHostingView(rootView: SelectiveRemoteWholePublicationView(model: model, access: access)); host.frame = NSRect(x: 0, y: 0, width: 760, height: 640); host.layoutSubtreeIfNeeded()
        await model.load(); await model.preparePreview(); await model.publish()
        #expect(!model.available && model.preview == nil && model.message != nil)
        #expect(await probe.calls == 0)
    }
}

@Suite("Whole publication protected resume")
struct CloudWholePublicationCoordinatorTests {
    @Test("checkpoint is encrypted, survives restart and rejects another authorization")
    func protectedResume() throws {
        let endpoint = URL(string: "https://whole-\(UUID().uuidString).example.test")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "a", count: 40), for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), token: String(repeating: "a", count: 40), tokenStore: tokens)
        let scope = SelectiveRemoteWholePublicationScope(session: session, teamID: UUID(), operationID: UUID())
        let protected = PublicationProtectedMemory()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteWholePublicationCheckpointStore(directory: directory, protected: protected)
        let payload = Data("immutable ciphertext plan, not a predecessor CEK".utf8)
        try store.persist(payload, scope: scope, generationsHash: String(repeating: "1", count: 64), session: session)
        let disk = try Data(contentsOf: #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first))
        #expect(disk.range(of: payload) == nil)
        let restarted = try SelectiveRemoteWholePublicationCheckpointStore(directory: directory, protected: protected)
        #expect(try restarted.load(scope: scope, generationsHash: String(repeating: "1", count: 64), session: session) == payload)
        tokens.saveToken(String(repeating: "b", count: 40), for: endpoint)
        #expect(throws: CancellationError.self) { try restarted.load(scope: scope, generationsHash: String(repeating: "1", count: 64), session: session) }
        let next = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: session.accountID, deviceID: session.deviceID, token: String(repeating: "b", count: 40), tokenStore: tokens)
        #expect(throws: Error.self) { try restarted.load(scope: .init(session: next, teamID: scope.teamID, operationID: scope.operationID), generationsHash: String(repeating: "1", count: 64), session: next) }
    }

    @Test("checkpoint immutability rejects a changed generation or changed bytes")
    func changedCheckpoint() throws {
        let endpoint = URL(string: "https://whole-\(UUID().uuidString).example.test")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken("token", for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), token: "token", tokenStore: tokens)
        let scope = SelectiveRemoteWholePublicationScope(session: session, teamID: UUID(), operationID: UUID())
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteWholePublicationCheckpointStore(directory: directory, protected: PublicationProtectedMemory())
        try store.persist(Data("original".utf8), scope: scope, generationsHash: "first", session: session)
        #expect(throws: Error.self) { try store.persist(Data("changed".utf8), scope: scope, generationsHash: "first", session: session) }
        #expect(throws: Error.self) { try store.load(scope: scope, generationsHash: "second", session: session) }
    }

    @Test("failure to persist local protection creates no uploadable checkpoint")
    func failedKeyPersistence() throws {
        let endpoint = URL(string: "https://whole-\(UUID().uuidString).example.test")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken("token", for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), token: "token", tokenStore: tokens)
        let scope = SelectiveRemoteWholePublicationScope(session: session, teamID: UUID(), operationID: UUID())
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SelectiveRemoteWholePublicationCheckpointStore(directory: directory, protected: WholeFailingProtectedStorage())
        #expect(throws: Error.self) { try store.persist(Data("prepared".utf8), scope: scope, generationsHash: "generation", session: session) }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test("typed native HTTP carries required capabilities and exact Team operation paths")
    func transport() async throws {
        let endpoint = URL(string: "https://transport.example.test")!, tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "t", count: 43); tokens.saveToken(token, for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), token: token, tokenStore: tokens)
        let scope = SelectiveRemoteWholePublicationScope(session: session, teamID: UUID(), operationID: UUID()), vault = UUID()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            #expect(request.value(forHTTPHeaderField: "X-Vault-Schema-Version") == "2")
            #expect(request.value(forHTTPHeaderField: "X-Vault-Capability") == "resource_acl_v2")
            #expect(request.value(forHTTPHeaderField: "X-Publication-Version") == "1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v1/teams/" + scope.teamID.canonicalCloudString + "/publication/operations/" + scope.operationID.canonicalCloudString + "/readback/" + vault.canonicalCloudString)
            return (Data("null".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await client.wholePublicationReadback(scope: scope, vaultID: vault) == .null)
    }

    @Test("pre-encryption part budget matches actual complete POST body at the one MiB boundary")
    func encodedPartBoundary() throws {
        let fixture = try PublicationFixture(), s = fixture.scope, subject = try fixture.headerResponse.publicationObject()["subject"]!.publicationObject()
        let c = SelectiveRemoteResourceCipherContext(teamID: s.teamID, vaultID: s.vaultID, resourceID: fixture.resourceID, part: .metadata, keyVersion: 2, policyVersion: 2, registryVersion: 2, resourceVersion: 2, manifestVersion: 2)
        let w = SelectiveRemoteResourceWrapperContext(teamID: s.teamID, vaultID: s.vaultID, resourceID: fixture.resourceID, part: .metadata, keyVersion: 2, membershipID: try SelectiveRemoteWholePublicationWire.id(subject["membershipID"]!), membershipEpoch: try subject["membershipEpoch"]!.publicationInteger(), deviceID: s.deviceID)
        let base = try SelectiveRemoteWholePublicationWire.encodedPartBudget(context: c, plaintextBytes: 0, wrapperContexts: [w], includeHash: true), limit = 1024 * 1024
        var last = (limit - base) * 3 / 4
        while try SelectiveRemoteWholePublicationWire.encodedPartBudget(context: c, plaintextBytes: last + 1, wrapperContexts: [w], includeHash: true) <= limit { last += 1 }
        for count in [last, last + 1] {
            var cek = SelectiveRemoteResourceCryptoV2.generateCEK(); defer { cek.resetBytes(in: 0..<cek.count) }
            let envelope = try SelectiveRemoteResourceCryptoV2.encrypt(Data(repeating: 65, count: count), cek: cek, context: c)
            let wrapper = try SelectiveRemoteResourceCryptoV2.wrap(cek, for: fixture.identity.publicKey, context: w)
            var object: [String: SelectiveRemoteJSONValue] = ["resourceID": .string(fixture.resourceID.canonicalCloudString), "part": .string("METADATA"), "envelope": try SelectiveRemoteWholePublicationWire.json(envelope), "wrappers": .array([try SelectiveRemoteWholePublicationWire.json(wrapper)])]
            object["sha256"] = .string(try SelectiveRemoteWholePublicationWire.hash(.object(object)))
            let bare = try SelectiveRemoteWholePublicationWire.bytes(.object(object)).count, body = try SelectiveRemoteWholePublicationWire.bytes(.object(["object": .object(object)])).count
            #expect(body == bare + 11)
            #expect(try SelectiveRemoteWholePublicationWire.encodedPartBudget(context: c, plaintextBytes: count, wrapperContexts: [w], includeHash: true) == body)
            #expect((body <= limit) == (count == last))
            if count > last { #expect(bare <= limit) }
        }
    }

    @Test("projection chunk budget includes encoded JSON at the maximum decoded chunk and rejects boundary plus one")
    func chunkBoundary() throws {
        let data = Data(repeating: 65, count: 512 * 1024), hash = SelectiveRemoteWholePublicationWire.digest(data)
        let body = try SelectiveRemoteWholePublicationWire.projectionChunk(data, index: 255, count: 256, sha256: hash)
        let bytes = try SelectiveRemoteWholePublicationWire.bytes(body), object = try body.publicationObject()
        #expect(bytes.count <= 1024 * 1024 && bytes.count > data.count)
        #expect(try Data(selectiveRemoteBase64URL: object["data"]!.publicationString()) == data)
        #expect(object["index"] == .number(255) && object["count"] == .number(256) && object["sha256"] == .string(hash))
        #expect(throws: SelectiveRemoteWholePublicationError.limit) { try SelectiveRemoteWholePublicationWire.projectionChunk(data + Data([65]), index: 255, count: 256, sha256: hash) }
    }

    @Test("native transport accepts complete one MiB JSON and rejects one extra byte before HTTP")
    func completeHTTPBoundary() async throws {
        let endpoint = URL(string: "https://wire-boundary.example.test")!, tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "t", count: 43); tokens.saveToken(token, for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), token: token, tokenStore: tokens), scope = SelectiveRemoteWholePublicationScope(session: session, teamID: UUID(), operationID: UUID())
        let limit = 1024 * 1024, client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            #expect(request.httpBody?.count == 1024 * 1024)
            return (Data("null".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let accepted = try SelectiveRemoteWholePublicationWire.bytes(.object(["data": .string(String(repeating: "A", count: limit - 11))]))
        let rejected = try SelectiveRemoteWholePublicationWire.bytes(.object(["data": .string(String(repeating: "A", count: limit - 10))]))
        #expect(accepted.count == limit && rejected.count == limit + 1)
        #expect(try await client.wholePublication(scope: scope, route: "start", body: accepted) == .null)
        await #expect(throws: SelectiveRemoteWholePublicationError.limit) { try await client.wholePublication(scope: scope, route: "start", body: rejected) }
    }
}

private struct WholeFailingProtectedStorage: SelectiveRemotePublicationProtectedStorage {
    func read(_ key: String) throws -> Data? { nil }
    func save(_ data: Data, key: String) throws { throw CocoaError(.fileWriteNoPermission) }
}

private struct WholeFixture: @unchecked Sendable {
    let source: PublicationFixture
    let request: SelectiveRemoteJSONValue
    let preview: SelectiveRemoteJSONValue
    let directory: SelectiveRemoteJSONValue
    let administrative: SelectiveRemoteJSONValue
    let generation: UUID
    init() throws {
        let source = try PublicationFixture(); self.source = source
        let s = source.scope, operation = UUID(); generation = UUID()
        let subject = try source.headerResponse.publicationObject()["subject"]!.publicationObject()
        let cert = source.ownTrust.certificates![0], checkpoint = source.ownTrust.checkpoint!
        let target: SelectiveRemoteJSONValue = .object(["accountID": .string(s.accountID.canonicalCloudString), "deviceID": .string(s.deviceID.canonicalCloudString),
            "membershipID": subject["membershipID"]!, "membershipEpoch": subject["membershipEpoch"]!, "publicKey": try SelectiveRemoteWholePublicationWire.json(source.identity.publicKey),
            "rootPublicKey": .string(source.ownTrust.rootPublicKey!), "certificate": try SelectiveRemoteWholePublicationWire.json(cert), "checkpoint": try SelectiveRemoteWholePublicationWire.json(checkpoint)])
        let resources: SelectiveRemoteJSONValue = .array([.object(["id": .string(source.resourceID.canonicalCloudString), "kind": .string("CREDENTIAL"), "parentFolderID": .null, "sourceOrdinal": .number(0)])])
        let vault: SelectiveRemoteJSONValue = .object(["vaultID": .string(s.vaultID.canonicalCloudString), "resources": resources, "policy": .array([]), "contentChanges": .array([]), "custodianDeviceIDs": .array([.string(s.deviceID.canonicalCloudString)])])
        request = .object(["version": .number(1), "teamID": .string(s.teamID.canonicalCloudString), "operationID": .string(operation.canonicalCloudString), "vaults": .array([vault]), "groupMutation": .null])
        let oldHeader = source.headerResponse.publicationObjectUnchecked("header"), oldHash = source.headerResponse.publicationObjectUnchecked("headerHash")
        let predecessor: SelectiveRemoteJSONValue = .object(["vaultID": .string(s.vaultID.canonicalCloudString), "generationID": try SelectiveRemoteVaultPublicationV1.headerPayload(oldHeader)["generationID"]!, "sequence": .number(1), "headerHash": oldHash])
        let scope: SelectiveRemoteJSONValue = .object(["teamID": .string(s.teamID.canonicalCloudString), "vaultID": .string(s.vaultID.canonicalCloudString), "attemptID": .string(generation.canonicalCloudString), "sourceRevision": .number(2), "sourceHash": .string(String(repeating: "2", count: 64)), "snapshotHash": .string(String(repeating: "3", count: 64)), "policyVersion": .number(2)])
        let generationJSON: SelectiveRemoteJSONValue = .object(["vaultID": .string(s.vaultID.canonicalCloudString), "generationID": .string(generation.canonicalCloudString), "sequence": .number(2), "previousHash": oldHash, "scope": scope,
            "snapshot": .object(["teamID": .string(s.teamID.canonicalCloudString), "vaultID": .string(s.vaultID.canonicalCloudString), "actorRole": .string("owner"), "devices": .array([target])])])
        let rows: [SelectiveRemoteJSONValue] = ["METADATA", "SECRET"].map { .object(["type": .string("PART"), "vaultID": .string(s.vaultID.canonicalCloudString), "resourceID": .string(source.resourceID.canonicalCloudString), "part": .string($0), "devices": .array([target])]) }
            + [.object(["type": .string("CUSTODY"), "vaultID": .string(s.vaultID.canonicalCloudString), "devices": .array([target])])]
        let binding: SelectiveRemoteJSONValue = .object(["version": .number(1), "teamID": .string(s.teamID.canonicalCloudString), "operationID": .string(operation.canonicalCloudString), "actorAccountID": .string(s.accountID.canonicalCloudString), "sessionID": .string(UUID().canonicalCloudString), "actorDeviceID": .string(s.deviceID.canonicalCloudString), "keyVersion": .number(3),
            "requestHash": .string(try SelectiveRemoteWholePublicationWire.hash(request)), "readSetHash": .string(String(repeating: "4", count: 64)), "successorHash": .string(String(repeating: "5", count: 64)), "policyHash": .string(String(repeating: "6", count: 64)), "recipientHash": .string(String(repeating: "7", count: 64)), "predecessors": .array([predecessor]),
            "counts": .object(["vaults": .number(1), "resources": .number(1), "parts": .number(3), "wrappers": .number(3)]), "effectiveAt": .string("2026-10-02T00:00:00.000Z"), "rowsHash": .string(try SelectiveRemoteWholePublicationWire.hash(.array(rows))), "rowCount": .number(3)])
        let tokenClaims: SelectiveRemoteJSONValue = .object(["version": .number(1), "instanceID": .string(UUID().canonicalCloudString), "issuedAt": .number(0), "expiresAt": .number(4_000_000_000_000), "binding": binding])
        let token = try SelectiveRemoteWholePublicationWire.bytes(tokenClaims).selectiveRemoteBase64URL + "." + Data(repeating: 1, count: 32).selectiveRemoteBase64URL
        preview = .object(["token": .string(token), "binding": binding, "request": request, "generations": .array([generationJSON]), "rows": .array(rows), "nextCursor": .null])
        let sidecarID = UUID(), cek = SelectiveRemoteResourceCryptoV2.generateCEK()
        let context = SelectiveRemoteResourceCipherContext(teamID: s.teamID, vaultID: s.vaultID, resourceID: sidecarID, part: .secret, keyVersion: 1, policyVersion: 1, registryVersion: 1, resourceVersion: 1, manifestVersion: 1)
        let linkScope: SelectiveRemoteJSONValue = .object(["teamID": .string(s.teamID.canonicalCloudString), "vaultID": .string(s.vaultID.canonicalCloudString)])
        let metadata: SelectiveRemoteJSONValue = .object(["version": .number(1), "scope": linkScope, "generationID": try SelectiveRemoteVaultPublicationV1.headerPayload(oldHeader)["generationID"]!, "sourceFingerprint": .string(String(repeating: "8", count: 64)), "mapping": .object(["record:credential:test": .string(source.resourceID.canonicalCloudString)]), "sourceMetadata": .object(["schemaVersion": .number(1), "tombstones": .array([])])])
        let envelope = try SelectiveRemoteWholePublicationWire.json(SelectiveRemoteResourceCryptoV2.encrypt(SelectiveRemoteWholePublicationWire.bytes(metadata), cek: cek, context: context))
        let wc = SelectiveRemoteResourceWrapperContext(teamID: s.teamID, vaultID: s.vaultID, resourceID: sidecarID, part: .secret, keyVersion: 1, membershipID: try SelectiveRemoteWholePublicationWire.id(subject["membershipID"]!), membershipEpoch: try subject["membershipEpoch"]!.publicationInteger(), deviceID: s.deviceID)
        let wrapper = try SelectiveRemoteWholePublicationWire.json(SelectiveRemoteResourceCryptoV2.wrap(cek, for: source.identity.publicKey, context: wc))
        let entry: SelectiveRemoteJSONValue = .object(["accountID": .string(s.accountID.canonicalCloudString), "deviceKeyVersion": .number(3), "wrapper": wrapper])
        let sidecar: SelectiveRemoteJSONValue = .object(["resourceID": .string(sidecarID.canonicalCloudString), "part": .string("SECRET"), "envelope": envelope, "wrappers": .array([wrapper])])
        let oldScope: SelectiveRemoteJSONValue = .object(["teamID": .string(s.teamID.canonicalCloudString), "vaultID": .string(s.vaultID.canonicalCloudString), "attemptID": try SelectiveRemoteVaultPublicationV1.headerPayload(oldHeader)["generationID"]!, "sourceRevision": .number(1), "sourceHash": .string(String(repeating: "8", count: 64)), "snapshotHash": .string(String(repeating: "9", count: 64)), "policyVersion": .number(1)])
        let commitment: SelectiveRemoteJSONValue = .object(["resourceID": .string(sidecarID.canonicalCloudString), "envelopeHash": .string(try SelectiveRemoteVaultPublicationV1.hash("ciphertext", envelope)), "wrapperRoot": .string(try SelectiveRemoteVaultPublicationV1.hash("wrapper-leaf", entry))])
        let manifest = try SelectiveRemoteWholePublicationWire.signed(.object(["version": .number(2), "scope": oldScope, "policyHash": .string(try SelectiveRemoteWholePublicationWire.hash(.array([]))), "resources": resources, "parts": .array([]), "reader": .object(["projectionHash": .string(String(repeating: "a", count: 64)), "sidecarHash": .string(try SelectiveRemoteVaultPublicationV1.hash("sidecar", sidecar)), "custodianDeviceIDs": .array([.string(s.deviceID.canonicalCloudString)]), "sidecarCommitment": commitment])]), purpose: nil, root: source.trustRoot)
        var page = try source.directory.publicationObject(); page["header"] = oldHeader; page["manifest"] = manifest; page["scope"] = oldScope; page["publisher"] = target; page["administrativeResourceID"] = .string(sidecarID.canonicalCloudString)
        directory = .object(page)
        administrative = .object(["resourceID": .string(sidecarID.canonicalCloudString), "part": .string("SECRET"), "envelope": envelope, "entry": entry, "proof": .object(["index": .number(0), "total": .number(1), "siblings": .array([])]), "headerHash": oldHash, "generationID": try SelectiveRemoteVaultPublicationV1.headerPayload(oldHeader)["generationID"]!, "manifest": manifest, "scope": oldScope, "publisher": target])
    }
}

private extension SelectiveRemoteJSONValue {
    func publicationObjectUnchecked(_ key: String) -> Self { try! publicationObject()[key]! }
}

private actor WholeRemote: SelectiveRemoteWholePublicationRemote {
    let fixture: WholeFixture
    var fault: String?
    var uploaded: [(String, Data)] = []
    var projection: SelectiveRemoteJSONValue?
    var manifest: SelectiveRemoteJSONValue?
    var committed: SelectiveRemoteJSONValue?
    var hook: (@Sendable (String) async -> Void)?
    var requestedPreview: SelectiveRemoteJSONValue?
    var discarded = false
    var previewOverride: SelectiveRemoteJSONValue?
    init(_ fixture: WholeFixture) { self.fixture = fixture }
    func setFault(_ value: String?) { fault = value }
    func setHook(_ value: @escaping @Sendable (String) async -> Void) { hook = value }
    func setCurrentCheckpoint(_ directory: SelectiveRemoteSignedDeviceDirectory) throws {
        var p = try fixture.preview.publicationObject(), generations = try p["generations"]!.publicationArray(), g = try generations[0].publicationObject(), s = try g["snapshot"]!.publicationObject(), target = try s["devices"]!.publicationArray()[0].publicationObject()
        target["checkpoint"] = try SelectiveRemoteWholePublicationWire.json(directory); s["devices"] = .array([.object(target)]); g["snapshot"] = .object(s); generations[0] = .object(g); p["generations"] = .array(generations)
        let rows = try p["rows"]!.publicationArray().map { raw -> SelectiveRemoteJSONValue in var r = try raw.publicationObject(); r["devices"] = .array([.object(target)]); return .object(r) }
        var b = try p["binding"]!.publicationObject(); b["rowsHash"] = .string(try SelectiveRemoteWholePublicationWire.hash(.array(rows))); p["rows"] = .array(rows); p["binding"] = .object(b)
        let claims: SelectiveRemoteJSONValue = .object(["version": .number(1), "instanceID": .string(UUID().canonicalCloudString), "issuedAt": .number(0), "expiresAt": .number(4_000_000_000_000), "binding": .object(b)])
        p["token"] = .string(try SelectiveRemoteWholePublicationWire.bytes(claims).selectiveRemoteBase64URL + "." + Data(repeating: 1, count: 32).selectiveRemoteBase64URL); previewOverride = .object(p)
    }
    func wholePublication(scope: SelectiveRemoteWholePublicationScope, route: String, body: Data?) async throws -> SelectiveRemoteJSONValue {
        await hook?(route)
        if route == "context" {
            let vault = try fixture.request.publicationObject()["vaults"]!.publicationArray()[0].publicationObject(), old = try fixture.directory.publicationObject(), binding = try fixture.preview.publicationObject()["binding"]!.publicationObject()
            return .object(["teamID": .string(scope.teamID.canonicalCloudString), "publicationAvailable": .boolean(fault != "context-off"), "environment": .string(fault == "context-production" ? "production" : "staging"), "actorRole": .string("owner"), "sessionID": binding["sessionID"]!, "actorKeyVersion": binding["keyVersion"]!, "current": .array([.object(["teamID": .string(scope.teamID.canonicalCloudString), "vaultID": vault["vaultID"]!, "generationID": old["generationID"]!, "sequence": .number(1), "headerHash": old["headerHash"]!, "resources": vault["resources"]!, "policy": vault["policy"]!, "custodianDeviceIDs": vault["custodianDeviceIDs"]!])]), "groups": .array([]), "memberships": .array([]), "edges": .array([])])
        }
        if route == "preview" {
            var p = try (previewOverride ?? fixture.preview).publicationObject()
            let request = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: #require(body)).publicationObject()["request"]!
            if request != fixture.request {
                var binding = try p["binding"]!.publicationObject(); binding["requestHash"] = .string(try SelectiveRemoteWholePublicationWire.hash(request)); p["binding"] = .object(binding); p["request"] = request
                let claims: SelectiveRemoteJSONValue = .object(["version": .number(1), "instanceID": .string(UUID().canonicalCloudString), "issuedAt": .number(0), "expiresAt": .number(4_000_000_000_000), "binding": .object(binding)])
                p["token"] = .string(try SelectiveRemoteWholePublicationWire.bytes(claims).selectiveRemoteBase64URL + "." + Data(repeating: 1, count: 32).selectiveRemoteBase64URL)
            }
            requestedPreview = .object(p)
            if fault == "partial-preview" { p["rows"] = .array(Array(try p["rows"]!.publicationArray().prefix(1))) }
            if fault == "repeated-preview" { p["nextCursor"] = .string("same") }
            return .object(p)
        }
        if route == "repairDirectory" { return fixture.directory }
        if route == "repairPart" {
            let input = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: #require(body)).publicationObject()
            let part = try input["part"]!.publicationString()
            if fault == "missing-secret" && part == "SECRET" || fault == "missing-sidecar" && part == "ADMINISTRATIVE" { throw SelectiveRemoteCloudError.serviceError(403, "publication_custodian_unavailable") }
            if part == "ADMINISTRATIVE" { return fixture.administrative }
            return try #require(fixture.source.parts["resources/" + fixture.source.resourceID.canonicalCloudString + "/parts/" + part])
        }
        if route.hasSuffix("/receipt") {
            if fault == "receipt-unavailable" { throw URLError(.networkConnectionLost) }
            return committed ?? .null
        }
        if route.hasSuffix("/discard") {
            if fault == "discard-lost" { throw URLError(.networkConnectionLost) }
            discarded = true; return .object(["operationID": .string(scope.operationID.canonicalCloudString), "state": .string("DISCARDED")])
        }
        if route == "commit" || route.hasSuffix("/commit") {
            if ["definitive", "receipt-unavailable", "discard-lost"].contains(fault ?? "") { throw SelectiveRemoteCloudError.serviceError(409, "publication_stale") }
            let header = try #require(projection).publicationObject()["header"]!, h = try SelectiveRemoteVaultPublicationV1.headerPayload(header)
            committed = .object(["operationID": .string(scope.operationID.canonicalCloudString), "teamID": .string(scope.teamID.canonicalCloudString), "requestHash": fixture.preview.publicationObjectUnchecked("binding").publicationObjectUnchecked("requestHash"), "actorAccountID": .string(scope.accountID.canonicalCloudString), "actorDeviceID": .string(scope.deviceID.canonicalCloudString), "vaults": .array([.object(["vaultID": h["vaultID"]!, "generationID": h["generationID"]!, "sequence": h["sequence"]!, "headerHash": .string(try SelectiveRemoteVaultPublicationV1.hash("header", header))])]), "committedAt": .string("2026-10-02T00:00:01.000Z")])
            if fault == "lost-commit" || fault == "readback" { throw URLError(.networkConnectionLost) }
            return committed!
        }
        if let body { uploaded.append((route, body)) }
        if route.contains("/projections/") { projection = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: #require(body)).publicationObject()["projection"] }
        if route.hasSuffix("/validate") { manifest = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: #require(body)).publicationObject()["manifests"]!.publicationArray()[0].publicationObject()["manifest"] }
        if fault == "upload" && route.contains("/parts/") { throw URLError(.networkConnectionLost) }
        return .object(["state": .string("PREPARING")])
    }
    func wholePublicationReadback(scope: SelectiveRemoteWholePublicationScope, vaultID: UUID) async throws -> SelectiveRemoteJSONValue {
        if fault == "readback" { throw URLError(.notConnectedToInternet) }
        let header = try #require(projection).publicationObject()["header"]!
        return .object(["vaultID": .string(vaultID.canonicalCloudString), "header": header, "headerHash": .string(try SelectiveRemoteVaultPublicationV1.hash("header", header)), "manifest": try #require(manifest)])
    }
}

@Suite("Whole publication verified crypto and ownership")
struct CloudWholePublicationPipelineTests {
    private func setup(_ fixture: WholeFixture, protected: PublicationProtectedMemory = PublicationProtectedMemory(), pins: Bool = true, pinOverride: SelectiveRemoteDeviceTrustPin? = nil) throws -> (SelectiveRemoteWholePublicationCoordinator, WholeRemote, SelectiveRemoteWholePublicationCheckpointStore, SelectiveRemotePublicationSession, URL) {
        let s = fixture.source.scope, token = "whole-token", tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken(token, for: s.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: s.endpoint, accountID: s.accountID, deviceID: s.deviceID, token: token, tokenStore: tokens)
        let operation = try SelectiveRemoteWholePublicationWire.id(fixture.request.publicationObject()["operationID"]!)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = try SelectiveRemoteWholePublicationCheckpointStore(directory: directory, protected: protected), remote = WholeRemote(fixture)
        let scope = SelectiveRemoteWholePublicationScope(session: session, teamID: s.teamID, operationID: operation)
        let coordinator = SelectiveRemoteWholePublicationCoordinator(scope: scope, session: session, remote: remote, identity: fixture.source.identity, root: fixture.source.trustRoot, store: store,
            pin: { _, _, _ in pins ? pinOverride ?? fixture.source.ownPin : nil }, advancePin: { _, _, prior, next in #expect(next.highWater >= prior.highWater) })
        return (coordinator, remote, store, session, directory)
    }

    @Test("a truncated or repeated preview cannot be confirmed")
    func previewCompleteness() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        await remote.setFault("partial-preview")
        await #expect(throws: Error.self) { try await coordinator.preview(request: fixture.request) }
        await remote.setFault("repeated-preview")
        await #expect(throws: Error.self) { try await coordinator.preview(request: fixture.request) }
    }

    @Test("preview requires independently pinned recipients before confirmation")
    func untrustedPreview() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, _, _, directory) = try setup(fixture, pins: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: SelectiveRemoteWholePublicationError.recipientTrustUnverified) { try await coordinator.preview(request: fixture.request) }
        #expect(await remote.uploaded.isEmpty)
    }

    @Test("publication context admits only explicitly available staging and exact whole Team request")
    func stagingContext() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        for fault in ["context-off", "context-production"] {
            await remote.setFault(fault)
            await #expect(throws: Error.self) { try await coordinator.context() }
        }
        await remote.setFault(nil)
        let context = try await coordinator.context(), desired = try await coordinator.desiredRequest(context: context)
        #expect(desired == fixture.request)
        _ = try await coordinator.preview(request: desired)
        #expect(await remote.uploaded.isEmpty)
    }

    @Test("historical publisher under the same independently pinned root authenticates immutable data without lowering trust")
    func historicalPublisher() async throws {
        let fixture = try WholeFixture(), source = fixture.source
        let directory = try SelectiveRemoteDeviceTrustV1.signDirectory(root: source.trustRoot, accountID: source.scope.accountID, version: 3, certificates: source.ownTrust.certificates!)
        let pin = SelectiveRemoteDeviceTrustPin(accountID: source.scope.accountID, rootFingerprint: source.ownPin.rootFingerprint, highWater: 3, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        let (coordinator, remote, _, _, path) = try setup(fixture, pinOverride: pin); defer { try? FileManager.default.removeItem(at: path) }
        try await remote.setCurrentCheckpoint(directory)
        let preview = try await coordinator.preview(request: fixture.request); try await coordinator.prepare(preview: preview)
        #expect(await remote.uploaded.filter { $0.0.contains("/parts/") }.count == 2)
    }

    @Test("missing SECRET, missing custody and an unpinned target block preparation")
    func missingCustody() async throws {
        for fault in ["missing-secret", "missing-sidecar"] {
            let fixture = try WholeFixture(), (coordinator, remote, store, session, directory) = try setup(fixture)
            defer { try? FileManager.default.removeItem(at: directory) }
            let preview = try await coordinator.preview(request: fixture.request)
            await remote.setFault(fault)
            await #expect(throws: Error.self) { try await coordinator.prepare(preview: preview) }
            #expect(await remote.uploaded.isEmpty)
            #expect(try store.load(scope: coordinator.scope, session: session) == nil)
        }
    }

    @Test("fresh complete generation uses sequence contexts, exact wrappers and decryptable unchanged content")
    func freshGeneration() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await coordinator.preview(request: fixture.request)
        try await coordinator.prepare(preview: preview)
        let uploads = await remote.uploaded.filter { $0.0.contains("/parts/") }
        #expect(uploads.count == 2)
        var keys: [Data] = [], nonces: [String] = []
        for (_, bytes) in uploads {
            let object = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: bytes).publicationObject()["object"]!.publicationObject()
            let envelope = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceCipherEnvelope.self, from: object["envelope"]!)
            let wrappers = try object["wrappers"]!.publicationArray()
            let wrapper = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceKeyWrapper.self, from: #require(wrappers.first))
            #expect(wrappers.count == 1 && wrapper.context.keyVersion == 2)
            #expect(envelope.context.keyVersion == 2 && envelope.context.manifestVersion == 2 && envelope.context.resourceVersion == 2 && envelope.context.registryVersion == 2 && envelope.context.policyVersion == 2)
            let key = try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: fixture.source.identity.privateKey, context: wrapper.context)
            let plaintext = try SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: key, context: envelope.context)
            let link = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: plaintext).publicationObject()["link"]!.publicationObject()
            #expect(link["generationID"] == .string(fixture.generation.canonicalCloudString))
            keys.append(key); nonces.append(envelope.nonce)
        }
        #expect(keys[0] != keys[1] && nonces[0] != nonces[1])
    }

    @Test("logout during predecessor download cannot persist or upload a successor")
    func logoutDuringAwait() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, store, session, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await coordinator.preview(request: fixture.request)
        await remote.setHook { route in if route == "repairPart" { session.invalidate() } }
        await #expect(throws: CancellationError.self) { try await coordinator.prepare(preview: preview) }
        #expect(await remote.uploaded.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        _ = store
    }

    @Test("persist failure prevents any upload")
    func persistFailure() async throws {
        let fixture = try WholeFixture(), protected = PublicationProtectedMemory()
        let (coordinator, remote, _, _, directory) = try setup(fixture, protected: protected)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await coordinator.preview(request: fixture.request); protected.fail = true
        await #expect(throws: Error.self) { try await coordinator.prepare(preview: preview) }
        #expect(await remote.uploaded.isEmpty)
    }

    @Test("lost COMMIT preserves receipt and blocks writes through restart until exact readback")
    func lostCommitReadback() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, store, session, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await coordinator.preview(request: fixture.request); try await coordinator.prepare(preview: preview)
        await remote.setFault("readback")
        await #expect(throws: Error.self) { try await coordinator.commit(preview: preview) }
        #expect(try await coordinator.writesDisabled())
        #expect(try store.commitState(scope: coordinator.scope, session: session).receipt != nil)
        let restarted = SelectiveRemoteWholePublicationCoordinator(scope: coordinator.scope, session: session, remote: remote, identity: fixture.source.identity, root: fixture.source.trustRoot, store: store, pin: { _, _, _ in fixture.source.ownPin }, advancePin: { _, _, _, _ in })
        #expect(try await restarted.writesDisabled())
        let nextScope = SelectiveRemoteWholePublicationScope(session: session, teamID: coordinator.scope.teamID, operationID: UUID())
        let newOperation = SelectiveRemoteWholePublicationCoordinator(scope: nextScope, session: session, remote: remote, identity: fixture.source.identity, root: fixture.source.trustRoot, store: store, pin: { _, _, _ in fixture.source.ownPin }, advancePin: { _, _, _, _ in })
        #expect(try await newOperation.writesDisabled())
        await remote.setFault(nil)
        _ = try await restarted.resolveReceipt(request: fixture.request)
        #expect(try await restarted.writesDisabled() == false)
    }

    @Test("renewed own session can resolve immutable receipt but cannot resume old prepared upload")
    func renewedReceipt() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, store, old, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await coordinator.preview(request: fixture.request); try await coordinator.prepare(preview: preview)
        await remote.setFault("readback"); await #expect(throws: Error.self) { try await coordinator.commit(preview: preview) }
        old.invalidate()
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken("renewed-own-token", for: old.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: old.endpoint, accountID: old.accountID, deviceID: old.deviceID, token: "renewed-own-token", tokenStore: tokens)
        let scope = SelectiveRemoteWholePublicationScope(session: session, teamID: coordinator.scope.teamID, operationID: coordinator.scope.operationID)
        #expect(throws: Error.self) { try store.load(scope: scope, session: session) }
        let renewed = SelectiveRemoteWholePublicationCoordinator(scope: scope, session: session, remote: remote, identity: fixture.source.identity, root: fixture.source.trustRoot, store: store, pin: { _, _, _ in fixture.source.ownPin }, advancePin: { _, _, _, _ in })
        await #expect(throws: Error.self) { try await renewed.resume(request: fixture.request) }
        let before = await remote.uploaded.count
        #expect(try await renewed.savedRequest() == fixture.request)
        await remote.setFault(nil); _ = try await renewed.resolveReceipt(request: fixture.request)
        #expect(try await renewed.writesDisabled() == false)
        #expect(await remote.uploaded.count == before)
    }

    @Test("prepared READY is discoverable before COMMIT and a renewed own session can discard without replay")
    func preparedRenewal() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, store, old, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await coordinator.preview(request: fixture.request); try await coordinator.prepare(preview: preview)
        #expect(try store.pendingOperation(scope: coordinator.scope, session: old) == coordinator.scope.operationID)
        old.invalidate()
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken("renewed-ready-token", for: old.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: old.endpoint, accountID: old.accountID, deviceID: old.deviceID, token: "renewed-ready-token", tokenStore: tokens)
        let scope = SelectiveRemoteWholePublicationScope(session: session, teamID: coordinator.scope.teamID, operationID: coordinator.scope.operationID)
        let renewed = SelectiveRemoteWholePublicationCoordinator(scope: scope, session: session, remote: remote, identity: fixture.source.identity, root: fixture.source.trustRoot, store: store, pin: { _, _, _ in fixture.source.ownPin }, advancePin: { _, _, _, _ in })
        #expect(try await renewed.canDiscardUncommitted())
        await #expect(throws: Error.self) { try await renewed.resume(request: fixture.request) }
        let before = await remote.uploaded.count
        try await renewed.discardAfterFailedCommit()
        #expect(try store.pendingOperation(scope: scope, session: session) == nil)
        #expect(await remote.uploaded.count == before)
        #expect(await remote.discarded)
    }

    @Test("definitive precommit failure releases writes only after null receipt and confirmed discard")
    func definitiveFailure() async throws {
        for fault in ["definitive", "receipt-unavailable", "discard-lost"] {
            let fixture = try WholeFixture(), (coordinator, remote, _, _, directory) = try setup(fixture)
            defer { try? FileManager.default.removeItem(at: directory) }
            let preview = try await coordinator.preview(request: fixture.request); try await coordinator.prepare(preview: preview)
            await remote.setFault(fault)
            await #expect(throws: Error.self) { try await coordinator.commit(preview: preview) }
            #expect(try await coordinator.writesDisabled() == (fault != "definitive"))
            #expect(await remote.discarded == (fault == "definitive"))
        }
    }

    @Test("declared content edit without exact linked plaintext fails before upload")
    func missingChangedPayload() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = try fixture.request.publicationObject(), vaults = try request["vaults"]!.publicationArray(), vault = try vaults[0].publicationObject()
        vault["contentChanges"] = .array([.object(["resourceID": .string(fixture.source.resourceID.canonicalCloudString), "part": .string("METADATA")])]); vaults[0] = .object(vault); request["vaults"] = .array(vaults)
        let preview = try await coordinator.preview(request: .object(request))
        await #expect(throws: Error.self) { try await coordinator.prepare(preview: preview) }
        #expect(await remote.uploaded.isEmpty)
    }

    @Test("real metadata edit retains SECRET and rejects stale linked generation")
    func changedPayload() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        func open(_ raw: SelectiveRemoteJSONValue, reader: Bool) throws -> SelectiveRemoteJSONValue {
            let o = try raw.publicationObject(), envelope = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceCipherEnvelope.self, from: o["envelope"]!)
            let wrapperJSON = reader ? try o["entry"]!.publicationObject()["wrapper"]! : try o["wrappers"]!.publicationArray()[0]
            let wrapper = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceKeyWrapper.self, from: wrapperJSON)
            var key = try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: fixture.source.identity.privateKey, context: wrapper.context); defer { key.resetBytes(in: 0..<key.count) }
            return try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: key, context: envelope.context))
        }
        let prefix = "resources/" + fixture.source.resourceID.canonicalCloudString + "/parts/"
        var plaintext = try open(#require(fixture.source.parts[prefix + "METADATA"]), reader: true).publicationObject(), metadata = try plaintext["metadata"]!.publicationObject(); metadata["title"] = .string("Edited metadata"); plaintext["metadata"] = .object(metadata)
        var r = try fixture.request.publicationObject(), vaults = try r["vaults"]!.publicationArray(), v = try vaults[0].publicationObject(); v["contentChanges"] = .array([.object(["resourceID": .string(fixture.source.resourceID.canonicalCloudString), "part": .string("METADATA")])]); vaults[0] = .object(v); r["vaults"] = .array(vaults)
        let preview = try await coordinator.preview(request: .object(r)), key = fixture.source.scope.vaultID.canonicalCloudString + "/" + fixture.source.resourceID.canonicalCloudString + "/METADATA"
        var stale = plaintext, link = try stale["link"]!.publicationObject(); link["generationID"] = .string(UUID().canonicalCloudString); stale["link"] = .object(link)
        await #expect(throws: Error.self) { try await coordinator.prepare(preview: preview, changedParts: [key: try JSONEncoder().encode(SelectiveRemoteJSONValue.object(stale))]) }
        #expect(await remote.uploaded.isEmpty)
        try await coordinator.prepare(preview: preview, changedParts: [key: JSONEncoder().encode(SelectiveRemoteJSONValue.object(plaintext))])
        let objects = try await remote.uploaded.filter { $0.0.contains("/parts/") }.map { try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: $0.1).publicationObject()["object"]! }
        let edited = try #require(objects.first { try $0.publicationObject()["part"] == .string("METADATA") }), secret = try #require(objects.first { try $0.publicationObject()["part"] == .string("SECRET") })
        #expect(try open(edited, reader: false).publicationObject()["metadata"] == .object(metadata))
        #expect(try open(secret, reader: false).publicationObject()["record"] == open(#require(fixture.source.parts[prefix + "SECRET"]), reader: true).publicationObject()["record"])
    }

    @Test("restart upload reuses exactly the persisted part bytes")
    func restartUpload() async throws {
        let fixture = try WholeFixture(), (coordinator, remote, store, session, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await coordinator.preview(request: fixture.request); await remote.setFault("upload")
        await #expect(throws: Error.self) { try await coordinator.prepare(preview: preview) }
        let original = try #require(await remote.uploaded.first { $0.0.contains("/parts/") })
        let restarted = SelectiveRemoteWholePublicationCoordinator(scope: coordinator.scope, session: session, remote: remote, identity: fixture.source.identity, root: fixture.source.trustRoot, store: store, pin: { _, _, _ in fixture.source.ownPin }, advancePin: { _, _, _, _ in })
        await remote.setFault(nil); try await restarted.resume(request: fixture.request)
        let replayed = await remote.uploaded.filter { $0.0 == original.0 }
        #expect(replayed.count == 3 && replayed[0].1 == replayed[1].1)
        let changed = SelectiveRemoteJSONValue.object(try fixture.request.publicationObject().merging(["groupMutation": .object(["action": .string("CREATE"), "groupID": .string(UUID().canonicalCloudString), "name": .string("Changed intent")])]) { _, rhs in rhs })
        await #expect(throws: Error.self) { try await restarted.resume(request: changed) }
    }
}
