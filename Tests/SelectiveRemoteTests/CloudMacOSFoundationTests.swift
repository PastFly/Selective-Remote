import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Cloud session and Team crypto foundation")
struct CloudMacOSFoundationTests {
    @Test("login keeps the bearer token in the session store and authenticates later requests")
    func authenticatedFoundation() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let userID = try #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let token = String(repeating: "t", count: 43)
        let store = SelectiveRemoteCloudMemoryTokenStore()
        let stub = CloudHTTPStub { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/auth/login"):
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["password"] as? String == "synthetic-password")
                return Self.response(request, status: 200, json: [
                    "token": token,
                    "user": ["id": userID.uuidString.lowercased(), "email": "user@example.invalid", "displayName": "User"],
                    "deviceID": deviceID.uuidString.lowercased()
                ])
            case ("GET", "/v1/me"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return Self.response(request, status: 200, json: [
                    "id": userID.uuidString.lowercased(), "email": "user@example.invalid", "displayName": "User"
                ])
            case ("GET", "/v1/teams"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return Self.response(request, status: 200, json: ["teams": [[
                    "id": teamID.uuidString.lowercased(),
                    "name": "Platform",
                    "membershipID": membershipID.uuidString.lowercased(),
                    "role": "owner",
                    "membershipEpoch": 3,
                    "createdAt": "2026-09-06T00:00:00.000Z",
                    "updatedAt": "2026-09-06T00:00:00.000Z"
                ]]])
            case ("POST", "/v1/auth/logout"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return Self.response(request, status: 204, json: nil)
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return Self.response(request, status: 500, json: ["error": "unexpected_request"])
            }
        }
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )

