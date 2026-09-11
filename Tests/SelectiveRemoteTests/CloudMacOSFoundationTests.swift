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
                    "user": [
                        "id": userID.uuidString.lowercased(),
                        "email": "user@example.invalid",
                        "username": "user",
                        "displayName": "User",
                        "createdAt": "2026-09-10T00:00:00.000Z"
                    ],
                    "deviceID": deviceID.uuidString.lowercased()
                ])
            case ("GET", "/v1/me"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return Self.response(request, status: 200, json: [
                    "id": userID.uuidString.lowercased(), "email": "user@example.invalid", "username": "user", "displayName": "User",
                    "deviceID": deviceID.uuidString.lowercased()
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
        #expect(user == SelectiveRemoteCloudUser(id: userID, email: "user@example.invalid", username: "user", displayName: "User"))
        #expect(try store.token(for: endpoint) == token)
        let hasStoredSession = await client.hasStoredSession(endpoint: endpoint)
        #expect(hasStoredSession)
        #expect(try await client.currentUser(endpoint: endpoint) == user)
        let teams = try await client.teams(endpoint: endpoint)
        #expect(teams.count == 1)
        #expect(teams[0].role == .owner)
        #expect(teams[0].membershipEpoch == 3)
        let restoredClient = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )
        #expect(await restoredClient.hasStoredSession(endpoint: endpoint))
        #expect(try await restoredClient.currentUser(endpoint: endpoint) == user)
        try await restoredClient.logout(endpoint: endpoint)
        #expect(try store.token(for: endpoint) == nil)
    }

    @Test("native Team management creates Teams, invitations and Shared Vaults")
    func nativeTeamManagement() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let userID = try #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        let invitationID = try #require(UUID(uuidString: "77777777-7777-4777-8777-777777777777"))
        let linkInvitationID = try #require(UUID(uuidString: "88888888-8888-4888-8888-888888888888"))
        let vaultID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let store = SelectiveRemoteCloudMemoryTokenStore()
        try store.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let stub = CloudHTTPStub { request in
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key")?.hasPrefix("macos:") == true
                || request.httpMethod == "GET")
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/teams"):
                #expect(Self.stringBodyValue(request, key: "name") == "Platform")
                return Self.response(request, status: 201, json: ["team": [
                    "id": teamID.canonicalCloudString, "name": "Platform",
                    "membershipID": membershipID.canonicalCloudString, "role": "owner", "membershipEpoch": 1,
                    "createdAt": "2026-09-09T00:00:00.000Z", "updatedAt": "2026-09-09T00:00:00.000Z"
                ]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/members"):
                return Self.response(request, status: 200, json: ["members": [[
                    "id": membershipID.canonicalCloudString, "userID": userID.canonicalCloudString,
                    "username": "owner", "displayName": "Owner", "role": "owner",
                    "epoch": 1, "joinedAt": "2026-09-09T00:00:00.000Z"
                ]]])
            case ("POST", "/v1/teams/\(teamID.canonicalCloudString)/invitations"):
                #expect(Self.stringBodyValue(request, key: "role") == "viewer")
                if Self.stringBodyValue(request, key: "type") == "link" {
                    return Self.response(request, status: 201, json: ["invitation": [
                        "id": linkInvitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                        "teamName": "Platform", "type": "link", "targetUsername": NSNull(),
                        "role": "viewer", "status": "pending",
                        "acceptanceURL": "https://cloud.example.invalid/#accept-team-invitation?token=\(String(repeating: "x", count: 43))",
                        "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                    ]])
                }
                #expect(Self.stringBodyValue(request, key: "username") == "viewer")
                return Self.response(request, status: 201, json: ["invitation": [
                    "id": invitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "teamName": "Platform", "type": "username", "targetUsername": "viewer",
                    "role": "viewer", "status": "pending", "acceptanceURL": NSNull(),
                    "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                ]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/invitations"):
                return Self.response(request, status: 200, json: ["invitations": [[
                    "id": invitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "teamName": "Platform", "type": "username", "targetUsername": "viewer",
                    "role": "viewer", "status": "pending", "acceptanceURL": NSNull(),
                    "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                ]]])
            case ("GET", "/v1/team-invitations"):
                return Self.response(request, status: 200, json: ["invitations": [[
                    "id": invitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "teamName": "Platform", "type": "username", "targetUsername": "viewer",
                    "role": "viewer", "status": "pending", "acceptanceURL": NSNull(),
                    "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                ]]])
            case ("POST", "/v1/team-invitations/accept"):
                #expect(Self.stringBodyValue(request, key: "invitationID") == invitationID.canonicalCloudString)
                return Self.response(request, status: 200, json: ["membership": [
                    "id": membershipID.canonicalCloudString, "userID": userID.canonicalCloudString,
                    "username": "viewer", "displayName": "Viewer", "role": "viewer",
                    "epoch": 1, "joinedAt": "2026-09-09T00:00:00.000Z"
                ]])
            case ("DELETE", "/v1/teams/\(teamID.canonicalCloudString)/invitations/\(linkInvitationID.canonicalCloudString)"):
                return Self.response(request, status: 200, json: ["cancelled": true])
            case ("POST", "/v1/teams/\(teamID.canonicalCloudString)/vaults"):
                #expect(Self.stringBodyValue(request, key: "name") == "Production")
                return Self.response(request, status: 201, json: ["vault": [
                    "id": vaultID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "name": "Production", "revision": 0, "keyGeneration": 1,
                    "rotationRequired": false, "createdAt": "2026-09-09T00:00:00.000Z",
                    "updatedAt": "2026-09-09T00:00:00.000Z"
                ]])
            default:
                Issue.record("Unexpected Team management request")
                return Self.response(request, status: 500, json: ["error": "unexpected_request"])
            }
        }
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            try stub.data(for: request)
        })

        #expect(try await client.createTeam(endpoint: endpoint, name: " Platform ").name == "Platform")
        #expect(try await client.teamMembers(endpoint: endpoint, teamID: teamID).first?.role == .owner)
        #expect(try await client.inviteTeamMember(
            endpoint: endpoint, teamID: teamID, username: " @Viewer ", role: .viewer
        ).targetUsername == "viewer")
        #expect(try await client.teamInvitations(endpoint: endpoint, teamID: teamID).count == 1)
        #expect(try await client.pendingTeamInvitations(endpoint: endpoint).first?.teamName == "Platform")
        let link = try await client.createTeamInvitationLink(endpoint: endpoint, teamID: teamID, role: .viewer)
        #expect(link.id == linkInvitationID)
        #expect(link.acceptanceURL?.hasSuffix(String(repeating: "x", count: 43)) == true)
        #expect(try await client.acceptTeamInvitation(
            endpoint: endpoint, invitationID: invitationID
        ).username == "viewer")
        try await client.cancelTeamInvitation(
            endpoint: endpoint, teamID: teamID, invitationID: linkInvitationID
        )
        #expect(try await client.createSharedVault(
            endpoint: endpoint, teamID: teamID, name: " Production "
        ).id == vaultID)
    }

    @Test("registration sends the device public identity and requires exact verification response")
    func registrationFoundation() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let store = SelectiveRemoteCloudMemoryTokenStore()
        let stub = CloudHTTPStub { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/auth/register")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(object.keys) == ["email", "password", "username", "displayName", "device"])
            #expect(object["email"] as? String == "user@example.invalid")
            #expect(object["password"] as? String == "synthetic-password")
            #expect(object["displayName"] as? String == "User")
            #expect(object["username"] as? String == "leonid")
            let device = try #require(object["device"] as? [String: Any])
            #expect(device["id"] as? String == deviceID.canonicalCloudString)
            #expect(device["name"] as? String == "Synthetic Mac")
            #expect(device["platform"] as? String == "macos")
            return Self.response(request, status: 201, json: ["verificationRequired": true])
        }
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )

        try await client.register(
            endpoint: endpoint,
            displayName: " User ",
            username: " Leonid ",
            email: " user@example.invalid ",
            password: "synthetic-password",
            device: .thisMac(id: deviceID, name: "Synthetic Mac")
        )
        #expect(try store.token(for: endpoint) == nil)
    }

    @Test("registration rejects an extended or false verification response")
    func registrationRejectsInvalidResponses() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let invalidResponses: [[String: Any]] = [
            ["verificationRequired": false],
            ["verificationRequired": true, "unexpected": true]
        ]
        for json in invalidResponses {
            let payload = try JSONSerialization.data(withJSONObject: json)
            let client = SelectiveRemoteCloudAPIClient(
                tokenStore: SelectiveRemoteCloudMemoryTokenStore(),
                dataLoader: { request in
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(
                        url: url,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    ))
                    return (payload, response)
                }
            )
            await #expect(throws: SelectiveRemoteCloudError.invalidResponse) {
                try await client.register(
                    endpoint: endpoint,
                    displayName: "User",
                    username: "user",
                    email: "user@example.invalid",
                    password: "synthetic-password",
                    device: .thisMac(id: deviceID, name: "Synthetic Mac")
                )
            }
        }
    }

    @Test("macOS account inventory rejects extended user and Team responses")
    func accountInventoryRejectsExtendedResponses() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let token = String(repeating: "t", count: 43)
        let userID = try #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let store = SelectiveRemoteCloudMemoryTokenStore()
        try store.saveToken(token, for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in
                switch request.url?.path {
                case "/v1/me":
                    Self.response(request, status: 200, json: [
                        "id": userID.canonicalCloudString,
                        "email": "user@example.invalid",
                        "displayName": "User",
                        "unexpected": true
                    ])
                case "/v1/teams":
                    Self.response(request, status: 200, json: ["teams": [[
                        "id": teamID.canonicalCloudString,
                        "name": "Platform",
                        "membershipID": membershipID.canonicalCloudString,
                        "role": "owner",
                        "membershipEpoch": 3,
                        "createdAt": "2026-09-07T00:00:00.000Z",
                        "updatedAt": "2026-09-07T00:00:00.000Z",
                        "unexpected": true
                    ]]])
                default:
                    Self.response(request, status: 500, json: ["error": "unexpected_request"])
                }
            }
        )

        await #expect(throws: SelectiveRemoteCloudError.invalidResponse) {
            try await client.currentUser(endpoint: endpoint)
        }
        await #expect(throws: SelectiveRemoteCloudError.invalidResponse) {
            try await client.teams(endpoint: endpoint)
        }
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
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
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
            case ("POST", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)/wrappers"):
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "macos:team:vault:grant-1")
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(Set(object.keys) == ["keyGeneration", "wrapper"])
                #expect(object["keyGeneration"] as? Int == 7)
                let encodedWrapper = try #require(object["wrapper"] as? [String: Any])
                #expect(encodedWrapper["deviceID"] as? String == deviceID.canonicalCloudString)
                return Self.response(request, status: 201, json: [
                    "granted": true,
                    "keyGeneration": 7,
                    "deviceID": deviceID.canonicalCloudString
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
        let grant = try await client.grantSharedVaultWrapper(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: 7,
            wrapper: wrapper,
            idempotencyKey: "macos:team:vault:grant-1"
        )
        #expect(grant == .init(granted: true, keyGeneration: 7, deviceID: deviceID))
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

    @Test("current macOS key holder provisions another admitted device")
    func teamVaultWrapperProvisioning() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let membershipID = try fixture.wrapper.membershipID.uuid
        let recipientID = try #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        let recipientMembershipID = try #require(
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        )
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let recipient = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: recipientID,
            privateKeyRepresentation: Data(repeating: 0x03, count: 32)
        )
        let actorWrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let keyDevices: [SelectiveRemoteCloudTeamKeyDevice] = [
            .init(
                membershipID: membershipID,
                membershipEpoch: fixture.wrapper.membershipEpoch,
                deviceID: deviceID,
                publicKeyAlgorithm: "p256-ecdh-v1",
                publicKey: identity.publicKey,
                hasWrapper: true
            ),
            .init(
                membershipID: recipientMembershipID,
                membershipEpoch: 1,
                deviceID: recipientID,
                publicKeyAlgorithm: "p256-ecdh-v1",
                publicKey: recipient.publicKey,
                hasWrapper: false
            )
        ]
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: actorWrapper),
            writeResult: .init(
                conflict: false,
                revision: 6,
                keyGeneration: fixture.wrapper.keyGeneration,
                rotationCompleted: false
            ),
            keyDevices: keyDevices
        )
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: SelectiveRemoteTeamVaultMemorySnapshotStore()
        )

        #expect(try await coordinator.provisionMissingWrappers(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        ) == 1)
        let grants = await remote.recordedGrants()
        let grantedWrapper = try #require(grants.first?.wrapper)
        #expect(grants.count == 1)
        #expect(grants.first?.keyGeneration == fixture.wrapper.keyGeneration)
        #expect(grants.first?.idempotencyKey.hasPrefix("macos:team-vault:grant:") == true)
        #expect(try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            grantedWrapper,
            with: recipient,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.wrapper.keyGeneration
        ) == fixture.keyWrap.vaultKey.base64URLData)
    }

    @Test("macOS background cycle provisions wrappers and refreshes ciphertext")
    func teamVaultBackgroundSync() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let membershipID = try fixture.wrapper.membershipID.uuid
        let recipientID = try #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        let recipientMembershipID = try #require(
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        )
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let recipient = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: recipientID,
            privateKeyRepresentation: Data(repeating: 0x03, count: 32)
        )
        let team = SelectiveRemoteCloudTeam(
            id: teamID,
            name: "Platform",
            membershipID: membershipID,
            role: .viewer,
            membershipEpoch: fixture.wrapper.membershipEpoch,
            createdAt: "2026-09-09T00:00:00.000Z",
            updatedAt: "2026-09-09T00:00:00.000Z"
        )
        let vault = SelectiveRemoteCloudSharedVault(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: fixture.payload.baseRevision + 1,
            keyGeneration: fixture.wrapper.keyGeneration,
            rotationRequired: false,
            createdAt: "2026-09-09T00:00:00.000Z",
            updatedAt: "2026-09-09T00:00:00.000Z"
        )
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(
                fixture,
                wrapper: try Self.fixtureWrapper(fixture, identity: identity)
            ),
            writeResult: .init(
                conflict: false,
                revision: 6,
                keyGeneration: fixture.wrapper.keyGeneration,
                rotationCompleted: false
            ),
            teams: [team],
            vaults: [vault],
            keyDevices: [
                .init(
                    membershipID: membershipID,
                    membershipEpoch: fixture.wrapper.membershipEpoch,
                    deviceID: deviceID,
                    publicKeyAlgorithm: "p256-ecdh-v1",
                    publicKey: identity.publicKey,
                    hasWrapper: true
                ),
                .init(
                    membershipID: recipientMembershipID,
                    membershipEpoch: 1,
                    deviceID: recipientID,
                    publicKeyAlgorithm: "p256-ecdh-v1",
                    publicKey: recipient.publicKey,
                    hasWrapper: false
                )
            ]
        )
        let keyStore = SelectiveRemoteTeamDeviceMemoryKeyStore()
        _ = try keyStore.savePrivateKeyIfAbsent(
            try fixture.keyWrap.recipientPrivateScalar.base64URLData,
            for: endpoint,
            deviceID: deviceID
        )
        let snapshots = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let materialized = TeamVaultMaterializedSnapshotSink()
        let autoSync = SelectiveRemoteTeamVaultAutoSync(
            remote: remote,
            identityManager: SelectiveRemoteTeamDeviceIdentityManager(store: keyStore),
            snapshotStore: { snapshots },
            snapshotConsumer: { await materialized.replace(with: $0) }
        )

        let report = try await autoSync.synchronizeOnce(
            endpoint: endpoint,
            deviceID: deviceID
        )
        #expect(report.scannedVaults == 1)
        #expect(report.synchronizedVaults == 1)
        #expect(report.wrappersGranted == 1)
        #expect(report.pendingWrappers == 0)
        #expect(report.failures == 0)
        #expect(try snapshots.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) != nil)
        let published = await materialized.snapshots()
        #expect(published.count == 1)
        #expect(published.first?.teamID == teamID)
        #expect(published.first?.vaultID == vaultID)
        #expect(published.first?.role == .viewer)
        let expectedPayload = try fixture.payload.plaintext.base64URLData
        #expect(published.first?.payload == expectedPayload)
    }

    @Test("Team Vault coordinator stages and acknowledges one causal upload")
    func teamVaultSyncUpload() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: false, revision: 6, keyGeneration: 7, rotationCompleted: false)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )

        let refreshed = try await coordinator.refresh(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .synchronized(initial) = refreshed else {
            Issue.record("Expected the first remote revision to be synchronized")
            return
        }
        let initialPayload = try fixture.payload.plaintext.base64URLData
        #expect(initial.payload == initialPayload)
        #expect(initial.snapshot.serverRevision == 5)
        #expect(initial.snapshot.localRevision == initial.snapshot.syncedLocalRevision)

        let editedPayload = Data("synthetic local edit".utf8)
        let staged = try await coordinator.stage(
            editedPayload,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        #expect(staged.snapshot.envelope.baseRevision == 5)
        #expect(staged.snapshot.localRevision == 2)
        #expect(staged.snapshot.syncedLocalRevision == 1)

        let pushed = try await coordinator.push(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .uploaded(uploaded) = pushed else {
            Issue.record("Expected the staged payload to upload")
            return
        }
        #expect(uploaded.payload == editedPayload)
        #expect(uploaded.snapshot.serverRevision == 6)
        #expect(uploaded.snapshot.localRevision == uploaded.snapshot.syncedLocalRevision)
        let writes = await remote.recordedWrites()
        #expect(writes.count == 1)
        #expect(writes.first?.upload.envelope == staged.snapshot.envelope)
        #expect(writes.first?.idempotencyKey.contains(staged.snapshot.envelope.contentHash) == true)
    }

    @Test("Team Vault coordinator initializes encrypted host data for the approved device set")
    func teamVaultInitialization() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let vaultID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: Data(repeating: 0x31, count: 32)
        )
        let empty = SelectiveRemoteCloudSharedVaultEnvelope(
            id: vaultID, teamID: teamID, name: "Operations", revision: 0,
            keyGeneration: 1, rotationRequired: false, envelopeVersion: nil,
            ciphertext: nil, nonce: nil, authTag: nil, contentHash: nil, wrapper: nil,
            createdAt: "2026-09-08T00:00:00.000Z", updatedAt: "2026-09-08T00:00:00.000Z"
        )
        let remote = TeamVaultRemoteStub(
            envelope: empty,
            writeResult: .init(conflict: false, revision: 1, keyGeneration: 1, rotationCompleted: false)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint, remote: remote, snapshots: storage
        )
        let payload = Data(#"{"records":["synthetic-host"]}"#.utf8)
        let outcome = try await coordinator.initialize(
            payload: payload,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity,
            keyDevices: [.init(
                membershipID: membershipID,
                membershipEpoch: 1,
                deviceID: deviceID,
                publicKeyAlgorithm: "p256-ecdh-v1",
                publicKey: identity.publicKey,
                hasWrapper: false
            )]
        )
        guard case let .uploaded(uploaded) = outcome else {
            Issue.record("Expected initialization to commit")
            return
        }
        #expect(uploaded.payload == payload)
        #expect(uploaded.snapshot.serverRevision == 1)
        #expect(uploaded.snapshot.syncedLocalRevision == 1)
        let writes = await remote.recordedWrites()
        #expect(writes.count == 1)
        #expect(writes[0].upload.wrappers?.count == 1)
        #expect(writes[0].upload.envelope.baseRevision == 0)
        let vaultKey = try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            uploaded.snapshot.wrapper,
            with: identity,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: 1
        )
        #expect(try SelectiveRemoteTeamVaultCrypto.decryptPayload(
            uploaded.snapshot.envelope,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID
        ) == payload)
    }

    @Test("Team Vault coordinator preserves the dirty snapshot and both conflict versions")
    func teamVaultSyncConflict() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )
        _ = try await coordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity)

        let localPayload = Data("synthetic local conflict".utf8)
        let staged = try await coordinator.stage(
            localPayload,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        let remotePayload = Data("synthetic remote conflict".utf8)
        let remoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            remotePayload,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 5,
            nonce: Data(repeating: 0x23, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 6,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: remoteCiphertext.envelopeVersion,
            ciphertext: remoteCiphertext.ciphertext,
            nonce: remoteCiphertext.nonce,
            authTag: remoteCiphertext.authTag,
            contentHash: remoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T00:00:00.000Z"
        ))

        let pushed = try await coordinator.push(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .conflict(conflict) = pushed else {
            Issue.record("Expected an explicit causal conflict")
            return
        }
        #expect(conflict.local.payload == localPayload)
        #expect(conflict.remote.payload == remotePayload)
        #expect(conflict.local.snapshot.envelope == staged.snapshot.envelope)
        let preserved = try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        #expect(preserved == staged.snapshot)

        let newerRemotePayload = Data("synthetic newer remote conflict".utf8)
        let newerRemoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            newerRemotePayload,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 6,
            nonce: Data(repeating: 0x24, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 7,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: newerRemoteCiphertext.envelopeVersion,
            ciphertext: newerRemoteCiphertext.ciphertext,
            nonce: newerRemoteCiphertext.nonce,
            authTag: newerRemoteCiphertext.authTag,
            contentHash: newerRemoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T01:00:00.000Z"
        ))
        let staleResolution = try await coordinator.resolveConflict(
            conflict,
            resolvedPayload: Data("must not upload".utf8),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .conflict(updatedConflict) = staleResolution else {
            Issue.record("Expected a changed remote version to return a new conflict")
            return
        }
        #expect(updatedConflict.remote.revision == 7)
        #expect(updatedConflict.remote.payload == newerRemotePayload)
        #expect(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == staged.snapshot)
        let staleResolutionWrites = await remote.recordedWrites()
        #expect(staleResolutionWrites.count == 1)

        let resolvedPayload = Data("synthetic joined conflict resolution".utf8)
        await remote.setWriteFailure(.unknownOutcome)
        await #expect(throws: TeamVaultRemoteStubFailure.unknownOutcome) {
            try await coordinator.resolveConflict(
                updatedConflict,
                resolvedPayload: resolvedPayload,
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            )
        }
        let storedPendingResolution = try storage.load(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        )
        let pendingResolution = try #require(storedPendingResolution)
        #expect(pendingResolution.envelope.baseRevision == 7)
        #expect(pendingResolution.localRevision > pendingResolution.syncedLocalRevision)

        await remote.setWriteFailure(nil)
        await remote.setWriteResult(.init(
            conflict: false,
            revision: 8,
            keyGeneration: fixture.payload.keyGeneration,
            rotationCompleted: false
        ))
        let resolution = try await coordinator.push(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .uploaded(uploaded) = resolution else {
            Issue.record("Expected the explicit conflict resolution to upload")
            return
        }
        #expect(uploaded.payload == resolvedPayload)
        #expect(uploaded.snapshot.serverRevision == 8)
        #expect(uploaded.snapshot.envelope.baseRevision == 7)
        #expect(uploaded.snapshot.localRevision == uploaded.snapshot.syncedLocalRevision)
        let resolutionWrites = await remote.recordedWrites()
        #expect(resolutionWrites.count == 3)
        #expect(resolutionWrites.last?.upload.envelope.baseRevision == 7)
        #expect(resolutionWrites[1].idempotencyKey == resolutionWrites[2].idempotencyKey)
        #expect(resolutionWrites.last?.idempotencyKey != resolutionWrites.first?.idempotencyKey)
    }

    @Test("Team Vault conflict resolution preserves an edit staged during remote revalidation")
    func teamVaultConflictResolutionReentrancy() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: try fixture.wrapper.deviceID.uuid,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )
        _ = try await coordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity)
        _ = try await coordinator.stage(
            Data("synthetic original local conflict".utf8),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )

        let remotePayload = Data("synthetic remote conflict".utf8)
        let remoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            remotePayload,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 5,
            nonce: Data(repeating: 0x26, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 6,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: remoteCiphertext.envelopeVersion,
            ciphertext: remoteCiphertext.ciphertext,
            nonce: remoteCiphertext.nonce,
            authTag: remoteCiphertext.authTag,
            contentHash: remoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T00:00:00.000Z"
        ))
        let pushed = try await coordinator.push(teamID: teamID, vaultID: vaultID, identity: identity)
        guard case let .conflict(conflict) = pushed else {
            Issue.record("Expected an explicit conflict")
            return
        }

        let barrier = TeamVaultReadBarrier()
        await remote.setReadBarrier(barrier)
        let resolving = Task {
            try await coordinator.resolveConflict(
                conflict,
                resolvedPayload: Data("must not replace racing edit".utf8),
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            )
        }
        await barrier.waitUntilSuspended()
        let racingPayload = Data("synthetic racing local edit".utf8)
        let racing = try await coordinator.stage(
            racingPayload,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        await barrier.resume()

        await #expect(throws: SelectiveRemoteTeamVaultSyncError.staleConflict) {
            try await resolving.value
        }
        let preserved = try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        #expect(preserved == racing.snapshot)
        let writes = await remote.recordedWrites()
        #expect(writes.count == 1)
    }

    @Test("Team Vault record workflow requires a complete causal choice before upload")
    func teamVaultRecordConflictWorkflow() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: try fixture.wrapper.deviceID.uuid,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )
        _ = try await coordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity)

        let deviceA = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let deviceB = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let recordID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let localRecord = try SelectiveRemoteVaultRecord(
            id: recordID,
            type: .host,
            version: .init([deviceA: 2]),
            modifiedAt: "2026-09-07T01:00:00.000Z",
            data: .object(["title": .string("Local")])
        )
        let remoteRecord = try SelectiveRemoteVaultRecord(
            id: recordID,
            type: .host,
            version: .init([deviceA: 1, deviceB: 1]),
            modifiedAt: "2026-09-07T02:00:00.000Z",
            data: .object(["title": .string("Remote")])
        )
        let localDocument = try SelectiveRemoteVaultDocument(records: [localRecord])
        let remoteDocument = try SelectiveRemoteVaultDocument(records: [remoteRecord])
        _ = try await coordinator.stage(
            localDocument.encoded(),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        let remoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            remoteDocument.encoded(),
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 5,
            nonce: Data(repeating: 0x27, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 6,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: remoteCiphertext.envelopeVersion,
            ciphertext: remoteCiphertext.ciphertext,
            nonce: remoteCiphertext.nonce,
            authTag: remoteCiphertext.authTag,
            contentHash: remoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T02:00:00.000Z"
        ))

        let pushed = try await coordinator.push(teamID: teamID, vaultID: vaultID, identity: identity)
        guard case let .conflict(transportConflict) = pushed else {
            Issue.record("Expected a transport conflict")
            return
        }
        let prepared = try await coordinator.prepareRecordConflict(transportConflict)
        #expect(prepared.mergedDocument.records.isEmpty)
        #expect(prepared.recordConflicts.map(\.id) == [recordID])
        await #expect(throws: SelectiveRemoteVaultDocumentError.incompleteConflictResolutions) {
            try await coordinator.resolveRecordConflicts(
                prepared,
                resolutions: [],
                resolvedAt: "2026-09-07T03:00:00.000Z",
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            )
        }

        await remote.setWriteResult(.init(
            conflict: false,
            revision: 7,
            keyGeneration: fixture.payload.keyGeneration,
            rotationCompleted: false
        ))
        let resolved = try await coordinator.resolveRecordConflicts(
            prepared,
            resolutions: [.init(id: recordID, choice: .remote)],
            resolvedAt: "2026-09-07T03:00:00.000Z",
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .uploaded(snapshot, document) = resolved else {
            Issue.record("Expected a resolved record upload")
            return
        }
        #expect(snapshot.snapshot.serverRevision == 7)
        #expect(document.records[0].data == .object(["title": .string("Remote")]))
        #expect(document.records[0].version.counters == [
            deviceA: 2,
            deviceB: 1,
            identity.deviceID: 1
        ])
        let writes = await remote.recordedWrites()
        #expect(writes.count == 2)
        #expect(writes.last?.upload.envelope.baseRevision == 6)
    }

    @Test("Team Vault coordinator fails closed while key rotation is required")
    func teamVaultSyncRotationGate() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: try fixture.wrapper.deviceID.uuid,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        var blocked = Self.remoteEnvelope(fixture, wrapper: wrapper)
        blocked.rotationRequired = true
        let remote = TeamVaultRemoteStub(
            envelope: blocked,
            writeResult: .init(conflict: false, revision: 6, keyGeneration: 7, rotationCompleted: false)
        )
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: SelectiveRemoteTeamVaultMemorySnapshotStore()
        )
        await #expect(throws: SelectiveRemoteTeamVaultSyncError.rotationRequired) {
            try await coordinator.refresh(
                teamID: try fixture.wrapper.teamID.uuid,
                vaultID: try fixture.wrapper.vaultID.uuid,
                identity: identity
            )
        }
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

    private static func fixtureWrapper(
        _ fixture: TeamVaultFixture,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) throws -> SelectiveRemoteTeamVaultKeyWrapper {
        try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
            fixture.keyWrap.vaultKey.base64URLData,
            for: identity.publicKey,
            context: SelectiveRemoteTeamWrapperContext(
                teamID: try fixture.wrapper.teamID.uuid,
                vaultID: try fixture.wrapper.vaultID.uuid,
                keyGeneration: fixture.wrapper.keyGeneration,
                membershipID: try fixture.wrapper.membershipID.uuid,
                membershipEpoch: fixture.wrapper.membershipEpoch,
                deviceID: identity.deviceID
            ),
            ephemeralPrivateKeyRepresentation: fixture.keyWrap.ephemeralPrivateScalar.base64URLData,
            nonce: fixture.keyWrap.nonce.base64URLData
        )
    }

    private static func remoteEnvelope(
        _ fixture: TeamVaultFixture,
        wrapper: SelectiveRemoteTeamVaultKeyWrapper
    ) -> SelectiveRemoteCloudSharedVaultEnvelope {
        .init(
            id: UUID(uuidString: fixture.wrapper.vaultID)!,
            teamID: UUID(uuidString: fixture.wrapper.teamID)!,
            name: "Operations",
            revision: fixture.payload.baseRevision + 1,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: fixture.payload.envelopeVersion,
            ciphertext: fixture.payload.ciphertext,
            nonce: fixture.payload.nonce,
            authTag: fixture.payload.authTag,
            contentHash: fixture.payload.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-06T00:00:00.000Z"
        )
    }

    private static func stringBodyValue(_ request: URLRequest, key: String) -> String? {
        guard let body = request.httpBody,
              let value = try? JSONSerialization.jsonObject(with: body),
              let object = value as? [String: Any]
        else { return nil }
        return object[key] as? String
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

@Suite("Account-password Personal Vault enrollment")
struct AccountPasswordPersonalVaultEnrollmentTests {
    @Test("macOS derives the browser-compatible passphrase and unwraps the Vault key")
    func accountPasswordRoundTrip() throws {
        let password = "correct horse battery"
        let passphrase = try SelectiveRemotePersonalVaultCrypto.accountPassphrase(password)
        #expect(passphrase == "selective-remote:account-password:v1:correct horse battery")
        let document = try SelectiveRemoteVaultDocument(records: [], tombstones: [])
        let setup = try SelectiveRemotePersonalVaultCrypto.createSetup(
            document,
            recoveryPhrase: passphrase,
            baseRevision: 0
        )

        let unwrapped = try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(
            setup.envelope.wrappedKey,
            passphrase: passphrase
        )
        #expect(unwrapped == setup.vaultKey)
        #expect(try SelectiveRemotePersonalVaultCrypto.open(setup.envelope, vaultKey: unwrapped) == document)
        #expect(throws: SelectiveRemotePersonalVaultError.self) {
            try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(
                setup.envelope.wrappedKey,
                passphrase: "selective-remote:account-password:v1:different password"
            )
        }
    }

    @Test("canonically equivalent account passwords derive the same passphrase")
    func unicodeNormalization() throws {
        #expect(
            try SelectiveRemotePersonalVaultCrypto.accountPassphrase("mot-de-passe-café")
                == SelectiveRemotePersonalVaultCrypto.accountPassphrase("mot-de-passe-cafe\u{301}")
        )
    }

    @Test("a newly enrolled remote Vault cannot upload before initial download")
    func remoteEnrollmentUploadGate() throws {
        let material = try SelectiveRemotePersonalVaultKeyMaterial(
            vaultID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            vaultKey: Data(repeating: 1, count: 32),
            wrappedKey: .init(salt: Data(repeating: 2, count: 16), value: Data(repeating: 3, count: 40)),
            revision: 2,
            documentHash: Data(repeating: 4, count: 32),
            requiresInitialDownload: true
        )
        #expect(material.requiresInitialDownload == true)
        #expect(!material.allowsUpload)
    }
}

