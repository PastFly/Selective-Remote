import Combine
import CryptoKit
import Foundation
import FoundationXML

enum CloudProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case aws
    case azure
    case digitalOcean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aws: "AWS"
        case .azure: "Microsoft Azure"
        case .digitalOcean: "DigitalOcean"
        }
    }

    var systemImage: String {
        switch self {
        case .aws: "shippingbox.fill"
        case .azure: "square.stack.3d.up.fill"
        case .digitalOcean: "drop.fill"
        }
    }

    var tintHex: String {
        switch self {
        case .aws: "#FF9900"
        case .azure: "#168DDD"
        case .digitalOcean: "#0080FF"
        }
    }
}

enum CloudGroupingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case region
    case network
    case firstTag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .region:
            UpdateLocalization.text(ru: "Регион", en: "Region")
        case .network:
            UpdateLocalization.text(ru: "VPC / сеть", en: "VPC / Network")
        case .firstTag:
            UpdateLocalization.text(ru: "Первый тег", en: "First Tag")
        }
    }
}

struct CloudAccount: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var provider: CloudProvider
    var name: String
    var region: String
    var tenantID: String
    var clientID: String
    var subscriptionID: String
    var projectID: String
    var defaultUsername: String
    var groupingMode: CloudGroupingMode
    var createdAt = Date()
    var lastRefreshedAt: Date?

    init(provider: CloudProvider) {
        self.provider = provider
        name = provider.title
        switch provider {
        case .aws:
            region = "eu-central-1"
            defaultUsername = "ec2-user"
        case .azure:
            region = ""
            defaultUsername = "azureuser"
        case .digitalOcean:
            region = ""
            defaultUsername = "root"
        }
        tenantID = ""
        clientID = ""
        subscriptionID = ""
        projectID = ""
        groupingMode = .region
    }
}

struct CloudAccountSecret: Codable, Equatable, Sendable {
    var accessKeyID = ""
    var secretAccessKey = ""
    var sessionToken = ""
    var clientSecret = ""
    var apiToken = ""

    var isEmpty: Bool {
        accessKeyID.isEmpty
            && secretAccessKey.isEmpty
            && sessionToken.isEmpty
            && clientSecret.isEmpty
            && apiToken.isEmpty
    }

    func isValid(for provider: CloudProvider) -> Bool {
        switch provider {
        case .aws:
            !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !secretAccessKey.isEmpty
        case .azure:
            !clientSecret.isEmpty
        case .digitalOcean:
            !apiToken.isEmpty
        }
    }
}

enum CloudInstanceState: String, Codable, CaseIterable, Sendable {
    case running
    case stopped
    case pending
    case stopping
    case terminated
    case unknown

    init(providerValue: String) {
        switch providerValue.lowercased() {
        case "running", "active", "powerstate/running": self = .running
        case "stopped", "deallocated", "off", "powerstate/deallocated", "powerstate/stopped": self = .stopped
        case "pending", "new", "starting", "powerstate/starting": self = .pending
        case "stopping", "powerstate/stopping", "powerstate/deallocating": self = .stopping
        case "terminated", "deleted": self = .terminated
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .running: UpdateLocalization.text(ru: "Работает", en: "Running")
        case .stopped: UpdateLocalization.text(ru: "Выключена", en: "Stopped")
        case .pending: UpdateLocalization.text(ru: "Запускается", en: "Starting")
        case .stopping: UpdateLocalization.text(ru: "Останавливается", en: "Stopping")
        case .terminated: UpdateLocalization.text(ru: "Удалена", en: "Terminated")
        case .unknown: UpdateLocalization.text(ru: "Неизвестно", en: "Unknown")
        }
    }

    var canConnect: Bool { self == .running }
}

struct CloudInstance: Codable, Equatable, Identifiable, Sendable {
    var id: String { resourceID }
    let resourceID: String
    let provider: CloudProvider
    let name: String
    let state: CloudInstanceState
    let region: String
    let availabilityZone: String
    let networkName: String
    let publicIPAddress: String
    let privateIPAddress: String
    let tags: [String: String]
    let operatingSystem: String

    var preferredAddress: String {
        let publicValue = publicIPAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return publicValue.isEmpty ? privateIPAddress : publicValue
    }

    var sortedTags: [String] {
        tags.sorted { lhs, rhs in
            lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }.map { key, value in
            value.isEmpty ? key : "\(key)=\(value)"
        }
    }
}

