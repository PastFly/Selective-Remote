import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

/// Synthetic transport only; signatures, Merkle binding, ECDH and AES-GCM are real.
actor PublicationFixtureRemote: SelectiveRemoteVaultPublicationRemote {
    let fixture: PublicationFixture
    var requests: [String] = []
    var fault: String?
    var hook: (@Sendable (String) async -> Void)?
    init(_ fixture: PublicationFixture) { self.fixture = fixture }
    func setFault(_ value: String?) { fault = value }
    func setHook(_ value: @escaping @Sendable (String) async -> Void) { hook = value }
    func publicationOwnTrust(endpoint: URL) async throws -> SelectiveRemoteCloudDeviceTrustSnapshot {
        if fault == "offline" { throw URLError(.notConnectedToInternet) }
        return fixture.ownTrust
    }
    func publicationRead(scope: SelectiveRemotePublicationScope, route: String, generation: String?, hash: String?, cursor: String?) async throws -> SelectiveRemoteJSONValue {
        requests.append(route); await hook?(route)
        if fault == "offline" { throw URLError(.notConnectedToInternet) }
        if fault == "denied" { throw SelectiveRemoteCloudError.serviceError(403, "publication_access_denied") }
        if route == "header" { return fixture.headerResponse }
        if fault == "pointer" { throw SelectiveRemoteCloudError.serviceError(409, "publication_changed") }
        if route == "publisher" { return fixture.publisher }
        if route == "directory" {
            var page = try fixture.directory.publicationObject()
            let offset = cursor.flatMap(Int.init) ?? 0
            let end = min(offset + 100, fixture.descriptors.count)
            page["descriptors"] = .array(Array(fixture.descriptors[offset..<end]))
            page["nextCursor"] = end < fixture.descriptors.count ? .string(String(end)) : .null
            if fault == "partial" { page["descriptors"] = .array([]) }
            if fault == "repeat" { page["nextCursor"] = .string("same-cursor") }
            if fault == "oversized" { page["descriptors"] = .array(Array(repeating: fixture.descriptors[0], count: 101)) }
            return .object(page)
        }
        if let response = fixture.parts[route] { return response }
        throw SelectiveRemotePublicationError.invalid
    }
}