@Suite("Personal Vault initial download decoder")
struct PersonalVaultInitialDownloadDecoderTests {
    @Test("macOS export round-trips into typed local resources")
    func exportedResourcesRoundTrip() throws {
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.host = "host.example"
        profile.friendlyName = "Production"
        let snippet = TerminalCommandTemplate(
            id: UUID(), profileID: UUID(uuidString: "5A17407D-9F03-4F7B-80FB-BD06D3FA50B1")!,
            title: "Uptime", command: "uptime", category: "Ops",
            targets: [.localTerminal], updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let forward = IndependentPortForward(
            connection: .custom(host: "jump.example", username: "root", port: 22),
            kind: .local
        )
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [profile], credentials: [], snippets: [snippet], forwarding: [forward],
            deviceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )

        let decoded = try SelectiveRemotePersonalVaultImporter.decode(exported.document)
        #expect(decoded.profiles.first?.id == profile.id)
        #expect(decoded.profiles.first?.friendlyName == profile.friendlyName)
        #expect(decoded.profiles.first?.host == profile.host)
        #expect(decoded.profiles.first?.connectionType == profile.connectionType)
        #expect(decoded.snippets == [snippet])
        #expect(decoded.forwarding == [forward])
        #expect(decoded.credentials.isEmpty)
    }

