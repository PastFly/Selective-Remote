import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Selective Remote Cloud foundation")
struct CloudFoundationTests {
    @Test("Production endpoint is normalized without a trailing slash")
    func normalizesEndpoint() throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("  https://cloud.pastfly.ru///  ")
        #expect(endpoint.absoluteString == "https://cloud.pastfly.ru")
    }

    @Test("Plain HTTP is rejected outside local development")
    func rejectsInsecureEndpoint() {
        #expect(throws: SelectiveRemoteCloudError.insecureEndpoint) {
            try SelectiveRemoteCloudEndpoint.normalized("http://cloud.pastfly.ru")
        }
        #expect(throws: Never.self) {
            try SelectiveRemoteCloudEndpoint.normalized("http://localhost:8080")
        }
    }

    @Test("Credentials cannot be embedded in an endpoint")
    func rejectsEmbeddedCredentials() {
        #expect(throws: SelectiveRemoteCloudError.invalidEndpoint) {
            try SelectiveRemoteCloudEndpoint.normalized("https://user:password@cloud.pastfly.ru")
        }
    }

    @Test("Endpoints cannot smuggle an API path")
    func rejectsEndpointPath() {
        #expect(throws: SelectiveRemoteCloudError.invalidEndpoint) {
            try SelectiveRemoteCloudEndpoint.normalized("https://cloud.pastfly.ru/untrusted")
        }
    }

    @Test("Browser sign-in uses the configured host and port")
    func browserSignInUsesConfiguredEndpoint() {
        let production = SelectiveRemoteCloudPortalURL.login(endpoint: SelectiveRemoteCloudEndpoint.production)
        #expect(production?.absoluteString == "https://cloud.pastfly.ru/?auth=login")

        let staging = SelectiveRemoteCloudPortalURL.login(endpoint: " https://staging.example.test:8443/ ")
        #expect(staging?.absoluteString == "https://staging.example.test:8443/?auth=login")

        let development = SelectiveRemoteCloudPortalURL.login(endpoint: "http://localhost:8080")
        #expect(development?.absoluteString == "http://localhost:8080/?auth=login")
    }

    @Test("Browser sign-in rejects an invalid endpoint without falling back to production", arguments: [
        "",
        "http://staging.example.test:8443",
        "https://staging.example.test:8443/?auth=registration",
        "https://user:password@staging.example.test:8443",
    ])
    func browserSignInRejectsInvalidEndpoint(_ endpoint: String) {
        #expect(SelectiveRemoteCloudPortalURL.login(endpoint: endpoint) == nil)
    }

    @Test("Cloud metadata matches API v1 contract")
    func decodesMetadata() throws {
        let data = Data(#"{"apiVersion":1,"vaultSchemaVersion":1,"registrationEnabled":false}"#.utf8)
        let metadata = try JSONDecoder().decode(SelectiveRemoteCloudMetadata.self, from: data)
        #expect(metadata == SelectiveRemoteCloudMetadata(
            apiVersion: 1,
            vaultSchemaVersion: 1,
            registrationEnabled: false
        ))
    }
}