struct PublicationFixture: @unchecked Sendable {
    let scope: SelectiveRemotePublicationScope
    let identity: SelectiveRemoteTeamDeviceIdentity
    let ownPin: SelectiveRemoteDeviceTrustPin
    let ownTrust: SelectiveRemoteCloudDeviceTrustSnapshot
    let publisher: SelectiveRemoteJSONValue
    let headerResponse: SelectiveRemoteJSONValue
    let directory: SelectiveRemoteJSONValue
    let descriptors: [SelectiveRemoteJSONValue]
    let parts: [String: SelectiveRemoteJSONValue]
    let resourceID: UUID
    let trustRoot: P256.Signing.PrivateKey
    init(crossPublisher: Bool = false, empty: Bool = false, allKinds: Bool = false, credentialCount: Int = 1, includeSecret: Bool = true, transport: String = "ssh", sourceID: String? = nil, omitSourceID: Bool = false, folderName: String? = nil, converterProduced: Bool = false, credentialKind: String? = nil, nativeProfileMismatch: Bool = false, sameAccountAs prior: PublicationFixture? = nil, sameTeam: Bool = true) throws {
        let endpoint = prior?.scope.endpoint ?? URL(string: "https://fixture-\(UUID().uuidString.lowercased()).example.test")!, accountID = prior?.scope.accountID ?? UUID(), deviceID = prior?.scope.deviceID ?? UUID(), teamID = sameTeam ? prior?.scope.teamID ?? UUID() : UUID(), vaultID = UUID(), membershipID = UUID(), generationID = UUID()
        scope = .init(endpoint: endpoint, accountID: accountID, deviceID: deviceID, teamID: teamID, vaultID: vaultID)
        identity = try prior?.identity ?? .init(deviceID: deviceID, privateKeyRepresentation: P256.KeyAgreement.PrivateKey().rawRepresentation)
        let root = prior?.trustRoot ?? P256.Signing.PrivateKey(); trustRoot = root
        let cert = try prior?.ownTrust.certificates?.first ?? SelectiveRemoteDeviceTrustV1.issueCertificate(root: root, accountID: accountID, deviceID: deviceID, publicKey: identity.publicKey, keyVersion: 3, issuedAt: 1, serial: UUID())
        let checkpoint = try prior?.ownTrust.checkpoint ?? SelectiveRemoteDeviceTrustV1.signDirectory(root: root, accountID: accountID, version: 2, certificates: [cert])
        ownPin = .init(accountID: accountID, rootFingerprint: SelectiveRemoteDeviceTrustV1.fingerprint(root.publicKey), highWater: 2, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(checkpoint))
        ownTrust = .init(state: "ROOT_PUBLISHED", rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL, rootFingerprint: ownPin.rootFingerprint, custodianDeviceID: deviceID, checkpoint: checkpoint, certificates: [cert])
        let publisherRoot = crossPublisher ? P256.Signing.PrivateKey() : root
        let publisherAccount = crossPublisher ? UUID() : accountID
        let publisherDevice = crossPublisher ? UUID() : deviceID
        let pubCert = crossPublisher ? try SelectiveRemoteDeviceTrustV1.issueCertificate(root: publisherRoot, accountID: publisherAccount, deviceID: publisherDevice, publicKey: identity.publicKey, keyVersion: 3, issuedAt: 1, serial: UUID()) : cert
        let pubCheckpoint = crossPublisher ? try SelectiveRemoteDeviceTrustV1.signDirectory(root: publisherRoot, accountID: publisherAccount, version: 2, certificates: [pubCert]) : checkpoint
        func json<T: Encodable>(_ value: T) throws -> SelectiveRemoteJSONValue {
            func lower(_ value: SelectiveRemoteJSONValue) -> SelectiveRemoteJSONValue {
                switch value {
                case let .string(s): return UUID(uuidString: s).map { .string($0.canonicalCloudString) } ?? value
                case let .object(o): return .object(o.mapValues(lower))
                case let .array(a): return .array(a.map(lower))
                default: return value
                }
            }
            return lower(try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: JSONEncoder().encode(value)))
        }
        func sign(_ purpose: String, _ value: SelectiveRemoteJSONValue) throws -> SelectiveRemoteJSONValue { .object(["payload": value, "signature": .string(try publisherRoot.signature(for: SelectiveRemoteVaultPublicationV1.bytes(purpose, value)).rawRepresentation.selectiveRemoteBase64URL)]) }
        let converted: [[String: SelectiveRemoteJSONValue]]
        if converterProduced {
            let url = try #require(Bundle.module.url(forResource: "native-converter-mapped-v1", withExtension: "json", subdirectory: "Fixtures"))
            converted = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: Data(contentsOf: url)).publicationObject()["parts"]!.publicationArray().map { try $0.publicationObject() }
        } else { converted = [] }
        resourceID = try converted.first(where: { $0["kind"] == .string("CREDENTIAL") }).map { UUID(uuidString: try $0["resourceID"]!.publicationString())! } ?? UUID()
        var cores: [SelectiveRemoteJSONValue] = [], bodies: [(SelectiveRemoteJSONValue, SelectiveRemoteJSONValue)] = []
        let hostID = UUID(), folderID = UUID(), snippetFolderID = UUID(), snippetID = UUID(), forwardingID = UUID()
        var resources: [(UUID, CloudAccessKind, SelectiveRemoteResourcePart)] = empty ? [] : [(resourceID, .credential, .metadata), (resourceID, .credential, .secret)]
        if !empty && credentialCount > 1 { for _ in 1..<credentialCount { let id = UUID(); resources += [(id, .credential, .metadata), (id, .credential, .secret)] } }
        if allKinds { resources += [(hostID, .host, .general), (folderID, .folder, .general), (snippetFolderID, .folder, .general), (snippetID, .snippet, .general), (forwardingID, .forwarding, .general)] }
        if !includeSecret { resources.removeAll { $0.2 == .secret } }
        if converterProduced {
            resources = try converted.map { (UUID(uuidString: try $0["resourceID"]!.publicationString())!, CloudAccessKind(rawValue: try $0["kind"]!.publicationString())!, SelectiveRemoteResourcePart(rawValue: try $0["part"]!.publicationString())!) }
        }
        resources.sort { ($0.0.canonicalCloudString + "/" + $0.2.rawValue) < ($1.0.canonicalCloudString + "/" + $1.2.rawValue) }
        for (resourceID, kind, part) in resources {
            let context = SelectiveRemoteResourceCipherContext(teamID: teamID, vaultID: vaultID, resourceID: resourceID, part: part, keyVersion: 1, policyVersion: 1, registryVersion: 1, resourceVersion: 1, manifestVersion: 1)
            let link: SelectiveRemoteJSONValue = .object(["teamID": .string(teamID.canonicalCloudString), "vaultID": .string(vaultID.canonicalCloudString), "generationID": .string(generationID.canonicalCloudString), "resourceID": .string(resourceID.canonicalCloudString), "kind": .string(kind.rawValue), "part": .string(part.rawValue)])
            var credentialData: [String: SelectiveRemoteJSONValue] = ["title": .string("Published credential"), "username": .string("alice"), "secret": .string("test-only-secret")]
            if allKinds { credentialData["kind"] = .string(credentialKind ?? transport); credentialData["sourceID"] = .string(sourceID ?? hostID.canonicalCloudString) }
            var metadata: [String: SelectiveRemoteJSONValue] = ["title": .string("Published credential"), "username": .string("alice")]
            if allKinds { metadata["kind"] = .string(credentialKind ?? transport) }
            var payload: SelectiveRemoteJSONValue
            if kind == .folder {
                let name = folderName ?? (resourceID == folderID ? "Authorized hosts" : "Authorized snippets")
                payload = .object(["link": link, "folder": .object(["type": .string(resourceID == folderID ? "host" : "snippet"), "path": .string(name), "component": .string(name)])])
            } else if part == .metadata { payload = .object(["link": link, "metadata": .object(metadata)]) }
            else {
                let type: SelectiveRemoteVaultRecordType = kind == .credential ? .credential : kind == .host ? .host : kind == .snippet ? .snippet : .forwarding
                var data: SelectiveRemoteJSONValue = kind == .credential ? .object(credentialData) : kind == .host ? .object(["title": .string("Published host"), "address": .string(transport + "://host.example"), "folder": .string("Historical path")]) : kind == .snippet ? .object(["title": .string("Published snippet"), "body": .string("echo test-only"), "folder": .string("Historical snippet path")]) : .object(["title": .string("Published tunnel"), "destination": .string("localhost:5432"), "kind": .string("local")])
                if kind == .host && nativeProfileMismatch {
                    var profile = ConnectionProfile(connectionType: .ssh); profile.id = UUID(); profile.host = "host.example"; profile.friendlyName = "Published host"
                    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                    data = .object(["title": .string("Published host"), "address": .string("host.example"), "username": .string(profile.username), "connectionType": .string("ssh"), "profile": .string(try encoder.encode(profile).selectiveRemoteBase64URL)])
                }
                let record = try SelectiveRemoteVaultRecord(id: resourceID, type: type, version: .init([deviceID: 2]), modifiedAt: "2026-10-01T01:00:00.000Z", data: data)
                var original = try json(record).publicationObject()
                if let sourceID { original["id"] = .string(sourceID) }
                if omitSourceID { original.removeValue(forKey: "id") }
                payload = .object(["link": link, "record": .object(original)])
            }
            let conversion = converted.first { $0["resourceID"] == .string(resourceID.canonicalCloudString) && $0["part"] == .string(part.rawValue) }
            if let conversion {
                var object = try conversion["payload"]!.publicationObject()
                // Rebind only transport scope/generation for fresh native signatures; original record/folder remains exact converter output.
                object["link"] = link; payload = .object(object)
            }
            let cek = SelectiveRemoteResourceCryptoV2.generateCEK()
            let envelope = try json(SelectiveRemoteResourceCryptoV2.encrypt(JSONEncoder().encode(payload), cek: cek, context: context))
            let wrapperContext = SelectiveRemoteResourceWrapperContext(teamID: teamID, vaultID: vaultID, resourceID: resourceID, part: part, keyVersion: 1, membershipID: membershipID, membershipEpoch: 2, deviceID: deviceID)
            let wrapper = try json(SelectiveRemoteResourceCryptoV2.wrap(cek, for: identity.publicKey, context: wrapperContext))
            let entry: SelectiveRemoteJSONValue = .object(["accountID": .string(accountID.canonicalCloudString), "deviceKeyVersion": .number(3), "wrapper": wrapper])
            let parent = conversion?["parentFolderID"] ?? (kind == .host ? .string(folderID.canonicalCloudString) : kind == .snippet ? .string(snippetFolderID.canonicalCloudString) : .null)
            cores.append(.object(["resourceID": .string(resourceID.canonicalCloudString), "kind": .string(kind.rawValue), "part": .string(part.rawValue), "parentFolderID": parent, "context": try json(context), "ciphertextHash": .string(try SelectiveRemoteVaultPublicationV1.hash("ciphertext", envelope)), "wrapperRoot": .string(try SelectiveRemoteVaultPublicationV1.hash("wrapper-leaf", entry))]))
            bodies.append((envelope, entry))
        }
        let header = try sign("header", .object(["version": .number(1), "teamID": .string(teamID.canonicalCloudString), "vaultID": .string(vaultID.canonicalCloudString), "generationID": .string(generationID.canonicalCloudString), "sequence": .number(1), "previousHash": .null, "descriptorCommitment": .string(try SelectiveRemoteVaultPublicationV1.hash("descriptors", .array(cores))), "publisherAccountID": .string(publisherAccount.canonicalCloudString), "publisherDeviceID": .string(publisherDevice.canonicalCloudString), "publisherKeyVersion": .number(3)]))
        let hash = try SelectiveRemoteVaultPublicationV1.hash("header", header)
        descriptors = try cores.map { core in var object = try core.publicationObject(); object["headerHash"] = .string(hash); return try sign("descriptor", .object(object)) }
        let subject: SelectiveRemoteJSONValue = .object(["accountID": .string(accountID.canonicalCloudString), "deviceID": .string(deviceID.canonicalCloudString), "membershipID": .string(membershipID.canonicalCloudString), "membershipEpoch": .number(2)])
        let items = try descriptors.map { d -> SelectiveRemoteJSONValue in let p = try SelectiveRemoteVaultPublicationV1.descriptorPayload(d); return .object(["resourceID": p["resourceID"]!, "part": p["part"]!, "descriptorHash": .string(try SelectiveRemoteVaultPublicationV1.hash("descriptor", d))]) }
        var inventoryPayload = try subject.publicationObject(); inventoryPayload["headerHash"] = .string(hash); inventoryPayload["count"] = .number(Double(descriptors.count)); inventoryPayload["digest"] = .string(try SelectiveRemoteVaultPublicationV1.hash("inventory-items", .array(items)))
        let inventory = try sign("inventory", .object(inventoryPayload))
        headerResponse = .object(["header": header, "headerHash": .string(hash), "subject": subject, "inventory": inventory])
        directory = .object(["headerHash": .string(hash), "generationID": .string(generationID.canonicalCloudString), "inventory": inventory, "descriptors": .array(descriptors), "nextCursor": .null])
        publisher = .object(["headerHash": .string(hash), "generationID": .string(generationID.canonicalCloudString), "accountID": .string(publisherAccount.canonicalCloudString), "deviceID": .string(publisherDevice.canonicalCloudString), "keyVersion": .number(3), "rootPublicKey": .string(publisherRoot.publicKey.x963Representation.selectiveRemoteBase64URL), "certificate": try json(pubCert), "checkpoint": try json(pubCheckpoint)])
        var map: [String: SelectiveRemoteJSONValue] = [:]
        for (index, descriptor) in descriptors.enumerated() {
            let p = try SelectiveRemoteVaultPublicationV1.descriptorPayload(descriptor)
            map["resources/" + (try p["resourceID"]!.publicationString()) + "/parts/" + (try p["part"]!.publicationString())] = .object(["headerHash": .string(hash), "generationID": .string(generationID.canonicalCloudString), "descriptor": descriptor, "envelope": bodies[index].0, "entry": bodies[index].1, "proof": .object(["index": .number(0), "total": .number(1), "siblings": .array([])])])
        }
        parts = map
    }
}

