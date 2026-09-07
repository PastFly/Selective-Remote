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

struct SelectiveRemoteCloudTeam: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var membershipID: UUID
    var role: SelectiveRemoteCloudTeamRole
    var membershipEpoch: Int
    var createdAt: String
    var updatedAt: String
}

struct SelectiveRemoteCloudSharedVault: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var teamID: UUID
    var name: String
    var revision: Int
    var keyGeneration: Int
    var rotationRequired: Bool
    var createdAt: String
    var updatedAt: String
}

struct SelectiveRemoteCloudTeamKeyDevice: Codable, Equatable, Sendable {
    var membershipID: UUID
    var membershipEpoch: Int
    var deviceID: UUID
    var publicKeyAlgorithm: String
    var publicKey: SelectiveRemoteTeamDevicePublicKey
    var hasWrapper: Bool
}

struct SelectiveRemoteCloudSharedVaultEnvelope: Codable, Equatable, Sendable {
    var id: UUID
    var teamID: UUID
    var name: String
    var revision: Int
    var keyGeneration: Int
    var rotationRequired: Bool
    var envelopeVersion: Int?
    var ciphertext: String?
    var nonce: String?
    var authTag: String?
    var contentHash: String?
    var wrapper: SelectiveRemoteTeamVaultKeyWrapper?
    var createdAt: String
    var updatedAt: String

    var payloadEnvelope: SelectiveRemoteTeamVaultPayloadEnvelope? {
        get throws {
            guard revision > 0 else { return nil }
            guard let envelopeVersion, let ciphertext, let nonce, let authTag, let contentHash else {
                throw SelectiveRemoteCloudError.invalidResponse
            }
            do {
                return try SelectiveRemoteTeamVaultPayloadEnvelope(
                    baseRevision: revision - 1,
                    keyGeneration: keyGeneration,
                    envelopeVersion: envelopeVersion,
                    ciphertext: ciphertext,
                    nonce: nonce,
                    authTag: authTag,
                    contentHash: contentHash
                )
            } catch {
                throw SelectiveRemoteCloudError.invalidResponse
            }
        }
    }
}

struct SelectiveRemoteCloudTeamVaultUpload: Encodable, Equatable, Sendable {
    var envelope: SelectiveRemoteTeamVaultPayloadEnvelope
    var wrappers: [SelectiveRemoteTeamVaultKeyWrapper]?

    enum CodingKeys: String, CodingKey {
        case baseRevision, keyGeneration, envelopeVersion
        case ciphertext, nonce, authTag, contentHash, wrappers
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(envelope.baseRevision, forKey: .baseRevision)
        try values.encode(envelope.keyGeneration, forKey: .keyGeneration)
        try values.encode(envelope.envelopeVersion, forKey: .envelopeVersion)
        try values.encode(envelope.ciphertext, forKey: .ciphertext)
        try values.encode(envelope.nonce, forKey: .nonce)
        try values.encode(envelope.authTag, forKey: .authTag)
        try values.encode(envelope.contentHash, forKey: .contentHash)
        try values.encodeIfPresent(wrappers, forKey: .wrappers)
    }
}

