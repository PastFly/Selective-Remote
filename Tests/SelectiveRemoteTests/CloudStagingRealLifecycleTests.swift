import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("isolated staging real lifecycle probe boundaries")
struct CloudStagingRealLifecycleTests {
    @Test("real HTTPS reader and durable restart — NOT RUN without protected opt-in; API probe is not GUI acceptance",
          .enabled(if: ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_STAGING_REAL_CONFIG"] != nil))
    func realHTTPS() async throws {
        do {
            guard let (config, directory) = try StagingRealProbeConfig.load(path: ProcessInfo.processInfo.environment["SELECTIVE_REMOTE_STAGING_REAL_CONFIG"])
            else { throw StagingRealProbeError.configuration }
            let result = try await StagingRealProbe.run(config, directory: directory)
            let bytes = try JSONEncoder().encode(result)
            print("STAGING_REAL_PROBE_RESULT " + String(decoding: bytes, as: UTF8.self))
        } catch { throw StagingRealProbeError.acceptance }
    }
    @Test("absent opt-in does not load any file or secret store")
    func absent() throws { #expect(try StagingRealProbeConfig.load(path: nil) == nil) }

    @Test("config accepts only explicitly scoped new test identity", arguments: ["endpoint", "runID", "testIdentityCreatedForRun", "teamName", "vaultName", "privateKey", "ownPin", "publisherPin", "headerHash", "sequence", "counts", "duplicateSecret", "overlapSecret", "unknownField"])
    func invalidScope(_ field: String) throws {
        var object = fixture()
        switch field {
        case "endpoint": object[field] = "https://other.invalid"
        case "runID": object[field] = "ordinary-profile"
        case "testIdentityCreatedForRun": object[field] = "TEST-ONLY-CODEX-other"
        case "teamName", "vaultName": object[field] = "ordinary Vault"
        case "privateKey": object["devicePrivateKey"] = Data(repeating: 0, count: 31).base64EncodedString()
        case "ownPin": var pin = object[field] as! [String: Any]; pin["accountID"] = UUID().uuidString; object[field] = pin
        case "publisherPin": var pin = object[field] as! [String: Any]; pin["rootFingerprint"] = "unknown"; object[field] = pin
        case "headerHash": object[field] = "unknown"
        case "sequence": object[field] = 0
        case "counts": object[field] = ["hosts": -1, "snippets": 0, "credentials": 0, "forwardings": 0, "folders": 0]
        case "duplicateSecret": let secret = ["resourceID": UUID().uuidString, "sha256": String(repeating: "b", count: 64)]; object["secrets"] = [secret, secret]
        case "overlapSecret": let id = UUID().uuidString; object["secrets"] = [["resourceID": id, "sha256": String(repeating: "b", count: 64)]]; object["deniedSecrets"] = [id]
        default: object["unreviewedOverride"] = true
        }
        let (file, root) = try write(object); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Error.self) { try StagingRealProbeConfig.load(path: file.path) }
    }

    @Test("private regular config and dedicated directory required", arguments: ["fileMode", "directoryMode", "symlink", "relative", "oversize"])
    func invalidFile(_ fault: String) throws {
        let (file, root) = try write(fixture()); defer { try? FileManager.default.removeItem(at: root) }
        var path = file.path
        switch fault {
        case "fileMode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        case "directoryMode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.deletingLastPathComponent().path)
        case "symlink": let link = file.deletingLastPathComponent().appending(path: "link.json"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file); path = link.path
        case "relative": path = file.deletingLastPathComponent().appending(path: "../" + file.deletingLastPathComponent().lastPathComponent + "/config.json").path
        default: try Data(repeating: 32, count: 70_000).write(to: file)
        }
        let testedPath = path
        #expect(throws: Error.self) { try StagingRealProbeConfig.load(path: testedPath) }
    }

    @Test("valid config remains bounded and returns dedicated run directory")
    func validConfig() throws {
        let (file, root) = try write(fixture()); defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try StagingRealProbeConfig.load(path: file.path)
        let (config, directory) = try #require(loaded)
        #expect(config.runID == directory.lastPathComponent)
        #expect(config.accountID == config.ownPin.accountID)
        #expect(config.service == "org.pastfly.SelectiveRemote.StagingReal." + config.runID)
    }

    @Test("isolated pin CAS preserves newer history and rejects fork, root swap, corruption and failed persistence")
    func pinHistory() throws {
        let storage = PublicationProtectedMemory(), pins = StagingRealPinStore(storage: storage), account = UUID()
        let first = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: String(repeating: "a", count: 64), highWater: 1, checkpointDigest: "first")
        let next = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: first.rootFingerprint, highWater: 2, checkpointDigest: "second")
        try pins.seed(first); try pins.advance(expected: first, next: next); try pins.seed(first)
        #expect(try pins.read() == next)
        #expect(throws: Error.self) { try pins.advance(expected: first, next: next) }
        #expect(throws: Error.self) { try pins.advance(expected: next, next: first) }
        let fork = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: first.rootFingerprint, highWater: 2, checkpointDigest: "fork")
        #expect(throws: Error.self) { try pins.seed(fork) }
        let wrongRoot = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: String(repeating: "b", count: 64), highWater: 3, checkpointDigest: "other")
        #expect(throws: Error.self) { try pins.seed(wrongRoot) }
        storage.failOnce("own-pin")
        let third = SelectiveRemoteDeviceTrustPin(accountID: account, rootFingerprint: first.rootFingerprint, highWater: 3, checkpointDigest: "third")
        #expect(throws: Error.self) { try pins.advance(expected: next, next: third) }
        #expect(try pins.read() == next)
        try storage.save(Data("corrupt".utf8), key: "own-pin")
        #expect(throws: Error.self) { try pins.seed(first) }
    }

    @Test("explicit in-memory session prevents production retirement fallback from opening default preferences or stores")
    func isolatedSession() async throws {
        let endpoint = URL(string: "https://native-unit-\(UUID().uuidString.lowercased()).example.test")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "t", count: 64)
        tokens.saveToken(token, for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), token: token, tokenStore: tokens, checkConfiguration: false)
        // No HTTPS call. A store fallback would fail this test instead of opening a default store.
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, publicationStore: { throw StagingRealProbeError.protection })
        try await client.installStagingProbeSession(session)
        let restored = try await client.publicationRetirementSession(endpoint: endpoint, token: token)
        #expect(restored === session)
    }

    private func fixture() -> [String: Any] {
        let account = UUID().uuidString, run = "TEST-ONLY-CODEX-native-unit"
        let pin: [String: Any] = ["accountID": account, "rootFingerprint": String(repeating: "a", count: 64), "highWater": 1, "checkpointDigest": Data(repeating: 1, count: 32).selectiveRemoteBase64URL]
        return ["formatVersion": 1, "runID": run, "testIdentityCreatedForRun": run, "endpoint": "https://cloud.pastfly.ru", "accountID": account, "deviceID": UUID().uuidString, "teamID": UUID().uuidString, "vaultID": UUID().uuidString, "teamName": run + "-team", "vaultName": run + "-vault", "sessionToken": String(repeating: "t", count: 64), "devicePrivateKey": P256.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString(), "ownPin": pin, "publisherPin": pin, "generationID": UUID().uuidString, "sequence": 1, "headerHash": String(repeating: "b", count: 64), "counts": ["hosts": 0, "snippets": 0, "credentials": 0, "forwardings": 0, "folders": 0], "secrets": [], "deniedSecrets": [], "requireOldClientDenial": true]
    }
    private func write(_ object: [String: Any]) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        let directory = root.appending(path: "TEST-ONLY-CODEX-native-unit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appending(path: "config.json")
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return (path, root)
    }
}