        let user = try await client.login(
            endpoint: endpoint,
            email: " user@example.invalid ",
            password: "synthetic-password",
            device: .thisMac(id: deviceID, name: "Synthetic Mac")
        )
        #expect(user == SelectiveRemoteCloudUser(id: userID, email: "user@example.invalid", displayName: "User"))
        #expect(try store.token(for: endpoint) == token)
        #expect(try await client.currentUser(endpoint: endpoint) == user)
        let teams = try await client.teams(endpoint: endpoint)
        #expect(teams.count == 1)
        #expect(teams[0].role == .owner)
        #expect(teams[0].membershipEpoch == 3)
        try await client.logout(endpoint: endpoint)
        #expect(try store.token(for: endpoint) == nil)
    }

    @Test("a 401 response deletes the stored macOS Cloud session")
    func unauthorizedClearsSession() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let store = SelectiveRemoteCloudMemoryTokenStore()
        try store.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in Self.response(request, status: 401, json: ["error": "unauthorized"]) }
        )
        await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) {
            try await client.currentUser(endpoint: endpoint)
        }
        #expect(try store.token(for: endpoint) == nil)
    }

    @Test("browser and macOS use the same P-256 fingerprint and Team envelope context")
    func sharedCryptoFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "team-vault-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(TeamVaultFixture.self, from: Data(contentsOf: url))
        #expect(fixture.version == 1)
        #expect(SelectiveRemoteTeamVaultCrypto.deviceFingerprint(fixture.publicKey) == fixture.fingerprint)

        let wrapper = try SelectiveRemoteTeamWrapperContext(
            teamID: try fixture.wrapper.teamID.uuid,
            vaultID: try fixture.wrapper.vaultID.uuid,
            keyGeneration: fixture.wrapper.keyGeneration,
            membershipID: try fixture.wrapper.membershipID.uuid,
            membershipEpoch: fixture.wrapper.membershipEpoch,
            deviceID: try fixture.wrapper.deviceID.uuid
        )
        #expect(SelectiveRemoteTeamVaultCrypto.wrapperContext(wrapper).base64URL == fixture.wrapper.contextBase64URL)
        #expect(SelectiveRemoteTeamVaultCrypto.wrapperContextHash(wrapper) == fixture.wrapper.contextHash)
        #expect(try SelectiveRemoteTeamVaultCrypto.payloadContext(
            teamID: fixture.payload.teamID.uuid,
            vaultID: fixture.payload.vaultID.uuid,
            keyGeneration: fixture.payload.keyGeneration
        ).base64URL == fixture.payload.contextBase64URL)
        #expect(try SelectiveRemoteTeamVaultCrypto.payloadContentHash(
            teamID: fixture.payload.teamID.uuid,
            vaultID: fixture.payload.vaultID.uuid,
            keyGeneration: fixture.payload.keyGeneration,
            nonce: fixture.payload.nonce,
            ciphertext: fixture.payload.ciphertext,
            authTag: fixture.payload.authTag
        ) == fixture.payload.contentHash)
    }

    @Test("macOS rejects a private or extended Team JWK before cryptographic use")
    func rejectsExtendedJWK() {
        let data = Data(#"{"kty":"EC","crv":"P-256","x":"axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpY","y":"T-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU","ext":true,"key_ops":[],"d":"secret"}"#.utf8)
        #expect(throws: SelectiveRemoteTeamCryptoError.invalidPublicKey) {
            try JSONDecoder().decode(SelectiveRemoteTeamDevicePublicKey.self, from: data)
        }
    }

    @Test("device identity converges on one device-only stored P-256 key")
    func persistentDeviceIdentity() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let store = SelectiveRemoteTeamDeviceMemoryKeyStore()
        let first = try await SelectiveRemoteTeamDeviceIdentityManager(store: store)
            .identity(endpoint: endpoint, deviceID: deviceID)
        let second = try await SelectiveRemoteTeamDeviceIdentityManager(store: store)
            .identity(endpoint: endpoint, deviceID: deviceID)
        #expect(first.deviceID == deviceID)
        #expect(first.publicKey == second.publicKey)
        #expect(first.privateKey.rawRepresentation == second.privateKey.rawRepresentation)
    }

    @Test("macOS deterministic wrapper decrypts in the browser fixture format")
    func sharedKeyWrapFixture() throws {
        let fixture = try Self.fixture()
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        #expect(identity.publicKey == fixture.publicKey)
        let context = try SelectiveRemoteTeamWrapperContext(
            teamID: try fixture.wrapper.teamID.uuid,
            vaultID: try fixture.wrapper.vaultID.uuid,
            keyGeneration: fixture.wrapper.keyGeneration,
            membershipID: try fixture.wrapper.membershipID.uuid,
            membershipEpoch: fixture.wrapper.membershipEpoch,
            deviceID: deviceID
        )
        let wrapper = try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
            try fixture.keyWrap.vaultKey.base64URLData,
            for: fixture.publicKey,
            context: context,
            ephemeralPrivateKeyRepresentation: try fixture.keyWrap.ephemeralPrivateScalar.base64URLData,
            nonce: try fixture.keyWrap.nonce.base64URLData
        )
        #expect(wrapper.ephemeralPublicKey == fixture.keyWrap.ephemeralPublicKey)
        #expect(wrapper.ciphertext == fixture.keyWrap.ciphertext)
        #expect(wrapper.authTag == fixture.keyWrap.authTag)
        #expect(wrapper.contextHash == fixture.wrapper.contextHash)
        let expectedVaultKey = try fixture.keyWrap.vaultKey.base64URLData
        #expect(try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            wrapper,
            with: identity,
            teamID: context.teamID,
            vaultID: context.vaultID,
            keyGeneration: context.keyGeneration
        ) == expectedVaultKey)

        let otherVaultID = try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        #expect(throws: SelectiveRemoteTeamCryptoError.wrapperContextMismatch) {
            try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
                wrapper,
                with: identity,
                teamID: context.teamID,
                vaultID: otherVaultID,
                keyGeneration: context.keyGeneration
            )
        }
    }

    @Test("macOS deterministic payload decrypts in the browser fixture format")
    func sharedPayloadFixture() throws {
        let fixture = try Self.fixture()
        let payload = try fixture.payload.plaintext.base64URLData
        let vaultKey = try fixture.keyWrap.vaultKey.base64URLData
        let teamID = try fixture.payload.teamID.uuid
        let vaultID = try fixture.payload.vaultID.uuid
        let envelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            payload,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: fixture.payload.baseRevision,
            nonce: try fixture.payload.nonce.base64URLData
        )
        #expect(envelope.ciphertext == fixture.payload.ciphertext)
        #expect(envelope.authTag == fixture.payload.authTag)
        #expect(envelope.contentHash == fixture.payload.contentHash)
        #expect(try SelectiveRemoteTeamVaultCrypto.decryptPayload(
            envelope,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID
        ) == payload)

        let otherTeamID = try #require(UUID(uuidString: "99999999-9999-4999-8999-999999999999"))
        #expect(throws: SelectiveRemoteTeamCryptoError.payloadContentHashMismatch) {
            try SelectiveRemoteTeamVaultCrypto.decryptPayload(
                envelope,
                vaultKey: vaultKey,
                teamID: otherTeamID,
                vaultID: vaultID
            )
        }
    }

    @Test("typed macOS Team Vault transport preserves conditional conflict state")
    func teamVaultTransport() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let vaultID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let fixture = try Self.fixture()
        let token = String(repeating: "t", count: 43)
        let store = SelectiveRemoteCloudMemoryTokenStore()
        try store.saveToken(token, for: endpoint)
        let stub = CloudHTTPStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/vaults"):
                return Self.response(request, status: 200, json: ["vaults": [[
                    "id": vaultID.canonicalCloudString,
                    "teamID": teamID.canonicalCloudString,
                    "name": "Operations",
                    "revision": 5,
                    "keyGeneration": 7,
                    "rotationRequired": false,
                    "createdAt": "2026-09-06T00:00:00.000Z",
                    "updatedAt": "2026-09-06T00:00:00.000Z"
                ]]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)/key-devices"):
                return Self.response(request, status: 200, json: ["devices": [[
                    "membershipID": membershipID.canonicalCloudString,
                    "membershipEpoch": 3,
                    "deviceID": deviceID.canonicalCloudString,
                    "publicKeyAlgorithm": "p256-ecdh-v1",
                    "publicKey": [
                        "kty": fixture.publicKey.kty, "crv": fixture.publicKey.crv,
                        "x": fixture.publicKey.x, "y": fixture.publicKey.y,
                        "ext": fixture.publicKey.ext, "key_ops": fixture.publicKey.keyOps
                    ],
                    "hasWrapper": true
                ]]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)"):
                return Self.response(request, status: 200, json: [
                    "id": vaultID.canonicalCloudString,
                    "teamID": teamID.canonicalCloudString,
                    "name": "Operations",
                    "revision": 5,
                    "keyGeneration": 7,
                    "rotationRequired": false,
                    "envelopeVersion": fixture.payload.envelopeVersion,
                    "ciphertext": fixture.payload.ciphertext,
                    "nonce": fixture.payload.nonce,
                    "authTag": fixture.payload.authTag,
                    "contentHash": fixture.payload.contentHash,
                    "wrapper": NSNull(),
                    "createdAt": "2026-09-06T00:00:00.000Z",
                    "updatedAt": "2026-09-06T00:00:00.000Z"
                ])
            case ("PUT", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)"):
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "macos:team:vault:synthetic-1")
                #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) }?.contains("schemaVersion") == false)
                return Self.response(request, status: 409, json: [
                    "conflict": true, "revision": 6, "keyGeneration": 7
                ])
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return Self.response(request, status: 500, json: ["error": "unexpected_request"])
            }
        }
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )
        #expect(try await client.sharedVaults(endpoint: endpoint, teamID: teamID).map(\.id) == [vaultID])
        #expect(try await client.teamKeyDevices(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        ).map(\.deviceID) == [deviceID])
        let remote = try await client.sharedVault(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        let downloadedEnvelope = try remote.payloadEnvelope
        let envelope = try #require(downloadedEnvelope)
        #expect(envelope.contentHash == fixture.payload.contentHash)
        let result = try await client.putSharedVault(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID,
            upload: .init(envelope: envelope, wrappers: nil),
            idempotencyKey: "macos:team:vault:synthetic-1"
        )
        #expect(result == .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil))
    }

    @Test("offline Team Vault storage persists only the strict ciphertext snapshot")
    func ciphertextOnlySnapshot() throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
            try fixture.keyWrap.vaultKey.base64URLData,
            for: identity.publicKey,
            context: SelectiveRemoteTeamWrapperContext(
                teamID: teamID,
                vaultID: vaultID,
                keyGeneration: fixture.payload.keyGeneration,
                membershipID: try fixture.wrapper.membershipID.uuid,
                membershipEpoch: fixture.wrapper.membershipEpoch,
                deviceID: deviceID
            ),
            ephemeralPrivateKeyRepresentation: try fixture.keyWrap.ephemeralPrivateScalar.base64URLData,
            nonce: try fixture.keyWrap.nonce.base64URLData
        )
        let envelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            try fixture.payload.plaintext.base64URLData,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: fixture.payload.baseRevision,
            nonce: try fixture.payload.nonce.base64URLData
        )
        let snapshot = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: deviceID,
            keyGeneration: fixture.payload.keyGeneration,
            localRevision: 2,
            serverRevision: 5,
            syncedLocalRevision: 1,
            envelope: envelope,
            wrapper: wrapper
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "selective-remote-team-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SelectiveRemoteTeamVaultFileSnapshotStore(root: root)
        try storage.save(snapshot, endpoint: endpoint)
        #expect(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == snapshot)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".json") }
        let storedFile = try #require(files.first)
        let fileURL = root.appending(path: storedFile)
        let bytes = try Data(contentsOf: fileURL)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("schemaVersion"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        try storage.remove(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        #expect(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == nil)
    }

    private static func fixture() throws -> TeamVaultFixture {
        let url = try #require(Bundle.module.url(
            forResource: "team-vault-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(TeamVaultFixture.self, from: Data(contentsOf: url))
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        json: Any?
    ) -> (Data, URLResponse) {
        let data = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private final class CloudHTTPStub: @unchecked Sendable {
    let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private struct TeamVaultFixture: Decodable, Sendable {
    var version: Int
    var publicKey: SelectiveRemoteTeamDevicePublicKey
    var fingerprint: String
    var wrapper: Wrapper
    var keyWrap: KeyWrap
    var payload: Payload

    struct Wrapper: Decodable, Sendable {
        var teamID: String
        var vaultID: String
        var keyGeneration: Int
        var membershipID: String
        var membershipEpoch: Int
        var deviceID: String
        var contextBase64URL: String
        var contextHash: String
    }

    struct Payload: Decodable, Sendable {
        var teamID: String
        var vaultID: String
        var keyGeneration: Int
        var contextBase64URL: String
        var envelopeVersion: Int
        var baseRevision: Int
        var plaintext: String
        var nonce: String
        var ciphertext: String
        var authTag: String
        var contentHash: String
    }

    struct KeyWrap: Decodable, Sendable {
        var recipientPrivateScalar: String
        var ephemeralPrivateScalar: String
        var ephemeralPublicKey: SelectiveRemoteTeamDevicePublicKey
        var vaultKey: String
        var nonce: String
        var ciphertext: String
        var authTag: String
    }
}

private extension String {
    var uuid: UUID {
        get throws {
            guard let value = UUID(uuidString: self) else {
                throw SelectiveRemoteTeamCryptoError.invalidEnvelope
            }
            return value
        }
    }

    var base64URLData: Data {
        get throws {
            guard let value = Data(selectiveRemoteBase64URL: self) else {
                throw SelectiveRemoteTeamCryptoError.invalidEnvelope
            }
            return value
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