    @Test("web Host and Snippet receive bounded local defaults")
    func webRecords() throws {
        let version = try SelectiveRemoteVaultVersion([
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")!: 1
        ])
        let hostID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let snippetID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let document = try SelectiveRemoteVaultDocument(records: [
            try .init(id: hostID, type: .host, version: version, modifiedAt: "2026-09-10T00:00:00.000Z", data: .object([
                "title": .string("Web Host"), "address": .string("web.example"), "username": .string("admin"),
                "connectionType": .string("ssh"), "port": .number(2_222),
                "folder": .string("Work/Production"), "tags": .array([.string("linux"), .string("prod")]),
                "description": .string("Created in browser")
            ])),
            try .init(id: snippetID, type: .snippet, version: version, modifiedAt: "2026-09-10T00:00:00.000Z", data: .object([
                "title": .string("Status"), "body": .string("uptime")
            ]))
        ])
        let decoded = try SelectiveRemotePersonalVaultImporter.decode(document)
        #expect(decoded.profiles.first?.id == hostID)
        #expect(decoded.profiles.first?.connectionType == .ssh)
        #expect(decoded.profiles.first?.sshPort == 2_222)
        #expect(decoded.profiles.first?.group == "Work/Production")
        #expect(decoded.profiles.first?.tags == ["linux", "prod"])
        #expect(decoded.profiles.first?.profileDescription == "Created in browser")
        #expect(decoded.snippets.first?.id == snippetID)
    }

