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
