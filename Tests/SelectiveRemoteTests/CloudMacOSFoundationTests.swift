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

private struct TeamVaultFixture: Decodable {
    var version: Int
    var publicKey: SelectiveRemoteTeamDevicePublicKey
    var fingerprint: String
    var wrapper: Wrapper
    var payload: Payload

    struct Wrapper: Decodable {
        var teamID: String
        var vaultID: String
        var keyGeneration: Int
        var membershipID: String
        var membershipEpoch: Int
        var deviceID: String
        var contextBase64URL: String
        var contextHash: String
    }

    struct Payload: Decodable {
        var teamID: String
        var vaultID: String
        var keyGeneration: Int
        var contextBase64URL: String
        var envelopeVersion: Int
        var nonce: String
        var ciphertext: String
        var authTag: String
        var contentHash: String
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
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
