// All HTTP is replaced by an in-memory dataLoader; all key/token stores are memory-only.
import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Personal Vault enrollment preserves existing ciphertext")
struct PersonalVaultEnrollmentSafetyTests {
    private static let oldPassword = "old synthetic password long enough"
    private static let newPassword = "new synthetic password long enough"
    private static let endpoint = URL(string: "https://password-reset-repro.example.invalid")!
    private static let accountID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
    private static let deviceID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    private static let vaultID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private static let remoteSnippetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let localSnippetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private static func snippet(id: UUID, title: String) -> TerminalCommandTemplate {
        TerminalCommandTemplate(
            id: id, profileID: deviceID, title: title, command: "echo synthetic",
            category: "Synthetic", targets: [.localTerminal],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func fixture(
        password: String,
        trustedKey: Bool = false,
        wrappingPassphrase: String? = nil,
        remoteEmpty: Bool = false
    ) async throws -> (
        enrollment: SelectiveRemotePersonalVaultAccountEnrollment,
        http: PasswordResetMemoryHTTP,
        keys: PasswordResetMemoryKeys,
        original: SelectiveRemoteVaultDocument,
        local: TerminalCommandTemplate
    ) {
        let original = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [], credentials: [],
            snippets: [snippet(id: remoteSnippetID, title: "Remote-only synthetic record")],
            forwarding: [], deviceID: deviceID
        ).document
        let setup = try SelectiveRemotePersonalVaultCrypto.createSetup(
            original,
            recoveryPhrase: wrappingPassphrase ?? SelectiveRemotePersonalVaultCrypto.accountPassphrase(oldPassword),
            baseRevision: 4
        )
        let initial = trustedKey ? try SelectiveRemotePersonalVaultKeyMaterial(
            vaultID: vaultID, vaultKey: setup.vaultKey, wrappedKey: setup.envelope.wrappedKey,
            revision: 5, documentHash: Data(SHA256.hash(data: try original.encoded()))
        ) : nil
        let keys = PasswordResetMemoryKeys(initial: initial)
        let http = PasswordResetMemoryHTTP(
            envelope: setup.envelope, vaultID: vaultID, accountID: accountID,
            deviceID: deviceID, acceptedPassword: password, revision: remoteEmpty ? 0 : 5
        )
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: SelectiveRemoteCloudMemoryTokenStore(),
            dataLoader: { request in try await http.data(for: request) },
            publicationStore: { throw PasswordResetReproError.forbiddenPersistentStore }
        )
        // Model a successful authentication after a server password reset. The server auth
        // transaction itself is separately covered by cloud/tests/service.test.mjs:416.
        let user = try await client.login(
            endpoint: endpoint, email: "synthetic@example.invalid", password: password,
            device: .init(id: deviceID, name: "Synthetic Mac", platform: "macos", appVersion: "0.32-test", publicKey: nil)
        )
        #expect(user.id == accountID)
        return (
            SelectiveRemotePersonalVaultAccountEnrollment(client: client, keyStore: keys),
            http, keys, original, snippet(id: localSnippetID, title: "Local-only synthetic record")
        )
    }

    @Test("A changed or wrong Vault password cannot replace ciphertext or saved keys", arguments: [false, true])
    func changedPasswordPreservesCurrentRemote(trustedKey: Bool) async throws {
        for hasLocalData in [false, true] {
            let f = try await Self.fixture(password: Self.newPassword, trustedKey: trustedKey)
            let priorMaterial = f.keys.savedMaterial
            var rejected = false
            do {
                _ = try await f.enrollment.enrollOrCreate(
                    endpoint: Self.endpoint, deviceID: Self.deviceID, password: Self.newPassword,
                    profiles: [], snippets: hasLocalData ? [f.local] : [], forwarding: []
                )
            } catch {
                rejected = true
            }
            #expect(rejected)
            let uploads = await f.http.uploadedEnvelopes()
            #expect(uploads.isEmpty)
            #expect(f.keys.savedMaterial == priorMaterial)
            #expect(f.keys.saveCount == 0)
            let paths = await f.http.requestPaths()
            #expect(paths == ["POST /v1/auth/login", "GET /v1/vault"])
        }
    }

    @Test("Unchanged password unlocks the remote Vault without replacement")
    func unchangedPasswordDoesNotReplace() async throws {
        let f = try await Self.fixture(password: Self.oldPassword)
        let revision = try await f.enrollment.enrollOrCreate(
            endpoint: Self.endpoint, deviceID: Self.deviceID, password: Self.oldPassword,
            profiles: [], snippets: [f.local], forwarding: []
        )
        let uploads = await f.http.uploadedEnvelopes()
        #expect(revision == 5)
        #expect(uploads.isEmpty)
        #expect(f.keys.savedMaterial?.requiresInitialDownload == true)
    }

