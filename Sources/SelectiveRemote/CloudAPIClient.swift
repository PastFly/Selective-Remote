import Foundation

enum SelectiveRemoteCloudError: LocalizedError, Equatable {
    case invalidEndpoint
    case insecureEndpoint
    case invalidRequest
    case authenticationRequired
    case invalidResponse
    case serviceError(Int, String?)
    case incompatibleAPI(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            UpdateLocalization.text(
                ru: "Укажите корректный адрес Selective Remote Cloud.",
                en: "Enter a valid Selective Remote Cloud address."
            )
        case .insecureEndpoint:
            UpdateLocalization.text(
                ru: "Для Cloud требуется HTTPS. HTTP разрешён только для localhost.",
                en: "Cloud requires HTTPS. HTTP is allowed only for localhost."
            )
        case .invalidRequest:
            UpdateLocalization.text(
                ru: "Проверьте данные аккаунта и этого Mac.",
                en: "Check the account and this Mac's details."
            )
        case .authenticationRequired:
            UpdateLocalization.text(
                ru: "Сессия Cloud завершена. Войдите снова.",
                en: "The Cloud session ended. Sign in again."
            )
        case .invalidResponse:
            UpdateLocalization.text(
                ru: "Cloud вернул некорректный ответ.",
                en: "Cloud returned an invalid response."
            )
        case let .serviceError(status, code):
            UpdateLocalization.text(
                ru: "Cloud недоступен (HTTP \(status)\(code.map { ": \($0)" } ?? "")).",
                en: "Cloud is unavailable (HTTP \(status)\(code.map { ": \($0)" } ?? ""))."
            )
        case let .incompatibleAPI(version):
            UpdateLocalization.text(
                ru: "Версия Cloud API \(version) пока не поддерживается.",
                en: "Cloud API version \(version) is not supported yet."
            )
        }
    }
}

struct SelectiveRemoteCloudMetadata: Codable, Equatable, Sendable {
    var apiVersion: Int
    var vaultSchemaVersion: Int
    var registrationEnabled: Bool
}

struct SelectiveRemoteCloudUser: Codable, Equatable, Sendable {
    var id: UUID
    var email: String
    var displayName: String
}

enum SelectiveRemoteCloudTeamRole: String, Codable, Equatable, Sendable {
    case owner
    case admin
    case editor
    case viewer
}

struct SelectiveRemoteCloudTeam: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var membershipID: UUID
    var role: SelectiveRemoteCloudTeamRole
    var membershipEpoch: Int
    var createdAt: String
    var updatedAt: String
}

struct SelectiveRemoteCloudDeviceRegistration: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var platform: String
    var appVersion: String
    var publicKey: SelectiveRemoteTeamDevicePublicKey?

    static func thisMac(
        id: UUID,
        name: String = Host.current().localizedName ?? "Mac",
        publicKey: SelectiveRemoteTeamDevicePublicKey? = nil
    ) -> Self {
        Self(
            id: id,
            name: name,
            platform: "macos",
            appVersion: AppBuildInfo.version,
            publicKey: publicKey
        )
    }
}

typealias SelectiveRemoteCloudDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum SelectiveRemoteCloudEndpoint {
    static let production = "https://cloud.pastfly.ru"

    static func normalized(_ value: String) throws -> URL {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.path.isEmpty || url.path == "/",
              url.query == nil,
              url.fragment == nil
        else { throw SelectiveRemoteCloudError.invalidEndpoint }

        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw SelectiveRemoteCloudError.insecureEndpoint
        }
        return url
    }
}

