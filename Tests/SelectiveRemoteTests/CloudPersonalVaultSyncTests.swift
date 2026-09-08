import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Personal Vault first upload")
struct CloudPersonalVaultSyncTests {
    @Test("AES-256 key wrap matches the RFC 3394 vector")
    func aesKeyWrapVector() throws {
        let keyEncryptionKey = try #require(Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        let vaultKey = try #require(Data(hex: "00112233445566778899aabbccddeeff"))
        let expected = try #require(Data(hex: "64e8c3f9ce0f5ba263e9777905818a2a93c8191e7d6e8ae7"))

        #expect(try SelectiveRemotePersonalVaultCrypto.wrapRFC3394(
            vaultKey,
            keyEncryptionKey: keyEncryptionKey
        ) == expected)
    }

    @Test("export maps local records and the envelope contains no plaintext")
    func ciphertextOnlyExport() async throws {
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let profileID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let snippetID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.id = profileID
        profile.friendlyName = "Production Host"
        profile.host = "host.example.invalid"
        profile.username = "operator"
        let snippet = TerminalCommandTemplate(
            id: snippetID,
            profileID: profileID,
            title: "Deploy",
            command: "synthetic-secret-command",
            category: "Operations",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [profile],
            credentials: [.init(
                sourceID: profileID,
                kind: .ssh,
                title: "Production Host · SSH",
                username: "operator",
                secret: "synthetic-secret-password"
            )],
            snippets: [snippet],
            forwarding: [],
            deviceID: deviceID,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(exported.summary == .init(hosts: 1, credentials: 1, snippets: 1, forwarding: 0))
        #expect(exported.document.records.map(\.type).sorted(by: { $0.rawValue < $1.rawValue }) == [
            .credential, .host, .snippet
        ])

        let document = exported.document
        let envelope = try await Task.detached {
            try SelectiveRemotePersonalVaultCrypto.seal(
                document,
                recoveryPhrase: "correct horse battery staple",
                baseRevision: 0,
                vaultKey: Data(repeating: 0x11, count: 32),
                salt: Data(repeating: 0x22, count: 16),
                nonce: Data(repeating: 0x33, count: 12)
            )
        }.value
        let encodedEnvelope = try JSONEncoder().encode(envelope)
        let wireText = try #require(String(data: encodedEnvelope, encoding: .utf8))
        #expect(!wireText.contains("Production Host"))
        #expect(!wireText.contains("host.example.invalid"))
        #expect(!wireText.contains("synthetic-secret-command"))
        #expect(!wireText.contains("synthetic-secret-password"))
        #expect(envelope.envelopeVersion == 1)
        #expect(envelope.wrappedKey.iterations == 600_000)
        #expect(Data(selectiveRemoteBase64URL: envelope.contentHash)?.count == 32)
    }

    @Test("authenticated GET and PUT use the strict Personal Vault contract")
    func personalVaultTransport() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let vaultID = try #require(UUID(uuidString: "77777777-7777-4777-8777-777777777777"))
        let token = String(repeating: "t", count: 43)
        let tokenStore = SelectiveRemoteCloudMemoryTokenStore()
        try tokenStore.saveToken(token, for: endpoint)
        let stub = PersonalVaultHTTPStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/vault"):
                return Self.response(request, status: 200, json: [
                    "id": vaultID.canonicalCloudString,
                    "revision": 0,
                    "envelopeVersion": NSNull(),
                    "wrappedKey": NSNull(),
                    "ciphertext": NSNull(),
                    "nonce": NSNull(),
                    "authTag": NSNull(),
                    "contentHash": NSNull(),
                    "updatedAt": "2026-09-08T00:00:00.000Z"
                ])
            case ("PUT", "/v1/vault"):
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(Set(object.keys) == [
                    "baseRevision", "envelopeVersion", "wrappedKey", "ciphertext",
                    "nonce", "authTag", "contentHash"
                ])
                let wrappedKey = try #require(object["wrappedKey"] as? [String: Any])
                #expect(Set(wrappedKey.keys) == ["algorithm", "iterations", "salt", "value"])
                #expect(object["baseRevision"] as? Int == 0)
                return Self.response(request, status: 200, json: ["conflict": false, "revision": 1])
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return Self.response(request, status: 500, json: ["error": "unexpected_request"])
            }
        }
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: tokenStore,
            dataLoader: { request in try stub.data(for: request) }
        )

        let remote = try await client.personalVault(endpoint: endpoint)
        #expect(remote.id == vaultID)
        #expect(remote.revision == 0)
        #expect(remote.envelope == nil)

        let document = try SelectiveRemoteVaultDocument(records: [try syntheticRecord()])
        let envelope = try SelectiveRemotePersonalVaultCrypto.seal(
            document,
            recoveryPhrase: "correct horse battery staple",
            baseRevision: 0,
            vaultKey: Data(repeating: 0x11, count: 32),
            salt: Data(repeating: 0x22, count: 16),
            nonce: Data(repeating: 0x33, count: 12)
        )
        #expect(envelope.wrappedKey.value == "3MfifkLZxvfeMvM1VS7k5LH_yWgHYmMYUb56NqdNdXg38MMYxCUsIA")
        #expect(envelope.nonce == "MzMzMzMzMzMzMzMz")
        #expect(envelope.ciphertext == "_6EgI6n9B0jBmtE23AmHSXKpLQ7x-_HFjCZsp5ms2VO4UQ_1wpaCNzedjjmLM8O6fJKXcJEiEGh9_ieRYNDjfG4MGZ2XeedxmDStAy0iFPs2bqemOV0RrQ2CzfDG6zvEdwLP5kCQwzmHHXff5EaanuL2VmEe_HyBVlXy5TUX6er8mK5oqeugtjYUx_eFd4oC8g508mcybOGKDM9fUleqBWWGK9watV9fQQBHcCrRx0a3_39mhrztZPgdhYBd8cgNgVSQkbb-uKR-wdDDJmSiqICNqFD2QgNcRlwMAwcOS44AJ-6R3xNMdm9w")
        #expect(envelope.authTag == "1IYkH8A_1_UG7ELGr1DBqQ")
        #expect(envelope.contentHash == "H2eTTOL2LATd622JBSfi6-vwew2LdNCo8v1kSoVshyk")
        #expect(try await client.putPersonalVault(endpoint: endpoint, envelope: envelope)
            == .init(conflict: false, revision: 1))
    }

    @Test("extended wrapped-key responses are rejected")
    func rejectsExtendedWrappedKey() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let tokenStore = SelectiveRemoteCloudMemoryTokenStore()
        try tokenStore.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let document = try SelectiveRemoteVaultDocument(records: [try syntheticRecord()])
        let envelope = try SelectiveRemotePersonalVaultCrypto.seal(
            document,
            recoveryPhrase: "correct horse battery staple",
            baseRevision: 0,
            vaultKey: Data(repeating: 0x11, count: 32),
            salt: Data(repeating: 0x22, count: 16),
            nonce: Data(repeating: 0x33, count: 12)
        )
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: tokenStore,
            dataLoader: { request in
                Self.response(request, status: 200, json: [
                    "id": "77777777-7777-4777-8777-777777777777",
                    "revision": 1,
                    "envelopeVersion": 1,
                    "wrappedKey": [
                        "algorithm": envelope.wrappedKey.algorithm,
                        "iterations": envelope.wrappedKey.iterations,
                        "salt": envelope.wrappedKey.salt,
                        "value": envelope.wrappedKey.value,
                        "unexpected": true
                    ],
                    "ciphertext": envelope.ciphertext,
                    "nonce": envelope.nonce,
                    "authTag": envelope.authTag,
                    "contentHash": envelope.contentHash,
                    "updatedAt": "2026-09-08T00:00:00.000Z"
                ])
            }
        )

        await #expect(throws: SelectiveRemoteCloudError.invalidResponse) {
            try await client.personalVault(endpoint: endpoint)
        }
    }

    private static func syntheticRecord() throws -> SelectiveRemoteVaultRecord {
        try .init(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            type: .host,
            version: SelectiveRemoteVaultVersion([
                UUID(uuidString: "44444444-4444-4444-8444-444444444444")!: 1
            ]),
            modifiedAt: "2026-09-08T00:00:00.000Z",
            data: .object(["title": .string("Synthetic Host")])
        )
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        json: Any?
    ) throws -> (Data, URLResponse) {
        let data = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = try #require(HTTPURLResponse(
            url: try #require(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }
}

private final class PersonalVaultHTTPStub: @unchecked Sendable {
    let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
