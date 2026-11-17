import Foundation
import Testing
@testable import SelectiveRemote

@Suite("V1 writer compatibility fence")
struct CloudV1WriteFenceTests {
    @Test("Personal upload reports the temporary write stop without exposing other errors")
    func reportsTemporaryWriteStop() async throws {
        let endpoint = URL(string: "https://fence-\(UUID()).example.invalid")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            if request.url?.path == "/v1/meta" {
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["X-Selective-V1-Write-Fence": "1"])!)
            }
            return (Data("{\"error\":\"vault_write_temporarily_unavailable\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        let session = try await client.sessionBinding(endpoint: endpoint)
        let wrapped = try SelectiveRemotePersonalVaultWrappedKey(salt: Data(repeating: 1, count: 16), value: Data(repeating: 2, count: 40))
        let envelope = try SelectiveRemotePersonalVaultEnvelope(baseRevision: 1, wrappedKey: wrapped, ciphertext: Data([1]), nonce: Data(repeating: 3, count: 12), authTag: Data(repeating: 4, count: 16))
        do {
            _ = try await client.putPersonalVault(endpoint: endpoint, envelope: envelope, session: session)
            Issue.record("The server's write stop must be surfaced")
        } catch {
            #expect(error as? SelectiveRemoteCloudError == .serviceError(503, "vault_write_temporarily_unavailable"))
            let copy = error.localizedDescription
            #expect(copy.contains("локальн") || copy.contains("local cop"))
            #expect(SelectiveRemoteCloudError.serviceError(400, "vault_write_temporarily_unavailable").localizedDescription != copy)
            #expect(SelectiveRemoteCloudError.serviceError(503, "unrelated_internal_error").localizedDescription != copy)
        }
    }

    @Test("Team upload reports the temporary write stop")
    func reportsTemporaryTeamWriteStop() async throws {
        let endpoint = URL(string: "https://fence-\(UUID()).example.invalid")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            if request.url?.path == "/v1/meta" {
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["X-Selective-V1-Write-Fence": "1"])!)
            }
            return (Data("{\"error\":\"vault_write_temporarily_unavailable\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        let teamID = UUID(), vaultID = UUID()
        let envelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            Data("synthetic".utf8), vaultKey: Data(repeating: 4, count: 32),
            teamID: teamID, vaultID: vaultID, keyGeneration: 1, baseRevision: 1
        )
        do {
            _ = try await client.putSharedVault(endpoint: endpoint, teamID: teamID, vaultID: vaultID,
                upload: .init(envelope: envelope, wrappers: nil), idempotencyKey: "synthetic-stop-test")
            Issue.record("The server's Team write stop must be surfaced")
        } catch {
            #expect(error as? SelectiveRemoteCloudError == .serviceError(503, "vault_write_temporarily_unavailable"))
            let copy = error.localizedDescription
            #expect(copy.contains("локальн") || copy.contains("local cop"))
        }
    }

    @Test("Personal upload does not reach a Cloud without the writer capability")
    func rejectsLegacyServer() async throws {
        let endpoint = URL(string: "https://fence-\(UUID()).example.invalid")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let calls = CloudV1FenceCalls()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            if request.url?.path == "/v1/vault" { await calls.record(request) }
            let data = Data((request.url?.path == "/v1/meta" ? "{}" : "{\"conflict\":false,\"revision\":1}").utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let session = try await client.sessionBinding(endpoint: endpoint)
        let wrapped = try SelectiveRemotePersonalVaultWrappedKey(salt: Data(repeating: 1, count: 16), value: Data(repeating: 2, count: 40))
        let envelope = try SelectiveRemotePersonalVaultEnvelope(baseRevision: 0, wrappedKey: wrapped, ciphertext: Data([1]), nonce: Data(repeating: 3, count: 12), authTag: Data(repeating: 4, count: 16))
        var rejected = false
        do { _ = try await client.putPersonalVault(endpoint: endpoint, envelope: envelope, session: session) } catch { rejected = true }
        #expect(rejected)
        #expect(await calls.count == 0)
    }

    @Test("Personal upload uses the framed protocol advertised by Cloud")
    func sendsFramedWrite() async throws {
        let endpoint = URL(string: "https://fence-\(UUID()).example.invalid")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let calls = CloudV1FenceCalls()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            if request.url?.path == "/v1/meta" {
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["X-Selective-V1-Write-Fence": "1"])!)
            }
            await calls.record(request)
            return (Data("{\"conflict\":false,\"revision\":1}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let session = try await client.sessionBinding(endpoint: endpoint)
        let wrapped = try SelectiveRemotePersonalVaultWrappedKey(salt: Data(repeating: 1, count: 16), value: Data(repeating: 2, count: 40))
        let envelope = try SelectiveRemotePersonalVaultEnvelope(baseRevision: 0, wrappedKey: wrapped, ciphertext: Data([1]), nonce: Data(repeating: 3, count: 12), authTag: Data(repeating: 4, count: 16))
        _ = try await client.putPersonalVault(endpoint: endpoint, envelope: envelope, session: session)
        let request = try #require(await calls.last)
        #expect(request.value(forHTTPHeaderField: "X-Selective-V1-Write-Fence") == "1")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["protocol"] as? String == "framed-v1")
        #expect((object["envelope"] as? [String: Any])?["baseRevision"] as? Int == 0)
    }

    @Test("A session change during writer negotiation blocks the pending upload")
    func changedSessionBlocksUpload() async throws {
        let endpoint = URL(string: "https://fence-\(UUID()).example.invalid")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let calls = CloudV1FenceCalls(), barrier = CloudV1FenceBarrier()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            if request.url?.path == "/v1/meta" {
                await barrier.pause()
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["X-Selective-V1-Write-Fence": "1"])!)
            }
            await calls.record(request)
            return (Data("{\"conflict\":false,\"revision\":1}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let session = try await client.sessionBinding(endpoint: endpoint)
        let wrapped = try SelectiveRemotePersonalVaultWrappedKey(salt: Data(repeating: 1, count: 16), value: Data(repeating: 2, count: 40))
        let envelope = try SelectiveRemotePersonalVaultEnvelope(baseRevision: 0, wrappedKey: wrapped, ciphertext: Data([1]), nonce: Data(repeating: 3, count: 12), authTag: Data(repeating: 4, count: 16))
        let pending = Task { try await client.putPersonalVault(endpoint: endpoint, envelope: envelope, session: session) }
        await barrier.waitUntilStarted()
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: endpoint)
        tokens.saveToken(String(repeating: "n", count: 43), for: endpoint)
        await barrier.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await calls.count == 0)
    }
}

private actor CloudV1FenceCalls {
    private var requests: [URLRequest] = []
    var count: Int { requests.count }
    var last: URLRequest? { requests.last }
    func record(_ request: URLRequest) { requests.append(request) }
}

private actor CloudV1FenceBarrier {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