actor SelectiveRemoteCloudAPIClient {
    private let dataLoader: SelectiveRemoteCloudDataLoader
    private let tokenStore: any SelectiveRemoteCloudTokenStore
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        session: URLSession = .shared,
        tokenStore: any SelectiveRemoteCloudTokenStore = SelectiveRemoteCloudKeychainTokenStore(),
        dataLoader: SelectiveRemoteCloudDataLoader? = nil
    ) {
        self.tokenStore = tokenStore
        self.dataLoader = dataLoader ?? { request in
            try await session.data(for: request)
        }
    }

    func metadata(endpoint: URL) async throws -> SelectiveRemoteCloudMetadata {
        let url = endpoint.appending(path: "v1/meta")
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("SelectiveRemote/\(AppBuildInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let service = try? decoder.decode(CloudServiceError.self, from: data)
            throw SelectiveRemoteCloudError.serviceError(http.statusCode, service?.error)
        }
        guard let metadata = try? decoder.decode(SelectiveRemoteCloudMetadata.self, from: data) else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        guard metadata.apiVersion == 1 else {
            throw SelectiveRemoteCloudError.incompatibleAPI(metadata.apiVersion)
        }
        return metadata
    }

    func hasStoredSession(endpoint: URL) -> Bool {
        (try? storedToken(for: endpoint)) != nil
    }

    func login(
        endpoint: URL,
        email: String,
        password: String,
        device: SelectiveRemoteCloudDeviceRegistration
    ) async throws -> SelectiveRemoteCloudUser {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, normalizedEmail.count <= 254,
              password.count >= 12, password.count <= 1_024,
              !normalizedName.isEmpty, normalizedName.count <= 120,
              !device.platform.isEmpty, device.platform.count <= 80,
              device.appVersion.count <= 40
        else { throw SelectiveRemoteCloudError.invalidRequest }

        let body = LoginRequest(
            email: normalizedEmail,
            password: password,
            device: .init(
                id: device.id,
                name: normalizedName,
                platform: device.platform,
                appVersion: device.appVersion,
                publicKey: device.publicKey
            )
        )
        var request = JSONRequest(
            url: endpoint.appending(path: "v1/auth/login"),
            method: "POST",
            body: try encoder.encode(body)
        ).value
        request.timeoutInterval = 20
        let (data, response) = try await dataLoader(request)
        let http = try httpResponse(response)
        guard (200..<300).contains(http.statusCode) else {
            throw serviceError(status: http.statusCode, data: data)
        }
        guard let result = try? decoder.decode(LoginResponse.self, from: data),
              (32...256).contains(result.token.count),
              result.deviceID == device.id
        else { throw SelectiveRemoteCloudError.invalidResponse }
        try tokenStore.saveToken(result.token, for: endpoint)
        return result.user
    }

    func currentUser(endpoint: URL) async throws -> SelectiveRemoteCloudUser {
        let data = try await authorizedData(endpoint: endpoint, path: "v1/me")
        guard let user = try? decoder.decode(SelectiveRemoteCloudUser.self, from: data) else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return user
    }

    func teams(endpoint: URL) async throws -> [SelectiveRemoteCloudTeam] {
        let data = try await authorizedData(endpoint: endpoint, path: "v1/teams")
        guard let result = try? decoder.decode(TeamsResponse.self, from: data),
              result.teams.count <= 1_000,
              result.teams.allSatisfy({ $0.membershipEpoch > 0 && !$0.name.isEmpty })
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.teams
    }

    func logout(endpoint: URL) async throws {
        guard let token = try storedToken(for: endpoint) else { return }
        var request = JSONRequest(
            url: endpoint.appending(path: "v1/auth/logout"),
            method: "POST",
            body: nil
        ).value
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await dataLoader(request)
            let http = try httpResponse(response)
            guard http.statusCode == 204 || http.statusCode == 401 else {
                throw serviceError(status: http.statusCode, data: data)
            }
        } catch {
            try? tokenStore.removeToken(for: endpoint)
            throw error
        }
        try tokenStore.removeToken(for: endpoint)
    }

    private func authorizedData(endpoint: URL, path: String) async throws -> Data {
        guard let token = try storedToken(for: endpoint) else {
            throw SelectiveRemoteCloudError.authenticationRequired
        }
        var request = JSONRequest(
            url: endpoint.appending(path: path),
            method: "GET",
            body: nil
        ).value
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await dataLoader(request)
        let http = try httpResponse(response)
        if http.statusCode == 401 {
            try? tokenStore.removeToken(for: endpoint)
            throw SelectiveRemoteCloudError.authenticationRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw serviceError(status: http.statusCode, data: data)
        }
        return data
    }

    private func storedToken(for endpoint: URL) throws -> String? {
        guard let token = try tokenStore.token(for: endpoint) else { return nil }
        guard (32...256).contains(token.count) else {
            try tokenStore.removeToken(for: endpoint)
            return nil
        }
        return token
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return response
    }

    private func serviceError(status: Int, data: Data) -> SelectiveRemoteCloudError {
        let service = try? decoder.decode(CloudServiceError.self, from: data)
        return .serviceError(status, service?.error)
    }
}

private struct JSONRequest {
    var value: URLRequest

    init(url: URL, method: String, body: Data?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("SelectiveRemote/\(AppBuildInfo.version)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        value = request
    }
}

private struct LoginRequest: Encodable {
    var email: String
    var password: String
    var device: SelectiveRemoteCloudDeviceRegistration
}

private struct LoginResponse: Decodable {
    var token: String
    var user: SelectiveRemoteCloudUser
    var deviceID: UUID
}

private struct TeamsResponse: Decodable {
    var teams: [SelectiveRemoteCloudTeam]
}

private struct CloudServiceError: Decodable {
    var error: String
}