struct SelectiveRemoteCloudTeamVaultWriteResult: Equatable, Sendable {
    var conflict: Bool
    var revision: Int
    var keyGeneration: Int
    var rotationCompleted: Bool?
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
        guard Self.validLoginJSON(data),
              let result = try? decoder.decode(LoginResponse.self, from: data),
              (32...256).contains(result.token.count),
              result.deviceID == device.id,
              Self.validUser(result.user)
        else { throw SelectiveRemoteCloudError.invalidResponse }
        try tokenStore.saveToken(result.token, for: endpoint)
        return result.user
    }

    func currentUser(endpoint: URL) async throws -> SelectiveRemoteCloudUser {
        let data = try await authorizedData(endpoint: endpoint, path: "v1/me")
        guard Self.validUserJSON(data),
              let user = try? decoder.decode(SelectiveRemoteCloudUser.self, from: data),
              Self.validUser(user)
        else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return user
    }

    func teams(endpoint: URL) async throws -> [SelectiveRemoteCloudTeam] {
        let data = try await authorizedData(endpoint: endpoint, path: "v1/teams")
        guard Self.validTeamsJSON(data),
              let result = try? decoder.decode(TeamsResponse.self, from: data),
              result.teams.count <= 1_000,
              result.teams.allSatisfy({ team in
                  team.id.isSelectiveRemoteCloudUUID
                      && team.membershipID.isSelectiveRemoteCloudUUID
                      && team.membershipEpoch > 0
                      && !team.name.isEmpty
                      && team.name.count <= 120
                      && !team.createdAt.isEmpty
                      && !team.updatedAt.isEmpty
              }),
              Set(result.teams.map(\.id)).count == result.teams.count,
              Set(result.teams.map(\.membershipID)).count == result.teams.count
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.teams
    }

    func sharedVaults(endpoint: URL, teamID: UUID) async throws -> [SelectiveRemoteCloudSharedVault] {
        guard teamID.isSelectiveRemoteCloudUUID else { throw SelectiveRemoteCloudError.invalidRequest }
        let data = try await authorizedData(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/vaults"
        )
        guard Self.validSharedVaultsJSON(data),
              let result = try? decoder.decode(SharedVaultsResponse.self, from: data),
              result.vaults.count <= 10_000,
              result.vaults.allSatisfy({ Self.validSharedVault($0, teamID: teamID) }),
              Set(result.vaults.map(\.id)).count == result.vaults.count
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.vaults
    }

    func teamKeyDevices(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> [SelectiveRemoteCloudTeamKeyDevice] {
        guard teamID.isSelectiveRemoteCloudUUID, vaultID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        let data = try await authorizedData(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)/key-devices"
        )
        guard Self.validTeamKeyDevicesJSON(data),
              let result = try? decoder.decode(TeamKeyDevicesResponse.self, from: data),
              result.devices.count <= 1_024,
              result.devices.allSatisfy({ device in
                  device.membershipID.isSelectiveRemoteCloudUUID
                      && device.deviceID.isSelectiveRemoteCloudUUID
                      && device.membershipEpoch > 0
                      && device.publicKeyAlgorithm == "p256-ecdh-v1"
              }),
              Set(result.devices.map(\.deviceID)).count == result.devices.count
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.devices
    }

    func sharedVault(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> SelectiveRemoteCloudSharedVaultEnvelope {
        guard teamID.isSelectiveRemoteCloudUUID, vaultID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        let data = try await authorizedData(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)"
        )
        guard Self.validSharedVaultEnvelopeJSON(data),
              let result = try? decoder.decode(SelectiveRemoteCloudSharedVaultEnvelope.self, from: data),
              Self.validSharedVaultEnvelope(result, teamID: teamID, vaultID: vaultID)
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result
    }

    func putSharedVault(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID,
        upload: SelectiveRemoteCloudTeamVaultUpload,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWriteResult {
        let uploadIsValid = (try? Self.validUpload(upload, teamID: teamID, vaultID: vaultID)) == true
        guard teamID.isSelectiveRemoteCloudUUID,
              vaultID.isSelectiveRemoteCloudUUID,
              Self.validIdempotencyKey(idempotencyKey),
              uploadIsValid
        else { throw SelectiveRemoteCloudError.invalidRequest }
        let (data, http) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)",
            method: "PUT",
            body: try encoder.encode(upload),
            headers: ["Idempotency-Key": idempotencyKey]
        )
        guard http.statusCode == 200 || http.statusCode == 409,
              Self.validTeamVaultWriteJSON(data, conflict: http.statusCode == 409),
              let response = try? decoder.decode(TeamVaultWriteResponse.self, from: data),
              response.conflict == (http.statusCode == 409),
              response.revision >= 0,
              response.keyGeneration > 0,
              (response.conflict
                  ? response.rotationCompleted == nil
                  : response.revision > 0 && response.rotationCompleted != nil)
        else {
            if !(200..<300).contains(http.statusCode), http.statusCode != 409 {
                throw serviceError(status: http.statusCode, data: data)
            }
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return .init(
            conflict: response.conflict,
            revision: response.revision,
            keyGeneration: response.keyGeneration,
            rotationCompleted: response.rotationCompleted
        )
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
        let (data, http) = try await authorizedResponse(endpoint: endpoint, path: path)
        guard (200..<300).contains(http.statusCode) else {
            throw serviceError(status: http.statusCode, data: data)
        }
        return data
    }

    private func authorizedResponse(
        endpoint: URL,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        guard let token = try storedToken(for: endpoint) else {
            throw SelectiveRemoteCloudError.authenticationRequired
        }
        var request = JSONRequest(
            url: endpoint.appending(path: path),
            method: method,
            body: body
        ).value
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await dataLoader(request)
        let http = try httpResponse(response)
        if http.statusCode == 401 {
            try? tokenStore.removeToken(for: endpoint)
            throw SelectiveRemoteCloudError.authenticationRequired
        }
        return (data, http)
    }

    private static func validSharedVault(_ value: SelectiveRemoteCloudSharedVault, teamID: UUID) -> Bool {
        value.id.isSelectiveRemoteCloudUUID
            && value.teamID == teamID
            && !value.name.isEmpty
            && value.name.count <= 120
            && value.revision >= 0
            && value.keyGeneration > 0
            && !value.createdAt.isEmpty
            && !value.updatedAt.isEmpty
    }

    private static func exactKeys(_ value: Any?, expected: Set<String>) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return Set(object.keys) == expected
    }

    private static func validUser(_ user: SelectiveRemoteCloudUser) -> Bool {
        user.id.isSelectiveRemoteCloudUUID
            && !user.email.isEmpty
            && user.email.count <= 254
            && !user.displayName.isEmpty
            && user.displayName.count <= 120
    }

    private static func validUserObject(_ value: Any?) -> Bool {
        exactKeys(value, expected: ["id", "email", "displayName"])
    }

    private static func validUserJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return validUserObject(object)
    }

    private static func validLoginJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["token", "user", "deviceID"]),
              let user = (object as? [String: Any])?["user"]
        else { return false }
        return validUserObject(user)
    }

    private static func validSharedVaultsJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["vaults"]),
              let vaults = (object as? [String: Any])?["vaults"] as? [Any]
        else { return false }
        let keys: Set<String> = [
            "id", "teamID", "name", "revision", "keyGeneration", "rotationRequired",
            "createdAt", "updatedAt"
        ]
        return vaults.allSatisfy { exactKeys($0, expected: keys) }
    }

    private static func validTeamsJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["teams"]),
              let teams = (object as? [String: Any])?["teams"] as? [Any]
        else { return false }
        let keys: Set<String> = [
            "id", "name", "membershipID", "role", "membershipEpoch",
            "createdAt", "updatedAt"
        ]
        return teams.allSatisfy { exactKeys($0, expected: keys) }
    }

    private static func validTeamKeyDevicesJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["devices"]),
              let devices = (object as? [String: Any])?["devices"] as? [Any]
        else { return false }
        let keys: Set<String> = [
            "membershipID", "membershipEpoch", "deviceID", "publicKeyAlgorithm",
            "publicKey", "hasWrapper"
        ]
        return devices.allSatisfy { exactKeys($0, expected: keys) }
    }

    private static func validSharedVaultEnvelopeJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return exactKeys(object, expected: [
            "id", "teamID", "name", "revision", "keyGeneration", "rotationRequired",
            "envelopeVersion", "ciphertext", "nonce", "authTag", "contentHash", "wrapper",
            "createdAt", "updatedAt"
        ])
    }

    private static func validTeamVaultWriteJSON(_ data: Data, conflict: Bool) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return exactKeys(
            object,
            expected: conflict
                ? ["conflict", "revision", "keyGeneration"]
                : ["conflict", "revision", "keyGeneration", "rotationCompleted"]
        )
    }

    private static func validSharedVaultEnvelope(
        _ value: SelectiveRemoteCloudSharedVaultEnvelope,
        teamID: UUID,
        vaultID: UUID
    ) -> Bool {
        let summary = SelectiveRemoteCloudSharedVault(
            id: value.id,
            teamID: value.teamID,
            name: value.name,
            revision: value.revision,
            keyGeneration: value.keyGeneration,
            rotationRequired: value.rotationRequired,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt
        )
        guard value.id == vaultID, validSharedVault(summary, teamID: teamID) else { return false }
        if value.revision == 0 {
            return value.envelopeVersion == nil
                && value.ciphertext == nil
                && value.nonce == nil
                && value.authTag == nil
                && value.contentHash == nil
                && value.wrapper == nil
        }
        return (try? value.payloadEnvelope) != nil
    }

    private static func validIdempotencyKey(_ value: String) -> Bool {
        (16...128).contains(value.count)
            && value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    }

    private static func validUpload(
        _ upload: SelectiveRemoteCloudTeamVaultUpload,
        teamID: UUID,
        vaultID: UUID
    ) throws -> Bool {
        guard let wrappers = upload.wrappers else { return true }
        guard !wrappers.isEmpty,
              wrappers.count <= 1_024,
              Set(wrappers.map(\.deviceID)).count == wrappers.count
        else { return false }
        return try wrappers.allSatisfy { wrapper in
            let context = try SelectiveRemoteTeamWrapperContext(
                teamID: teamID,
                vaultID: vaultID,
                keyGeneration: upload.envelope.keyGeneration,
                membershipID: wrapper.membershipID,
                membershipEpoch: wrapper.membershipEpoch,
                deviceID: wrapper.deviceID
            )
            return wrapper.contextHash == SelectiveRemoteTeamVaultCrypto.wrapperContextHash(context)
        }
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

private struct SharedVaultsResponse: Decodable {
    var vaults: [SelectiveRemoteCloudSharedVault]
}

private struct TeamKeyDevicesResponse: Decodable {
    var devices: [SelectiveRemoteCloudTeamKeyDevice]
}

private struct TeamVaultWriteResponse: Decodable {
    var conflict: Bool
    var revision: Int
    var keyGeneration: Int
    var rotationCompleted: Bool?
}

private struct CloudServiceError: Decodable {
    var error: String
}