@Suite("native verified publication coordinator")
struct CloudVaultPublicationCoordinatorTests {
    @Test("complete 2000-part inventory spans twenty bounded pages without automatic SECRET retrieval")
    func completeInventory() async throws {
        let fixture = try PublicationFixture(credentialCount: 1000), (reader, remote, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner)
        #expect(cache.descriptors.count == 2000); #expect(cache.parts.count == 1000)
        #expect(await remote.requests.filter { $0 == "directory" }.count == 20)
        #expect(await remote.requests.allSatisfy { !$0.hasSuffix("/SECRET") })
    }
    @Test("independent cross-publisher confirmation, wrong fingerprint rejection and local key mismatch fail closed")
    func trustAndKey() async throws {
        let fixture = try PublicationFixture(crossPublisher: true), (reader, _, store, session, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        var challenge: SelectiveRemotePublisherVerification?
        do { _ = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner) }
        catch let value as SelectiveRemotePublisherVerification { challenge = value }
        let verified = try #require(challenge)
        await #expect(throws: Error.self) { try await reader.confirmPublisher(verified, independentlyObtainedFingerprint: "wrong") }
        #expect(try store.load(scope: fixture.scope, session: session) == nil)
        try await reader.confirmPublisher(verified, independentlyObtainedFingerprint: verified.fingerprint)
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner)
        #expect(cache.parts.count == 1)
        await #expect(throws: Error.self) { try await reader.confirmPublisher(verified, independentlyObtainedFingerprint: verified.fingerprint) }
        let wrongKey = try SelectiveRemoteTeamDeviceIdentity(deviceID: fixture.scope.deviceID, privateKeyRepresentation: P256.KeyAgreement.PrivateKey().rawRepresentation)
        let changed = SelectiveRemoteVaultPublicationCoordinator(scope: fixture.scope, session: session, remote: PublicationFixtureRemote(fixture), identity: wrongKey, store: store, ownPin: { _, _ in fixture.ownPin }, advanceOwnPin: { _, _, _ in })
        await #expect(throws: Error.self) { try await changed.load(teamName: "Team", vaultName: "Vault", role: .owner) }
        await #expect(throws: Error.self) { try await changed.offline() }
        let unpinned = SelectiveRemoteVaultPublicationCoordinator(scope: fixture.scope, session: session, remote: PublicationFixtureRemote(fixture), identity: fixture.identity, store: store, ownPin: { _, _ in nil }, advanceOwnPin: { _, _, _ in })
        await #expect(throws: Error.self) { try await unpinned.load(teamName: "Team", vaultName: "Vault", role: .owner) }
    }
    func setup(_ fixture: PublicationFixture) throws -> (SelectiveRemoteVaultPublicationCoordinator, PublicationFixtureRemote, SelectiveRemoteVaultPublicationStore, SelectiveRemotePublicationSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "task5-\(UUID())")
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: PublicationProtectedMemory())
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken(String(repeating: "x", count: 40), for: fixture.scope.endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: String(repeating: "x", count: 40), tokenStore: tokens)
        let remote = PublicationFixtureRemote(fixture)
        let pin = fixture.ownPin
        let coordinator = SelectiveRemoteVaultPublicationCoordinator(scope: fixture.scope, session: session, remote: remote, identity: fixture.identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        return (coordinator, remote, store, session, directory)
    }
    @Test("actual metadata decrypt is durable and SECRET fetch occurs only after explicit reveal; stale cache blocks SECRET")
    func pipeline() async throws {
        let fixture = try PublicationFixture(); let (reader, remote, store, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        #expect(cache.parts.count == 1); #expect(cache.parts[0].part == .metadata)
        #expect(!(await remote.requests).contains(where: { $0.hasSuffix("SECRET") }))
        #expect(try await reader.reveal(resourceID: fixture.resourceID) == "test-only-secret")
        await remote.setFault("offline")
        let stale = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        #expect(stale.stale)
        await #expect(throws: Error.self) { try await reader.reveal(resourceID: fixture.resourceID) }
        #expect(try store.highWater(scope: fixture.scope)?.sequence == 1)
    }
    @Test("missing cross-account pin, partial or repeated pages and oversized descriptor page reject before display")
    func failures() async throws {
        for fault in ["partial", "repeat", "oversized", "pointer"] {
            let fixture = try PublicationFixture(); let (reader, remote, _, _, directory) = try setup(fixture)
            defer { try? FileManager.default.removeItem(at: directory) }
            await remote.setFault(fault)
            await #expect(throws: Error.self) { try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer) }
        }
        let fixture = try PublicationFixture(crossPublisher: true); let (reader, _, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: SelectiveRemotePublisherVerification.self) { try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer) }
    }
    @Test("authoritative denial removes encrypted live payload but retains high-water; logout during part request cannot publish")
    func authority() async throws {
        let fixture = try PublicationFixture(); let (reader, remote, store, session, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer)
        await remote.setFault("denied")
        await #expect(throws: Error.self) { try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer) }
        #expect(try store.load(scope: fixture.scope, session: session) == nil)
        #expect(try store.highWater(scope: fixture.scope)?.sequence == 1)
        await remote.setFault(nil)
        await remote.setHook { route in if route.contains("/parts/") { session.invalidate() } }
        await #expect(throws: CancellationError.self) { try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer) }
    }
    @Test("empty signed inventory is materialized without artificial resource")
    func empty() async throws {
        let fixture = try PublicationFixture(empty: true); let (reader, _, _, _, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await reader.load(teamName: "Team", vaultName: "Vault", role: .viewer).parts.isEmpty)
    }
}