    @Test("empty Mac accepts additions while an ID collision blocks the whole plan")
    func conflictAwarePlan() throws {
        var remote = ConnectionProfile(connectionType: .ssh)
        remote.host = "remote.example"
        let snapshot = SelectiveRemotePersonalVaultImportSnapshot(
            profiles: [remote], credentials: [], snippets: [], forwarding: [], tombstoneIDs: []
        )
        let clean = SelectiveRemotePersonalVaultImporter.plan(
            snapshot: snapshot, localProfiles: [], localSnippets: [], localForwarding: []
        )
        #expect(clean.canApply)
        #expect(clean.profiles == [remote])

        var local = remote
        local.host = "local.example"
        let blocked = SelectiveRemotePersonalVaultImporter.plan(
            snapshot: snapshot, localProfiles: [local], localSnippets: [], localForwarding: []
        )
        #expect(!blocked.canApply)
        #expect(blocked.conflictIDs == [remote.id])
        #expect(blocked.profiles.isEmpty)
    }

    @Test("remote tombstones never silently delete local resources")
    func tombstoneCollision() {
        let local = ConnectionProfile(connectionType: .rdp)
        let snapshot = SelectiveRemotePersonalVaultImportSnapshot(
            profiles: [], credentials: [], snippets: [], forwarding: [], tombstoneIDs: [local.id]
        )
        let plan = SelectiveRemotePersonalVaultImporter.plan(
            snapshot: snapshot, localProfiles: [local], localSnippets: [], localForwarding: []
        )
        #expect(!plan.canApply)
        #expect(plan.conflictIDs == [local.id])
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

private enum TeamVaultRemoteStubFailure: Error, Equatable, Sendable {
    case unknownOutcome
}

private actor TeamVaultReadBarrier {
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while !suspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TeamVaultRemoteStub: SelectiveRemoteTeamVaultAutoSyncRemote {
    struct RecordedWrite: Equatable, Sendable {
        let upload: SelectiveRemoteCloudTeamVaultUpload
        let idempotencyKey: String
    }

    struct RecordedGrant: Equatable, Sendable {
        let wrapper: SelectiveRemoteTeamVaultKeyWrapper
        let keyGeneration: Int
        let idempotencyKey: String
    }

    private var envelope: SelectiveRemoteCloudSharedVaultEnvelope
    private var writeResult: SelectiveRemoteCloudTeamVaultWriteResult
    private var writeFailure: TeamVaultRemoteStubFailure?
    private var readBarrier: TeamVaultReadBarrier?
    private var writes: [RecordedWrite] = []
    private var grants: [RecordedGrant] = []
    private var teamValues: [SelectiveRemoteCloudTeam]
    private var vaultValues: [SelectiveRemoteCloudSharedVault]
    private var keyDeviceValues: [SelectiveRemoteCloudTeamKeyDevice]

    init(
        envelope: SelectiveRemoteCloudSharedVaultEnvelope,
        writeResult: SelectiveRemoteCloudTeamVaultWriteResult,
        teams: [SelectiveRemoteCloudTeam] = [],
        vaults: [SelectiveRemoteCloudSharedVault] = [],
        keyDevices: [SelectiveRemoteCloudTeamKeyDevice] = []
    ) {
        self.envelope = envelope
        self.writeResult = writeResult
        teamValues = teams
        vaultValues = vaults
        keyDeviceValues = keyDevices
    }

    func hasStoredSession(endpoint _: URL) async -> Bool {
        true
    }

    func teams(endpoint _: URL) async throws -> [SelectiveRemoteCloudTeam] {
        teamValues
    }

    func sharedVaults(
        endpoint _: URL,
        teamID: UUID
    ) async throws -> [SelectiveRemoteCloudSharedVault] {
        #expect(vaultValues.allSatisfy { $0.teamID == teamID })
        return vaultValues
    }

    func teamKeyDevices(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> [SelectiveRemoteCloudTeamKeyDevice] {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        return keyDeviceValues
    }

    func grantSharedVaultWrapper(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int,
        wrapper: SelectiveRemoteTeamVaultKeyWrapper,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWrapperGrant {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        #expect(envelope.keyGeneration == keyGeneration)
        guard let index = keyDeviceValues.firstIndex(where: { $0.deviceID == wrapper.deviceID }) else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        grants.append(.init(
            wrapper: wrapper,
            keyGeneration: keyGeneration,
            idempotencyKey: idempotencyKey
        ))
        keyDeviceValues[index].hasWrapper = true
        return .init(granted: true, keyGeneration: keyGeneration, deviceID: wrapper.deviceID)
    }

    func sharedVault(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> SelectiveRemoteCloudSharedVaultEnvelope {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        if let readBarrier {
            self.readBarrier = nil
            await readBarrier.suspend()
        }
        return envelope
    }

    func putSharedVault(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID,
        upload: SelectiveRemoteCloudTeamVaultUpload,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWriteResult {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        writes.append(.init(upload: upload, idempotencyKey: idempotencyKey))
        if let writeFailure {
            throw writeFailure
        }
        return writeResult
    }

    func setEnvelope(_ value: SelectiveRemoteCloudSharedVaultEnvelope) {
        envelope = value
    }

    func setWriteResult(_ value: SelectiveRemoteCloudTeamVaultWriteResult) {
        writeResult = value
    }

    func setWriteFailure(_ value: TeamVaultRemoteStubFailure?) {
        writeFailure = value
    }

    func setReadBarrier(_ value: TeamVaultReadBarrier?) {
        readBarrier = value
    }

    func recordedWrites() -> [RecordedWrite] {
        writes
    }

    func recordedGrants() -> [RecordedGrant] {
        grants
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


private actor TeamVaultMaterializedSnapshotSink {
    private var values: [SelectiveRemoteTeamVaultMaterializedSnapshot] = []

    func replace(with snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot]) {
        values = snapshots
    }

    func snapshots() -> [SelectiveRemoteTeamVaultMaterializedSnapshot] {
        values
    }
}


@Suite("Unified Cloud Keychain envelope")
struct CloudSecureEnvelopeModelTests {
    @Test("session and one device key round-trip in a single envelope")
    func roundTrip() throws {
        let key = Data(repeating: 0x2a, count: 32)
        let input = SelectiveRemoteCloudSecureEnvelope(
            sessionToken: "session-token",
            teamDevicePrivateKeys: ["device-id": key],
            personalVaultKeyMaterials: ["device-id": Data([4, 5, 6])]
        )
        let encoded = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(
            SelectiveRemoteCloudSecureEnvelope.self,
            from: encoded
        )
        #expect(decoded == input)
        #expect(!decoded.isEmpty)
        #expect(decoded.teamDevicePrivateKeys["device-id"] == key)
        #expect(decoded.personalVaultKeyMaterials["device-id"] == Data([4, 5, 6]))
    }

    @Test("empty envelope is removable")
    func emptyEnvelope() {
        #expect(SelectiveRemoteCloudSecureEnvelope().isEmpty)
    }

    @Test("older unified envelopes decode before Personal Vault material is added")
    func legacyEnvelopeDecoding() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "sessionToken": "token",
            "teamDevicePrivateKeys": [String: String]()
        ])
        let decoded = try JSONDecoder().decode(
            SelectiveRemoteCloudSecureEnvelope.self,
            from: legacy
        )
        #expect(decoded.sessionToken == "token")
        #expect(decoded.personalVaultKeyMaterials.isEmpty)
    }
}