enum CloudIntegrationError: LocalizedError, Equatable {
    case missingCredentials
    case invalidAccount(String)
    case invalidResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            UpdateLocalization.text(
                ru: "Сохраните учётные данные облачного аккаунта в Keychain.",
                en: "Save the cloud account credentials in Keychain."
            )
        case let .invalidAccount(message), let .provider(message):
            message
        case .invalidResponse:
            UpdateLocalization.text(
                ru: "Облачный провайдер вернул некорректный ответ.",
                en: "The cloud provider returned an invalid response."
            )
        }
    }
}

struct CloudHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol CloudHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> CloudHTTPResponse
}

struct URLSessionCloudTransport: CloudHTTPTransport {
    func data(for request: URLRequest) async throws -> CloudHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudIntegrationError.invalidResponse
        }
        return CloudHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

enum CloudInventoryService {
    static func fetchInstances(
        account: CloudAccount,
        secret: CloudAccountSecret,
        transport: any CloudHTTPTransport = URLSessionCloudTransport()
    ) async throws -> [CloudInstance] {
        guard secret.isValid(for: account.provider) else {
            throw CloudIntegrationError.missingCredentials
        }
        switch account.provider {
        case .aws:
            return try await AWSCloudProvider.fetchInstances(
                account: account,
                secret: secret,
                transport: transport
            )
        case .azure:
            return try await AzureCloudProvider.fetchInstances(
                account: account,
                secret: secret,
                transport: transport
            )
        case .digitalOcean:
            return try await DigitalOceanCloudProvider.fetchInstances(
                account: account,
                secret: secret,
                transport: transport
            )
        }
    }

    static func checked(_ result: CloudHTTPResponse) throws -> Data {
        guard (200...299).contains(result.statusCode) else {
            let body = String(data: result.data, encoding: .utf8) ?? ""
            let sanitized = body.replacingOccurrences(
                of: #"(?i)(secret|token|password)[^,}\n]*"#,
                with: "$1: ••••",
                options: .regularExpression
            )
            throw CloudIntegrationError.provider(
                "HTTP \(result.statusCode): \(String(sanitized.prefix(280)))"
            )
        }
        return result.data
    }
}

enum DigitalOceanCloudProvider {
    private struct Page: Decodable {
        struct Droplet: Decodable {
            struct Region: Decodable { let slug: String }
            struct Image: Decodable { let distribution: String; let name: String }
            struct Networks: Decodable {
                struct Address: Decodable {
                    let ipAddress: String
                    let type: String

                    enum CodingKeys: String, CodingKey {
                        case ipAddress = "ip_address"
                        case type
                    }
                }
                let v4: [Address]
            }

            let id: Int
            let name: String
            let status: String
            let region: Region
            let image: Image
            let tags: [String]
            let vpcUUID: String?
            let networks: Networks

            enum CodingKeys: String, CodingKey {
                case id, name, status, region, image, tags, networks
                case vpcUUID = "vpc_uuid"
            }
        }
        let droplets: [Droplet]
    }

    private struct ProjectResourcesPage: Decodable {
        struct Resource: Decodable { let urn: String }
        let resources: [Resource]
    }