final class PublicationIdentityMemory: SelectiveRemoteTeamDeviceKeyStore, @unchecked Sendable {
    let raw: Data
    init(_ identity: SelectiveRemoteTeamDeviceIdentity) { raw = identity.privateKey.rawRepresentation }
    func privateKeyRepresentation(for endpoint: URL, deviceID: UUID) throws -> Data? { raw }
    func savePrivateKeyIfAbsent(_ representation: Data, for endpoint: URL, deviceID: UUID) throws -> Data { raw }
    func removePrivateKey(for endpoint: URL, deviceID: UUID) throws {}
}
actor PublicationAutoSyncFixture: SelectiveRemoteTeamVaultAutoSyncRemote {
    let fixture: PublicationFixture
    let transport: PublicationFixtureRemote
    let protected = PublicationProtectedMemory()
    let directory: URL
    let tokens = SelectiveRemoteCloudMemoryTokenStore()
    var mode: CloudAccessFormatState = .active
    var probeFailure = false
    var legacyCalls = 0
    var listFault: String?
    var reader: SelectiveRemoteVaultPublicationCoordinator?
    init(_ fixture: PublicationFixture, directory: URL) {
        self.fixture = fixture; self.directory = directory; transport = PublicationFixtureRemote(fixture)
        tokens.saveToken(String(repeating: "a", count: 40), for: fixture.scope.endpoint)
    }
    func setMode(_ value: CloudAccessFormatState) { mode = value }
    func setProbeFailure() { probeFailure = true }
    func setListFault(_ value: String?) { listFault = value }
    func resetProcessEpoch() { SelectiveRemotePublicationLifecycle.invalidate(endpoint: fixture.scope.endpoint) }
    func restoreAuthentication() { tokens.saveToken(String(repeating: "a", count: 40), for: fixture.scope.endpoint) }
    func retirePublications(session: SelectiveRemotePublicationSession, selection: SelectiveRemotePublicationRetirement) async throws {
        _ = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: protected).retireScopes(session: session, selection: selection)
    }
    func preparePublicationRetirement(session: SelectiveRemotePublicationSession) async throws {
        try SelectiveRemoteVaultPublicationStore(directory: directory, protected: protected).captureRetirementOwners(session: session)
    }
    func hasStoredSession(endpoint: URL) async -> Bool { true }
    func publicationSession(endpoint: URL, deviceID: UUID) async throws -> SelectiveRemotePublicationSession? {
        .init(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: String(repeating: "a", count: 40), tokenStore: tokens)
    }
    func vaultFormat(endpoint: URL, teamID: UUID, vaultID: UUID) async throws -> CloudAccessFormatState { if probeFailure { throw URLError(.notConnectedToInternet) }; return mode }
    func teams(endpoint: URL) async throws -> [SelectiveRemoteCloudTeam] {
        if listFault?.hasPrefix("team-auth") == true {
            let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
                (Data(#"{"error":"authentication_required"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            })
            return try await client.teams(endpoint: endpoint)
        }
        if listFault == "offline" { throw URLError(.notConnectedToInternet) }
        if listFault == "team-denied" { throw SelectiveRemoteCloudError.serviceError(403, "team_not_found") }
        if listFault == "team-omitted" { return [] }
        return [.init(id: fixture.scope.teamID, name: "Team", membershipID: UUID(), role: .viewer, membershipEpoch: 2, createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z")]
    }
    func sharedVaults(endpoint: URL, teamID: UUID) async throws -> [SelectiveRemoteCloudSharedVault] {
        if listFault == "vault-denied" { throw SelectiveRemoteCloudError.serviceError(404, "team_not_found") }
        if listFault == "vault-omitted" { return [] }
        return [.init(id: fixture.scope.vaultID, teamID: teamID, name: "Vault", revision: 1, keyGeneration: 1, rotationRequired: false, createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z")]
    }
    func materializePublication(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity, team: SelectiveRemoteCloudTeam, vault: SelectiveRemoteCloudSharedVault, offline: Bool) async throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        let pin = fixture.ownPin
        let coordinator = SelectiveRemoteVaultPublicationCoordinator(scope: fixture.scope, session: session, remote: transport, identity: identity, store: try .init(directory: directory, protected: protected), ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
        reader = coordinator
        let cache = offline ? try await coordinator.offline() : try await coordinator.load(teamName: team.name, vaultName: vault.name, role: team.role)
        return try cache.materializedSnapshot()
    }
    func reopenPublications(session: SelectiveRemotePublicationSession, identity: SelectiveRemoteTeamDeviceIdentity) async throws -> [SelectiveRemoteTeamVaultMaterializedSnapshot] {
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: protected)
        var result: [SelectiveRemoteTeamVaultMaterializedSnapshot] = []
        for scope in try store.cachedScopes(session: session) {
            let pin = fixture.ownPin
            let reader = SelectiveRemoteVaultPublicationCoordinator(scope: scope, session: session, remote: transport, identity: identity, store: store, ownPin: { _, _ in pin }, advanceOwnPin: { _, _, _ in })
            if let cache = try? await reader.offline() { result.append(try cache.materializedSnapshot()) }
        }
        return result
    }
    func teamKeyDevices(endpoint: URL, teamID: UUID, vaultID: UUID) async throws -> [SelectiveRemoteCloudTeamKeyDevice] { legacyCalls += 1; throw SelectiveRemotePublicationError.invalid }
    func sharedVault(endpoint: URL, teamID: UUID, vaultID: UUID) async throws -> SelectiveRemoteCloudSharedVaultEnvelope { legacyCalls += 1; throw SelectiveRemotePublicationError.invalid }
    func grantSharedVaultWrapper(endpoint: URL, teamID: UUID, vaultID: UUID, keyGeneration: Int, wrapper: SelectiveRemoteTeamVaultKeyWrapper, idempotencyKey: String) async throws -> SelectiveRemoteCloudTeamVaultWrapperGrant { legacyCalls += 1; throw SelectiveRemotePublicationError.invalid }
    func putSharedVault(endpoint: URL, teamID: UUID, vaultID: UUID, upload: SelectiveRemoteCloudTeamVaultUpload, idempotencyKey: String) async throws -> SelectiveRemoteCloudTeamVaultWriteResult { legacyCalls += 1; throw SelectiveRemotePublicationError.invalid }
}
actor PublicationSnapshotSink {
    var snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot] = []
    func replace(_ value: [SelectiveRemoteTeamVaultMaterializedSnapshot]) { snapshots = value }
}
@Suite("actual publication autosync lifecycle")
struct CloudVaultPublicationAutoSyncTests {
    @Test("authoritative list loss cannot reopen revoked durable scope during next offline preflight", arguments: ["team-denied", "team-omitted", "vault-denied", "vault-omitted", "team-auth", "team-auth-restart", "team-auth-legacy-receipt"])
    func listRetirement(_ fault: String) async throws {
        let fixture = try PublicationFixture(), directory = FileManager.default.temporaryDirectory.appending(path: "task5-retire-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PublicationAutoSyncFixture(fixture, directory: directory), sink = PublicationSnapshotSink()
        let auto = SelectiveRemoteTeamVaultAutoSync(remote: remote, identityManager: .init(store: PublicationIdentityMemory(fixture.identity)), snapshotStore: { SelectiveRemoteTeamVaultMemorySnapshotStore() }, snapshotConsumer: { await sink.replace($0) })
        _ = try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID)
        let session = try #require(try await remote.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID))
        let store = try SelectiveRemoteVaultPublicationStore(directory: directory, protected: remote.protected)
        let highWater = try #require(try store.highWater(scope: fixture.scope))
        #expect(try store.load(scope: fixture.scope, session: session) != nil)
        if fault == "team-auth-restart" || fault == "team-auth-legacy-receipt" {
            if fault == "team-auth-legacy-receipt" {
                let key = "receipt/" + SHA256.hash(data: Data(fixture.scope.key.utf8)).map { String(format: "%02x", $0) }.joined()
                var receipt = try JSONSerialization.jsonObject(with: #require(remote.protected.read(key))) as! [String: Any]
                receipt.removeValue(forKey: "authorizationVersion"); receipt["authorization"] = String(repeating: "1", count: 64)
                try remote.protected.save(JSONSerialization.data(withJSONObject: receipt), key: key)
            }
            await remote.resetProcessEpoch()
        }
        await remote.setListFault(fault)
        if fault == "team-denied" || fault.hasPrefix("team-auth") { await #expect(throws: Error.self) { try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) } }
        else { _ = try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) }
        await remote.restoreAuthentication()
        let checking = try #require(try await remote.publicationSession(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID))
        #expect(try store.load(scope: fixture.scope, session: checking) == nil)
        #expect(try store.cachedScopes(session: checking).isEmpty)
        #expect(try store.highWater(scope: fixture.scope) == highWater)
        await remote.setListFault("offline")
        _ = try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID)
        #expect(await sink.snapshots.isEmpty)
    }
    @Test("actual autosync selects publication, reopens protected cache on failed context, blocks preparation and never falls back to V1")
    func modes() async throws {
        let fixture = try PublicationFixture(), directory = FileManager.default.temporaryDirectory.appending(path: "task5-auto-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PublicationAutoSyncFixture(fixture, directory: directory), sink = PublicationSnapshotSink()
        let auto = SelectiveRemoteTeamVaultAutoSync(remote: remote, identityManager: .init(store: PublicationIdentityMemory(fixture.identity)), snapshotStore: { SelectiveRemoteTeamVaultMemorySnapshotStore() }, snapshotConsumer: { await sink.replace($0) })
        let report = try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID)
        #expect(report.synchronizedVaults == 1)
        #expect(await remote.legacyCalls == 0)
        #expect(await sink.snapshots.first?.publication?.parts.count == 1)
        await remote.setProbeFailure()
        _ = try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID)
        #expect(await sink.snapshots.first?.publication?.stale == true)
        #expect(await remote.legacyCalls == 0)
        let remote2 = PublicationAutoSyncFixture(fixture, directory: directory)
        await remote2.setMode(.preparing)
        let blocked = SelectiveRemoteTeamVaultAutoSync(remote: remote2, identityManager: .init(store: PublicationIdentityMemory(fixture.identity)), snapshotStore: { SelectiveRemoteTeamVaultMemorySnapshotStore() }, snapshotConsumer: { await sink.replace($0) })
        let blockedReport = try await blocked.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID)
        #expect(blockedReport.failures == 1); #expect(await remote2.legacyCalls == 0)
    }
    @Test("stop withdraws eligibility immediately and delayed old reader cannot repopulate actual consumer")
    func stop() async throws {
        let fixture = try PublicationFixture(), directory = FileManager.default.temporaryDirectory.appending(path: "task5-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PublicationAutoSyncFixture(fixture, directory: directory), sink = PublicationSnapshotSink(), gate = PublicationRequestGate()
        await remote.transport.setHook { route in if route == "header" { await gate.pause() } }
        let auto = SelectiveRemoteTeamVaultAutoSync(remote: remote, identityManager: .init(store: PublicationIdentityMemory(fixture.identity)), snapshotStore: { SelectiveRemoteTeamVaultMemorySnapshotStore() }, snapshotConsumer: { await sink.replace($0) })
        let pending = Task { try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) }
        while !(await gate.started) { await Task.yield() }
        await auto.stop()
        await #expect(throws: CancellationError.self) { try await auto.synchronizeOnce(endpoint: fixture.scope.endpoint, deviceID: fixture.scope.deviceID) }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await sink.snapshots.isEmpty)
    }
}

@Suite("actual published native models")
struct CloudVaultPublicationActualModelTests {
    @MainActor
    @Test("actual JS converter output materializes assigned IDs, duplicate ordinals, missing IDs and byte-distinct folders through native crypto")
    func actualConverter() async throws {
        let fixture = try PublicationFixture(converterProduced: true), (reader, _, _, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner), snapshot = try cache.materializedSnapshot()
        let hosts = try SelectiveRemoteTeamHostMaterializer.materialize(snapshot), snippets = try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot)
        #expect(hosts.count == 2); #expect(snippets.count == 2)
        #expect(Set(hosts.map(\.recordID)).count == 2); #expect(Set(snippets.map(\.recordID)).count == 2)
        for host in hosts { #expect(host.publication?.resourceID == host.recordID) }
        for snippet in snippets { #expect(snippet.publication?.resourceID == snippet.recordID) }
        let folders = try cache.folders()
        #expect(folders.count == 4); #expect(Set(folders.map { $0.reference.resourceID }).count == 4)
        #expect(Set(folders.map { Data($0.component.utf8) }).count == 4)
        let originalFixture = try JSONDecoder().decode(SelectiveRemoteJSONValue.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "native-converter-mapped-v1", withExtension: "json", subdirectory: "Fixtures")))).publicationObject()
        for original in try originalFixture["parts"]!.publicationArray() {
            let p = try original.publicationObject(), body = try p["payload"]!.publicationObject()
            guard p["part"] != .string("SECRET") else { continue }
            let part = try #require(cache.parts.first { .string($0.resourceID.canonicalCloudString) == p["resourceID"] && .string($0.part.rawValue) == p["part"] })
            let loaded = try cache.payload(part)
            for key in ["record", "folder", "metadata"] { #expect(loaded[key] == body[key]) }
        }
        let secret = try await reader.secretRecord(resourceID: fixture.resourceID)
        #expect(secret.id == fixture.resourceID); #expect(try secret.data.publicationObject()["secret"] == .string("CONVERTER-SYNTHETIC-SECRET"))
        #expect(try cache.forwardings().first?.record.id == cache.forwardings().first?.reference.resourceID)
        let presentation = SelectiveRemotePublicationPresentation(); try presentation.bind(reader: reader, session: session, scope: fixture.scope); presentation.replace(with: [snapshot])
        #expect(presentation.folders().count == 4)
        let ambiguous = try #require(hosts.first { $0.profile.connectionType == .ssh })
        await #expect(throws: Error.self) { try await presentation.hostCredentials(ambiguous) }
    }
    @Test("mapped runtime identity cannot conceal a mismatched original rich Host profile identity")
    func nativeProfileIdentity() async throws {
        let fixture = try PublicationFixture(allKinds: true, nativeProfileMismatch: true), (reader, _, _, _, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: Error.self) { try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner) }
    }
    @MainActor
    @Test("published RDP detail eligibility uses current publication and resolves SECRET on action")
    func rdpDetail() async throws {
        let fixture = try PublicationFixture(allKinds: true, transport: "rdp"), (reader, remote, _, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner), snapshot = try cache.materializedSnapshot()
        let host = try #require(try SelectiveRemoteTeamHostMaterializer.materialize(snapshot).first)
        let presentation = SelectiveRemotePublicationPresentation()
        try presentation.bind(reader: reader, session: session, scope: fixture.scope); presentation.replace(with: [snapshot])
        #expect(host.credentials.password == nil)
        #expect(presentation.connectionEnabled(host, temporaryPassword: ""))
        #expect(await remote.requests.filter { $0.hasSuffix("/SECRET") }.isEmpty)
        var connected: String?
        try await presentation.performHostConnection(host) { connected = $0.password }
        #expect(connected == "test-only-secret")
        session.invalidate(); #expect(!presentation.connectionEnabled(host, temporaryPassword: "ignored"))
    }
    @MainActor
    @Test("published Telnet uses authenticated host and port without unrelated credential authorization", arguments: [false, true])
    func telnet(_ includeSecret: Bool) async throws {
        let fixture = try PublicationFixture(allKinds: true, includeSecret: includeSecret, transport: "telnet", credentialKind: "ssh"), (reader, remote, _, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner), snapshot = try cache.materializedSnapshot()
        let host = try #require(try SelectiveRemoteTeamHostMaterializer.materialize(snapshot).first)
        let presentation = SelectiveRemotePublicationPresentation()
        try presentation.bind(reader: reader, session: session, scope: fixture.scope); presentation.replace(with: [snapshot])
        var connected = false
        try await presentation.performHostConnection(host) { #expect($0 == .empty); connected = true }
        #expect(connected)
        #expect(await remote.requests.filter { $0.hasSuffix("/SECRET") }.isEmpty)
    }
    @Test("native linked record materialization retains opaque or absent original IDs and exact Folder bytes", arguments: ["legacy-id", "<missing>"])
    func mappedRecords(_ source: String) async throws {
        let fixture = try PublicationFixture(allKinds: true, sourceID: source == "<missing>" ? nil : source, omitSourceID: source == "<missing>")
        let (reader, _, _, _, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner)
        let snapshot = try cache.materializedSnapshot(), hosts = try SelectiveRemoteTeamHostMaterializer.materialize(snapshot), snippets = try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot)
        #expect(hosts.count == 1); #expect(snippets.count == 1); #expect(try cache.forwardings().count == 1)
        for part in cache.parts where part.kind == .host || part.kind == .snippet {
            let original = try cache.payload(part)["record"]!.publicationObject()
            #expect(original["id"] == (source == "<missing>" ? nil : .string(source)))
            #expect(try cache.reference(recordID: part.resourceID, kind: part.kind)?.resourceID == part.resourceID)
        }
        #expect(try await reader.secretRecord(resourceID: fixture.resourceID).id == fixture.resourceID)
    }
    @Test("published Folder grammar preserves padded, long and byte-distinct Unicode components", arguments: [" A ", String(repeating: "x", count: 121), "é", "e\u{301}"])
    func exactFolders(_ name: String) async throws {
        let fixture = try PublicationFixture(allKinds: true, folderName: name), (reader, _, _, _, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner), snapshot = try cache.materializedSnapshot()
        #expect(Data(try #require(try SelectiveRemoteTeamHostMaterializer.materialize(snapshot).first).profile.group.utf8) == Data(name.utf8))
        #expect(Data(try #require(try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot).first).folder.utf8) == Data(name.utf8))
        #expect(try cache.folders().allSatisfy { Data($0.component.utf8) == Data(name.utf8) })
    }
    @MainActor
    @Test("published Host operation cannot fall back to agent or automatic authentication when SECRET is unavailable")
    func hostMissingSecret() async throws {
        let fixture = try PublicationFixture(allKinds: true, includeSecret: false), (reader, _, _, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner), snapshot = try cache.materializedSnapshot()
        let host = try #require(try SelectiveRemoteTeamHostMaterializer.materialize(snapshot).first)
        var profile = host.profile; profile.sshAuthenticationMode = .agent
        let agentHost = SelectiveRemoteTeamHost(id: host.id, recordID: host.recordID, teamID: host.teamID, teamName: host.teamName, role: host.role, vaultID: host.vaultID, vaultName: host.vaultName, revision: host.revision, keyGeneration: host.keyGeneration, modifiedAt: host.modifiedAt, address: host.address, profile: profile, credentials: host.credentials, publication: host.publication)
        let presentation = SelectiveRemotePublicationPresentation()
        try presentation.bind(reader: reader, session: session, scope: fixture.scope); presentation.replace(with: [snapshot])
        await #expect(throws: Error.self) { try await presentation.hostCredentials(agentHost) }
    }
    @MainActor
    @Test("late SECRET denial from old login cannot clear newer live models or newer encrypted payload")
    func secretRelogin() async throws {
        let fixture = try PublicationFixture(), (oldReader, oldRemote, store, oldSession, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await oldReader.load(teamName: "Team", vaultName: "Vault", role: .owner)
        let gate = PublicationRequestGate()
        await oldRemote.setHook { route in if route.hasSuffix("/SECRET") { await gate.pause() } }
        let pending = Task { try await oldReader.reveal(resourceID: fixture.resourceID) }
        while !(await gate.started) { await Task.yield() }
        oldSession.invalidate()
        let tokens = SelectiveRemoteCloudMemoryTokenStore(); tokens.saveToken(String(repeating: "r", count: 40), for: fixture.scope.endpoint)
        let newer = SelectiveRemotePublicationSession(endpoint: fixture.scope.endpoint, accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID, token: String(repeating: "r", count: 40), tokenStore: tokens)
        let reader = SelectiveRemoteVaultPublicationCoordinator(scope: fixture.scope, session: newer, remote: PublicationFixtureRemote(fixture), identity: fixture.identity, store: store, ownPin: { _, _ in fixture.ownPin }, advanceOwnPin: { _, _, _ in })
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner), snapshot = try cache.materializedSnapshot()
        let presentation = SelectiveRemotePublicationPresentation.shared
        defer { presentation.detach(scope: fixture.scope, expectedSession: newer) }
        try presentation.bind(reader: reader, session: newer, scope: fixture.scope); presentation.replace(with: [snapshot])
        let reference = try #require(try cache.reference(cache.parts[0]) as SelectiveRemotePublishedModelReference?)
        await oldRemote.setFault("denied"); await gate.release()
        await #expect(throws: Error.self) { try await pending.value }
        #expect(presentation.valid(reference)); #expect(try store.load(scope: fixture.scope, session: newer) == cache)
        #expect(presentation.secret(reference) == nil)
    }
    @MainActor
    @Test("verified parts feed ordinary Host, Credential metadata and Snippet stores plus actual Forwarding and Folder references")
    func models() async throws {
        let fixture = try PublicationFixture(allKinds: true)
        let (reader, _, _, session, directory) = try CloudVaultPublicationCoordinatorTests().setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await reader.load(teamName: "Team", vaultName: "Vault", role: .owner)
        let snapshot = try cache.materializedSnapshot()
        let hosts = SelectiveRemoteTeamHostStore(), snippets = SelectiveRemoteTeamSnippetStore(), credentials = SelectiveRemoteTeamCredentialStore()
        hosts.replace(with: [snapshot]); snippets.replace(with: [snapshot]); credentials.replace(with: [snapshot])
        #expect(hosts.hosts.count == 1); #expect(snippets.snippets.count == 1); #expect(credentials.credentials.count == 1)
        #expect(hosts.hosts.first?.profile.group == "Authorized hosts")
        #expect(snippets.snippets.first?.folder == "Authorized snippets")
        let credential = try #require(credentials.credentials.first)
        #expect(credential.title == "Published credential"); #expect(credential.username == "alice"); #expect(credential.secret == nil)
        let reference = try #require(credential.publication)
        #expect(try reference.access(displayName: credential.title).resourceID == fixture.resourceID)
        #expect(reference.resourceID != credential.id)
        let presentation = SelectiveRemotePublicationPresentation()
        try presentation.bind(reader: reader, session: session, scope: fixture.scope); presentation.replace(with: [snapshot])
        #expect(presentation.forwardings.count == 1)
        #expect(presentation.forwardings.first?.reference.kind == .forwarding)
        #expect(cache.parts.filter { $0.kind == .folder }.count == 2)
        #expect(presentation.canReveal(reference))
        #expect(try await presentation.hostCredentials(try #require(hosts.hosts.first)).password == "test-only-secret")
        #expect(presentation.verifiedParts(reference: try reference.access(displayName: credential.title), accountID: fixture.scope.accountID, deviceID: fixture.scope.deviceID) == [.metadata])
        #expect(presentation.verifiedParts(reference: try reference.access(displayName: credential.title), accountID: fixture.scope.accountID, deviceID: UUID()).isEmpty)
        #expect(try await presentation.reveal(reference) == "test-only-secret")
        session.invalidate()
        #expect(!presentation.valid(reference)); #expect(presentation.secret(reference) == nil)
    }
}
