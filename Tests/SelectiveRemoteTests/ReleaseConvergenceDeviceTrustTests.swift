import Foundation
import Testing
@testable import SelectiveRemote

struct ReleaseConvergenceDeviceTrustTests {
    @Test func oldBackendReportsUnsupportedTrustCapability() async throws {
        let endpoint = URL(string: "https://release.invalid")!
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(String(repeating: "s", count: 32), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            (Data("{\"error\":\"not_found\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await client.deviceTrustSnapshot(endpoint: endpoint)
            Issue.record("Old backend must not appear to support device approval")
        } catch {
            #expect(error as? SelectiveRemoteCloudError == .serviceError(404, "device_trust_unsupported"))
        }
        do {
            _ = try await client.deviceTrustRequests(endpoint: endpoint)
            Issue.record("Missing trust request collection must not appear empty")
        } catch {
            #expect(error as? SelectiveRemoteCloudError == .serviceError(404, "device_trust_unsupported"))
        }
        #expect(store.token(for: endpoint) == String(repeating: "s", count: 32))
    }
    @Test func unknownErrorsAndStatusesDoNotExposeServerContent() {
        for english in [false, true] {
            let secret = "internal_identifier_secret"
            let copy = CloudDeviceTrustPresentation.failure(
                SelectiveRemoteCloudError.serviceError(500, secret), english: english)
            #expect(!copy.contains(secret))
            #expect(!copy.contains("500"))
            #expect(!CloudDeviceTrustPresentation.requestStatus(secret, english: english).contains(secret))
            #expect(CloudDeviceTrustPresentation.failure(
                SelectiveRemoteDeviceTrustError.invalidSignature, english: english)
                .contains(english ? "Stop" : "Не продолжайте"))
        }
    }
}
