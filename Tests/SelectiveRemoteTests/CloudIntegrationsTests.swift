import Foundation
import Testing
@testable import SelectiveRemote

private struct CloudStubTransport: CloudHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> CloudHTTPResponse

    func data(for request: URLRequest) async throws -> CloudHTTPResponse {
        try handler(request)
    }
}

@Test("Cloud account metadata persists without provider secrets")
func cloudAccountCodableContainsNoSecrets() throws {
    var account = CloudAccount(provider: .aws)
    account.name = "Production AWS"
    account.region = "eu-central-1"
    let data = try JSONEncoder().encode(account)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.localizedCaseInsensitiveContains("secretAccessKey"))
    #expect(!text.localizedCaseInsensitiveContains("apiToken"))
    #expect(try JSONDecoder().decode(CloudAccount.self, from: data) == account)
}

@Test("Cloud-linked SSH profiles remain backward compatible")
func cloudProfileMetadataCodable() throws {
    let accountID = UUID()
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.cloudProvider = .digitalOcean
    profile.cloudAccountID = accountID
    profile.cloudResourceID = "12345"
    profile.cloudRegion = "fra1"
    profile.cloudNetworkName = "production-vpc"
    profile.cloudLastKnownState = .stopped
    profile.cloudTags = ["environment": "production"]

    let restored = try JSONDecoder().decode(
        ConnectionProfile.self,
        from: JSONEncoder().encode(profile)
    )
    #expect(restored.cloudProvider == .digitalOcean)
    #expect(restored.cloudAccountID == accountID)
    #expect(restored.cloudResourceID == "12345")
    #expect(restored.cloudLastKnownState == .stopped)

    var legacy = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
    )
    for key in [
        "cloudProvider", "cloudAccountID", "cloudResourceID", "cloudRegion",
        "cloudNetworkName", "cloudLastKnownState", "cloudTags"
    ] {
        legacy.removeValue(forKey: key)
    }
    let migrated = try JSONDecoder().decode(
        ConnectionProfile.self,
        from: JSONSerialization.data(withJSONObject: legacy)
    )
    #expect(migrated.cloudProvider == nil)
    #expect(migrated.cloudResourceID.isEmpty)
    #expect(migrated.cloudTags.isEmpty)
}

@Test("DigitalOcean inventory maps running and powered-off droplets")
func digitalOceanInventoryParsing() async throws {
    var account = CloudAccount(provider: .digitalOcean)
    account.name = "DO"
    let secret = CloudAccountSecret(apiToken: "test-token")
    let response = #"""
    {
      "droplets": [
        {
          "id": 42,
          "name": "web-1",
          "status": "active",
          "region": { "slug": "fra1" },
          "image": { "distribution": "Ubuntu", "name": "24.04" },
          "tags": ["production", "web"],
          "vpc_uuid": "vpc-1",
          "networks": { "v4": [
            { "ip_address": "203.0.113.10", "type": "public" },
            { "ip_address": "10.0.0.10", "type": "private" }
          ] }
        },
        {
          "id": 43,
          "name": "worker-1",
          "status": "off",
          "region": { "slug": "fra1" },
          "image": { "distribution": "Debian", "name": "13" },
          "tags": [],
          "vpc_uuid": "vpc-1",
          "networks": { "v4": [] }
        }
      ]
    }
    """#
    let transport = CloudStubTransport { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        return CloudHTTPResponse(
            data: Data(response.utf8),
            statusCode: 200
        )
    }

    let instances = try await CloudInventoryService.fetchInstances(
        account: account,
        secret: secret,
        transport: transport
    )
    #expect(instances.count == 2)
    #expect(instances[0].state == .running)
    #expect(instances[0].preferredAddress == "203.0.113.10")
    #expect(instances[0].networkName == "vpc-1")
    #expect(instances[1].state == .stopped)
}

@Test("DigitalOcean Project ID limits inventory to project droplets")
func digitalOceanProjectFiltering() async throws {
    var account = CloudAccount(provider: .digitalOcean)
    account.projectID = "project-1"
    let secret = CloudAccountSecret(apiToken: "test-token")
    let droplets = #"{"droplets":[{"id":42,"name":"included","status":"active","region":{"slug":"fra1"},"image":{"distribution":"Ubuntu","name":"24.04"},"tags":[],"vpc_uuid":null,"networks":{"v4":[]}},{"id":43,"name":"excluded","status":"active","region":{"slug":"fra1"},"image":{"distribution":"Ubuntu","name":"24.04"},"tags":[],"vpc_uuid":null,"networks":{"v4":[]}}]}"#
    let resources = #"{"resources":[{"urn":"do:droplet:42"},{"urn":"do:volume:99"}]}"#
    let transport = CloudStubTransport { request in
        let body = request.url?.path.contains("/projects/project-1/resources") == true
            ? resources
            : droplets
        return CloudHTTPResponse(
            data: Data(body.utf8),
            statusCode: 200
        )
    }

    let instances = try await CloudInventoryService.fetchInstances(
        account: account,
        secret: secret,
        transport: transport
    )
    #expect(instances.map(\.resourceID) == ["42"])
}

@Test("AWS Signature V4 is deterministic and never exposes the secret key")
func awsSignatureV4() throws {
    var request = URLRequest(url: URL(string: "https://ec2.us-east-1.amazonaws.com/")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    let body = Data("Action=DescribeInstances&Version=2016-11-15".utf8)
    AWSSignatureV4.sign(
        request: &request,
        body: body,
        region: "us-east-1",
        service: "ec2",
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "example-secret-value",
        sessionToken: "",
        date: Date(timeIntervalSince1970: 1_440_938_160)
    )
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"))
    #expect(authorization.contains("SignedHeaders=content-type;host;x-amz-date"))
    #expect(!authorization.contains("example-secret-value"))
}

@Test("Cloud inventory is wired into the sidebar and regular SSH profiles")
func cloudIntegrationSourceWiring() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let content = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    let appModel = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/AppModel.swift"),
        encoding: .utf8
    )
    let keychain = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/KeychainService.swift"),
        encoding: .utf8
    )
    #expect(content.contains("case cloud = \"Cloud\""))
    #expect(content.contains("CloudIntegrationsView("))
    #expect(appModel.contains("func importCloudInstance("))
    #expect(appModel.contains("User-edited SSH settings"))
    #expect(keychain.contains("cloudCredentialReference(accountID:"))
    #expect(keychain.contains("local.selectiveremote.cloud-credentials.v1"))
}