    static func fetchInstances(
        account: CloudAccount,
        secret: CloudAccountSecret,
        transport: any CloudHTTPTransport
    ) async throws -> [CloudInstance] {
        guard let url = URL(string: "https://api.digitalocean.com/v2/droplets?per_page=200") else {
            throw CloudIntegrationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try CloudInventoryService.checked(await transport.data(for: request))
        let page = try JSONDecoder().decode(Page.self, from: data)
        let projectDropletIDs = try await projectDropletIDs(
            account: account,
            secret: secret,
            transport: transport
        )
        let droplets = projectDropletIDs.map { ids in
            page.droplets.filter { ids.contains($0.id) }
        } ?? page.droplets
        return droplets.map { droplet in
            let publicIP = droplet.networks.v4.first(where: { $0.type == "public" })?.ipAddress ?? ""
            let privateIP = droplet.networks.v4.first(where: { $0.type == "private" })?.ipAddress ?? ""
            return CloudInstance(
                resourceID: String(droplet.id),
                provider: .digitalOcean,
                name: droplet.name,
                state: CloudInstanceState(providerValue: droplet.status),
                region: droplet.region.slug,
                availabilityZone: "",
                networkName: droplet.vpcUUID ?? "",
                publicIPAddress: publicIP,
                privateIPAddress: privateIP,
                tags: droplet.tags.reduce(into: [:]) { values, tag in values[tag] = "" },
                operatingSystem: "\(droplet.image.distribution) \(droplet.image.name)"
            )
        }
    }

    private static func projectDropletIDs(
        account: CloudAccount,
        secret: CloudAccountSecret,
        transport: any CloudHTTPTransport
    ) async throws -> Set<Int>? {
        let projectID = account.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty else { return nil }
        guard let encodedProjectID = projectID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ), let url = URL(
            string: "https://api.digitalocean.com/v2/projects/\(encodedProjectID)/resources?per_page=200"
        ) else {
            throw CloudIntegrationError.invalidAccount(
                UpdateLocalization.text(
                    ru: "Некорректный DigitalOcean Project ID.",
                    en: "Invalid DigitalOcean Project ID."
                )
            )
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try CloudInventoryService.checked(await transport.data(for: request))
        let page = try JSONDecoder().decode(ProjectResourcesPage.self, from: data)
        return Set(page.resources.compactMap { resource in
            let components = resource.urn.split(separator: ":")
            guard components.count == 3,
                  components[0] == "do",
                  components[1] == "droplet"
            else { return nil }
            return Int(components[2])
        })
    }
}

enum AzureCloudProvider {
    private struct TokenResponse: Decodable { let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct ResourceGraphResponse: Decodable {
        let data: [[String: JSONValue]]
    }

    static func fetchInstances(
        account: CloudAccount,
        secret: CloudAccountSecret,
        transport: any CloudHTTPTransport
    ) async throws -> [CloudInstance] {
        let tenant = account.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = account.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscription = account.subscriptionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenant.isEmpty, !client.isEmpty, !subscription.isEmpty else {
            throw CloudIntegrationError.invalidAccount(
                UpdateLocalization.text(
                    ru: "Для Azure укажите Tenant ID, Client ID и Subscription ID.",
                    en: "Enter the Azure Tenant ID, Client ID, and Subscription ID."
                )
            )
        }

        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = formData([
            "client_id": client,
            "client_secret": secret.clientSecret,
            "scope": "https://management.azure.com/.default",
            "grant_type": "client_credentials"
        ])
        let tokenData = try CloudInventoryService.checked(await transport.data(for: tokenRequest))
        let accessToken = try JSONDecoder().decode(TokenResponse.self, from: tokenData).accessToken

        let graphURL = URL(string: "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01")!
        var graphRequest = URLRequest(url: graphURL)
        graphRequest.httpMethod = "POST"
        graphRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        graphRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = """
        Resources
        | where type =~ 'microsoft.compute/virtualmachines'
        | extend powerState=tostring(properties.extended.instanceView.powerState.code)
        | extend nicId=tolower(tostring(properties.networkProfile.networkInterfaces[0].id))
        | project id, name, resourceGroup, location, tags, powerState, nicId, osType=tostring(properties.storageProfile.osDisk.osType)
        | join kind=leftouter (
            Resources
            | where type =~ 'microsoft.network/networkinterfaces'
            | extend nicId=tolower(id), ipconfig=properties.ipConfigurations[0]
            | project nicId, privateIP=tostring(ipconfig.properties.privateIPAddress), publicIPId=tolower(tostring(ipconfig.properties.publicIPAddress.id)), subnetId=tostring(ipconfig.properties.subnet.id)
        ) on nicId
        | join kind=leftouter (
            Resources
            | where type =~ 'microsoft.network/publicipaddresses'
            | project publicIPId=tolower(id), publicIP=tostring(properties.ipAddress)
        ) on publicIPId
        | project id, name, resourceGroup, location, tags, powerState, osType, privateIP, publicIP, subnetId
        """
        graphRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "subscriptions": [subscription],
            "query": query,
            "options": ["resultFormat": "objectArray"]
        ])
        let graphData = try CloudInventoryService.checked(await transport.data(for: graphRequest))
        let response = try JSONDecoder().decode(ResourceGraphResponse.self, from: graphData)
        return response.data.compactMap { item in
            guard let resourceID = item["id"]?.stringValue,
                  let name = item["name"]?.stringValue else { return nil }
            let rawTags = item["tags"]?.objectValue ?? [:]
            let tags = rawTags.compactMapValues { $0.stringValue }
            return CloudInstance(
                resourceID: resourceID,
                provider: .azure,
                name: name,
                state: CloudInstanceState(providerValue: item["powerState"]?.stringValue ?? ""),
                region: item["location"]?.stringValue ?? "",
                availabilityZone: "",
                networkName: item["subnetId"]?.stringValue?.split(separator: "/").last.map(String.init) ?? "",
                publicIPAddress: item["publicIP"]?.stringValue ?? "",
                privateIPAddress: item["privateIP"]?.stringValue ?? "",
                tags: tags,
                operatingSystem: item["osType"]?.stringValue ?? ""
            )
        }
    }

