import Foundation
import Testing
@testable import SelectiveRemote

@Suite("native publication reader transport")
struct CloudVaultPublicationTransportTests {
    @Test("all publication reads carry exact reader capabilities and retain bearer authorization")
    func capabilities() async throws {
        let endpoint = URL(string: "https://reader-transport.example.test")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore(), token = String(repeating: "t", count: 43)
        tokens.saveToken(token, for: endpoint)
        let scope = SelectiveRemotePublicationScope(endpoint: endpoint, accountID: UUID(), deviceID: UUID(), teamID: UUID(), vaultID: UUID())
        let expectedAuthorization = "Bearer \(token)"
        let prefix = "/v1/teams/\(scope.teamID.canonicalCloudString)/vaults/\(scope.vaultID.canonicalCloudString)/publication/"
        for route in ["header", "publisher", "directory", "resources/\(UUID().canonicalCloudString)/parts/SECRET"] {
            let expectedPath = prefix + route
            let dataLoader: SelectiveRemoteCloudDataLoader = { request in
                #expect(request.value(forHTTPHeaderField: "X-Vault-Schema-Version") == "2")
                #expect(request.value(forHTTPHeaderField: "X-Vault-Capability") == "resource_acl_v2")
                #expect(request.value(forHTTPHeaderField: "X-Publication-Version") == "1")
                #expect(request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization)
                #expect(request.httpMethod == "GET")
                #expect(request.url?.path == expectedPath)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("null".utf8), response)
            }
            let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: dataLoader)
            #expect(try await client.publicationRead(scope: scope, route: route) == .null)
        }
    }
}