    @Test("Ambiguous legacy-wrapper auto-migration is suspended instead of replacing remote data")
    func legacyWrapperDoesNotAuthorizeReplacement() async throws {
        let f = try await Self.fixture(
            password: Self.oldPassword,
            wrappingPassphrase: "synthetic legacy recovery phrase"
        )
        var rejected = false
        do {
            _ = try await f.enrollment.enrollOrCreate(
                endpoint: Self.endpoint, deviceID: Self.deviceID, password: Self.oldPassword,
                profiles: [], snippets: [f.local], forwarding: []
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        let uploads = await f.http.uploadedEnvelopes()
        #expect(uploads.isEmpty)
        #expect(f.keys.saveCount == 0)
    }

    @Test("First enrollment still uploads local data to an empty remote Vault")
    func emptyRemoteEnrollment() async throws {
        let f = try await Self.fixture(password: Self.newPassword, remoteEmpty: true)
        let revision = try await f.enrollment.enrollOrCreate(
            endpoint: Self.endpoint, deviceID: Self.deviceID, password: Self.newPassword,
            profiles: [], snippets: [f.local], forwarding: []
        )
        let uploads = await f.http.uploadedEnvelopes()
        #expect(revision == 1)
        #expect(uploads.count == 1)
        let uploaded = try #require(uploads.first)
        #expect(uploaded.baseRevision == 0)
        let key = try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(
            uploaded.wrappedKey,
            passphrase: SelectiveRemotePersonalVaultCrypto.accountPassphrase(Self.newPassword)
        )
        let document = try SelectiveRemotePersonalVaultCrypto.open(uploaded, vaultKey: key)
        #expect(document.records.contains { $0.id == Self.localSnippetID })
        #expect(f.keys.savedMaterial?.vaultKey == key)
    }
}

private enum PasswordResetReproError: Error {
    case forbiddenPersistentStore, unexpectedRequest, invalidSyntheticLogin
}

private final class PasswordResetMemoryKeys: SelectiveRemotePersonalVaultKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SelectiveRemotePersonalVaultKeyMaterial?
    private var reads = 0
    private var saves = 0
    init(initial: SelectiveRemotePersonalVaultKeyMaterial?) { value = initial }
    var savedMaterial: SelectiveRemotePersonalVaultKeyMaterial? { lock.withLock { value } }
    var materialReadCount: Int { lock.withLock { reads } }
    var saveCount: Int { lock.withLock { saves } }
    func material(endpoint: URL, deviceID: UUID) throws -> SelectiveRemotePersonalVaultKeyMaterial? {
        lock.withLock { reads += 1; return value }
    }
    func save(_ material: SelectiveRemotePersonalVaultKeyMaterial, endpoint: URL, deviceID: UUID) throws {
        lock.withLock { value = material; saves += 1 }
    }
    func remove(endpoint: URL, deviceID: UUID) throws { lock.withLock { value = nil } }
}

private actor PasswordResetMemoryHTTP {
    private let envelope: SelectiveRemotePersonalVaultEnvelope
    private let vaultID: UUID
    private let accountID: UUID
    private let deviceID: UUID
    private let acceptedPassword: String
    private let revision: Int
    private var uploads: [SelectiveRemotePersonalVaultEnvelope] = []
    private var paths: [String] = []
    private let token = String(repeating: "s", count: 43)

    init(envelope: SelectiveRemotePersonalVaultEnvelope, vaultID: UUID, accountID: UUID, deviceID: UUID, acceptedPassword: String, revision: Int) {
        self.envelope = envelope
        self.vaultID = vaultID
        self.accountID = accountID
        self.deviceID = deviceID
        self.acceptedPassword = acceptedPassword
        self.revision = revision
    }
    func uploadedEnvelopes() -> [SelectiveRemotePersonalVaultEnvelope] { uploads }
    func requestPaths() -> [String] { paths }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        guard request.url?.host == "password-reset-repro.example.invalid" else {
            throw PasswordResetReproError.unexpectedRequest
        }
        paths.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/v1/auth/login"):
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
            guard body?["password"] as? String == acceptedPassword else {
                throw PasswordResetReproError.invalidSyntheticLogin
            }
            return try response(request, json: [
                "token": token,
                "user": ["id": accountID.uuidString.lowercased(), "email": "synthetic@example.invalid", "username": "synthetic", "displayName": "Synthetic", "createdAt": "2026-10-09T00:00:00.000Z"],
                "deviceID": deviceID.uuidString.lowercased()
            ])
        case ("GET", "/v1/vault"):
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
            body.removeValue(forKey: "baseRevision")
            if revision == 0 {
                for field in ["wrappedKey", "ciphertext", "nonce", "authTag", "contentHash"] {
                    body[field] = NSNull()
                }
            }
            body["id"] = vaultID.uuidString.lowercased()
            body["revision"] = revision
            body["updatedAt"] = "2026-10-09T00:00:00.000Z"
            return try response(request, json: body)
        case ("PUT", "/v1/vault"):
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            let value = try JSONDecoder().decode(SelectiveRemotePersonalVaultEnvelope.self, from: #require(request.httpBody))
            uploads.append(value)
            return try response(request, json: ["conflict": false, "revision": revision + 1])
        default:
            throw PasswordResetReproError.unexpectedRequest
        }
    }
    private func response(_ request: URLRequest, json: [String: Any]) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (try JSONSerialization.data(withJSONObject: json), response)
    }
}