    private static func formData(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.sorted(by: { $0.key < $1.key }).map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw CloudIntegrationError.invalidResponse }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

enum AWSCloudProvider {
    static func fetchInstances(
        account: CloudAccount,
        secret: CloudAccountSecret,
        transport: any CloudHTTPTransport
    ) async throws -> [CloudInstance] {
        let region = account.region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else {
            throw CloudIntegrationError.invalidAccount(
                UpdateLocalization.text(ru: "Для AWS укажите регион.", en: "Enter an AWS region.")
            )
        }
        let endpoint = URL(string: "https://ec2.\(region).amazonaws.com/")!
        let body = "Action=DescribeInstances&MaxResults=1000&Version=2016-11-15"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        AWSSignatureV4.sign(
            request: &request,
            body: Data(body.utf8),
            region: region,
            service: "ec2",
            accessKeyID: secret.accessKeyID,
            secretAccessKey: secret.secretAccessKey,
            sessionToken: secret.sessionToken,
            date: Date()
        )
        let data = try CloudInventoryService.checked(await transport.data(for: request))
        return try AWSEC2ResponseParser.parse(data: data, region: region)
    }
}

enum AWSSignatureV4 {
    static func sign(
        request: inout URLRequest,
        body: Data,
        region: String,
        service: String,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String,
        date: Date
    ) {
        let timestamp = awsTimestamp(date)
        let dateStamp = String(timestamp.prefix(8))
        let host = request.url?.host ?? ""
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")
        if !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        let payloadHash = sha256Hex(body)
        let tokenHeader = sessionToken.isEmpty ? "" : "x-amz-security-token:\(sessionToken)\n"
        let signedHeaders = sessionToken.isEmpty
            ? "content-type;host;x-amz-date"
            : "content-type;host;x-amz-date;x-amz-security-token"
        let canonicalHeaders = "content-type:\(request.value(forHTTPHeaderField: "Content-Type") ?? "")\n"
            + "host:\(host)\n"
            + "x-amz-date:\(timestamp)\n"
            + tokenHeader
        let canonicalRequest = [
            request.httpMethod ?? "POST", "/", "", canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"
        let dateKey = hmac(key: Data(("AWS4" + secretAccessKey).utf8), value: dateStamp)
        let regionKey = hmac(key: dateKey, value: region)
        let serviceKey = hmac(key: regionKey, value: service)
        let signingKey = hmac(key: serviceKey, value: "aws4_request")
        let signature = hmac(key: signingKey, value: stringToSign).map { String(format: "%02x", $0) }.joined()
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func awsTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
}

private final class AWSEC2ResponseParser: NSObject, XMLParserDelegate {
    private var instances: [CloudInstance] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var path: [String] = []
    private var insideInstance = false
    private var insideTag = false
    private var tagKey = ""
    private var tags: [String: String] = [:]
    private let region: String

    init(region: String) { self.region = region }

    static func parse(data: Data, region: String) throws -> [CloudInstance] {
        let delegate = AWSEC2ResponseParser(region: region)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CloudIntegrationError.invalidResponse
        }
        return delegate.instances
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        _ = parser; _ = namespaceURI; _ = qName; _ = attributeDict
        path.append(elementName)
        text = ""
        if elementName == "item", path.dropLast().last == "instancesSet" {
            insideInstance = true
            current = [:]
            tags = [:]
        } else if insideInstance, elementName == "item", path.contains("tagSet") {
            insideTag = true
            tagKey = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        _ = parser
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = parser; _ = namespaceURI; _ = qName
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideTag {
            if elementName == "key" { tagKey = value }
            if elementName == "value", !tagKey.isEmpty { tags[tagKey] = value }
            if elementName == "item" { insideTag = false }
        } else if insideInstance {
            switch elementName {
            case "instanceId", "instanceType", "privateIpAddress", "ipAddress", "subnetId", "vpcId", "availabilityZone", "architecture":
                if current[elementName] == nil { current[elementName] = value }
            case "name" where path.contains("instanceState"):
                current["state"] = value
            default:
                break
            }
            if elementName == "item", path.dropLast().last == "instancesSet" {
                let resourceID = current["instanceId"] ?? UUID().uuidString
                instances.append(
                    CloudInstance(
                        resourceID: resourceID,
                        provider: .aws,
                        name: tags["Name"]?.nilIfCloudBlank ?? resourceID,
                        state: CloudInstanceState(providerValue: current["state"] ?? ""),
                        region: region,
                        availabilityZone: current["availabilityZone"] ?? "",
                        networkName: current["vpcId"] ?? current["subnetId"] ?? "",
                        publicIPAddress: current["ipAddress"] ?? "",
                        privateIPAddress: current["privateIpAddress"] ?? "",
                        tags: tags,
                        operatingSystem: current["architecture"] ?? ""
                    )
                )
                insideInstance = false
            }
        }
        if !path.isEmpty { path.removeLast() }
        text = ""
    }
}

private extension String {
    var nilIfCloudBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

@MainActor
final class CloudIntegrationStore: ObservableObject {
    @Published private(set) var accounts: [CloudAccount]
    @Published private(set) var instancesByAccount: [UUID: [CloudInstance]] = [:]
    @Published var selectedAccountID: UUID?
    @Published private(set) var refreshingAccountIDs: Set<UUID> = []
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let accountsKey = "SelectiveRemote.cloudAccounts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accounts = Self.loadAccounts(defaults: defaults, key: accountsKey)
        selectedAccountID = accounts.first?.id
    }

    var selectedAccount: CloudAccount? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    func secret(for accountID: UUID) -> CloudAccountSecret {
        do {
            guard let value = try KeychainService.readCloudSecret(accountID: accountID),
                  let data = value.data(using: .utf8) else { return CloudAccountSecret() }
            return try JSONDecoder().decode(CloudAccountSecret.self, from: data)
        } catch {
            errorMessage = error.localizedDescription
            return CloudAccountSecret()
        }
    }

    func save(account: CloudAccount, secret: CloudAccountSecret) throws {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        accounts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !secret.isEmpty {
            let data = try JSONEncoder().encode(secret)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CloudIntegrationError.invalidResponse
            }
            try KeychainService.saveCloudSecret(value, accountID: account.id)
        }
        selectedAccountID = account.id
        persist()
        errorMessage = nil
    }

    func remove(_ account: CloudAccount) {
        try? KeychainService.deleteCloudSecret(accountID: account.id)
        accounts.removeAll { $0.id == account.id }
        instancesByAccount.removeValue(forKey: account.id)
        if selectedAccountID == account.id { selectedAccountID = accounts.first?.id }
        persist()
    }

    func refresh(_ account: CloudAccount) async {
        guard !refreshingAccountIDs.contains(account.id) else { return }
        refreshingAccountIDs.insert(account.id)
        defer { refreshingAccountIDs.remove(account.id) }
        do {
            let values = try await CloudInventoryService.fetchInstances(
                account: account,
                secret: secret(for: account.id)
            )
            instancesByAccount[account.id] = values.sorted {
                if $0.state != $1.state { return $0.state == .running }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].lastRefreshedAt = Date()
            }
            persist()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func instances(for accountID: UUID) -> [CloudInstance] {
        instancesByAccount[accountID] ?? []
    }

    func groupName(for instance: CloudInstance, account: CloudAccount) -> String {
        let suffix: String
        switch account.groupingMode {
        case .region:
            suffix = instance.region.nilIfCloudBlank ?? UpdateLocalization.text(ru: "Без региона", en: "No Region")
        case .network:
            suffix = instance.networkName.nilIfCloudBlank ?? UpdateLocalization.text(ru: "Без сети", en: "No Network")
        case .firstTag:
            suffix = instance.sortedTags.first ?? UpdateLocalization.text(ru: "Без тегов", en: "No Tags")
        }
        return "\(account.provider.title) / \(suffix)"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
        }
    }

    private static func loadAccounts(defaults: UserDefaults, key: String) -> [CloudAccount] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([CloudAccount].self, from: data)
        else { return [] }
        return values
    }
}
