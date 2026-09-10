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
            switch code {
            case "invalid_credentials":
                UpdateLocalization.text(
                    ru: "Неверная электронная почта или пароль.",
                    en: "The email or password is incorrect."
                )
            case "email_not_verified":
                UpdateLocalization.text(
                    ru: "Сначала подтвердите электронную почту по ссылке из письма.",
                    en: "Verify your email using the link in the message first."
                )
            case "registration_disabled":
                UpdateLocalization.text(
                    ru: "Регистрация новых аккаунтов отключена на этом сервере.",
                    en: "New-account registration is disabled on this server."
                )
            case "smtp_not_configured":
                UpdateLocalization.text(
                    ru: "Сервер ещё не настроен для отправки письма подтверждения.",
                    en: "The server is not configured to send verification email yet."
                )
            default:
                UpdateLocalization.text(
                    ru: "Cloud недоступен (HTTP \(status)\(code.map { ": \($0)" } ?? "")).",
                    en: "Cloud is unavailable (HTTP \(status)\(code.map { ": \($0)" } ?? ""))."
                )
            }
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
    var username: String
    var displayName: String
}

enum SelectiveRemoteCloudTeamRole: String, Codable, Equatable, Hashable, Sendable {
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

struct SelectiveRemoteCloudTeamMember: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var userID: UUID
    var username: String
    var displayName: String
    var role: SelectiveRemoteCloudTeamRole
    var epoch: Int
    var joinedAt: String
}

enum SelectiveRemoteCloudTeamInvitationType: String, Codable, Equatable, Sendable {
    case email
    case username
    case link
}

struct SelectiveRemoteCloudTeamInvitation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var teamID: UUID
    var teamName: String?
    var type: SelectiveRemoteCloudTeamInvitationType
    var targetUsername: String?
    var role: SelectiveRemoteCloudTeamRole
    var status: String
    var createdAt: String
    var expiresAt: String
    var acceptanceURL: String?
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

struct SelectiveRemoteCloudTeamVaultWrapperGrant: Equatable, Sendable {
    var granted: Bool
    var keyGeneration: Int
    var deviceID: UUID
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

enum SelectiveRemoteCloudPortalURL {
    static let login = URL(string: "https://cloud.pastfly.ru/?auth=login")!

    static func registration(endpoint: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "auth", value: "registration")]
        components.fragment = nil
        return components.url!
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

    func register(
        endpoint: URL,
        displayName: String,
        username: String,
        email: String,
        password: String,
        device: SelectiveRemoteCloudDeviceRegistration
    ) async throws {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeviceName = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty, normalizedDisplayName.count <= 120,
              normalizedUsername.range(
                  of: #"^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$"#,
                  options: .regularExpression
              ) != nil,
              !normalizedEmail.isEmpty, normalizedEmail.count <= 254,
              password.count >= 12, password.count <= 1_024,
              !normalizedDeviceName.isEmpty, normalizedDeviceName.count <= 120,
              !device.platform.isEmpty, device.platform.count <= 80,
              device.appVersion.count <= 40
        else { throw SelectiveRemoteCloudError.invalidRequest }

        let body = RegistrationRequest(
            email: normalizedEmail,
            password: password,
            username: normalizedUsername,
            displayName: normalizedDisplayName,
            device: .init(
                id: device.id,
                name: normalizedDeviceName,
                platform: device.platform,
                appVersion: device.appVersion,
                publicKey: device.publicKey
            )
        )
        let request = JSONRequest(
            url: endpoint.appending(path: "v1/auth/register"),
            method: "POST",
            body: try encoder.encode(body)
        ).value
        let (data, response) = try await dataLoader(request)
        let http = try httpResponse(response)
        guard http.statusCode == 201 else {
            throw serviceError(status: http.statusCode, data: data)
        }
        guard Self.exactKeys(
            try? JSONSerialization.jsonObject(with: data),
            expected: ["verificationRequired"]
        ),
        let result = try? decoder.decode(RegistrationResponse.self, from: data),
        result.verificationRequired
        else { throw SelectiveRemoteCloudError.invalidResponse }
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

    func createTeam(endpoint: URL, name: String) async throws -> SelectiveRemoteCloudTeam {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 120 else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        let (data, http) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/teams",
            method: "POST",
            body: try encoder.encode(TeamNameRequest(name: normalizedName)),
            headers: ["Idempotency-Key": Self.idempotencyKey("team-create")]
        )
        guard http.statusCode == 201 else { throw serviceError(status: http.statusCode, data: data) }
        guard Self.validSingleTeamJSON(data),
              let result = try? decoder.decode(TeamResponse.self, from: data),
              Self.validTeam(result.team)
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.team
    }

    func teamMembers(endpoint: URL, teamID: UUID) async throws -> [SelectiveRemoteCloudTeamMember] {
        guard teamID.isSelectiveRemoteCloudUUID else { throw SelectiveRemoteCloudError.invalidRequest }
        let data = try await authorizedData(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/members"
        )
        guard Self.validTeamMembersJSON(data),
              let result = try? decoder.decode(TeamMembersResponse.self, from: data),
              result.members.count <= 10_000,
              result.members.allSatisfy(Self.validTeamMember),
              Set(result.members.map(\.id)).count == result.members.count
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.members
    }

    func teamInvitations(
        endpoint: URL,
        teamID: UUID
    ) async throws -> [SelectiveRemoteCloudTeamInvitation] {
        guard teamID.isSelectiveRemoteCloudUUID else { throw SelectiveRemoteCloudError.invalidRequest }
        let data = try await authorizedData(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/invitations"
        )
        return try Self.decodeTeamInvitations(data, expectedTeamID: teamID, endpoint: endpoint)
    }

    func pendingTeamInvitations(endpoint: URL) async throws -> [SelectiveRemoteCloudTeamInvitation] {
        let data = try await authorizedData(endpoint: endpoint, path: "v1/team-invitations")
        let invitations = try Self.decodeTeamInvitations(data, expectedTeamID: nil, endpoint: endpoint)
        guard invitations.allSatisfy({ $0.type == .username }) else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return invitations
    }

    func inviteTeamMember(
        endpoint: URL,
        teamID: UUID,
        username: String,
        role: SelectiveRemoteCloudTeamRole
    ) async throws -> SelectiveRemoteCloudTeamInvitation {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUsername = trimmedUsername.hasPrefix("@")
            ? String(trimmedUsername.dropFirst())
            : trimmedUsername
        guard teamID.isSelectiveRemoteCloudUUID,
              normalizedUsername.range(
                  of: #"^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$"#,
                  options: .regularExpression
              ) != nil,
              role != .owner
        else { throw SelectiveRemoteCloudError.invalidRequest }
        let invitation = try await createTeamInvitation(
            endpoint: endpoint,
            teamID: teamID,
            request: TeamInvitationRequest(username: normalizedUsername, email: nil, type: nil, role: role)
        )
        guard invitation.type == .username,
              invitation.targetUsername == normalizedUsername,
              invitation.acceptanceURL == nil
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return invitation
    }

    func inviteTeamMember(endpoint: URL, teamID: UUID, email: String, role: SelectiveRemoteCloudTeamRole) async throws -> SelectiveRemoteCloudTeamInvitation {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard teamID.isSelectiveRemoteCloudUUID, normalizedEmail.contains("@"), normalizedEmail.count <= 320, role != .owner else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        let invitation = try await createTeamInvitation(
            endpoint: endpoint, teamID: teamID,
            request: TeamInvitationRequest(username: nil, email: normalizedEmail, type: "email", role: role)
        )
        guard invitation.type == .email, invitation.acceptanceURL == nil else { throw SelectiveRemoteCloudError.invalidResponse }
        return invitation
    }

    func createTeamInvitationLink(
        endpoint: URL,
        teamID: UUID,
        role: SelectiveRemoteCloudTeamRole
    ) async throws -> SelectiveRemoteCloudTeamInvitation {
        guard teamID.isSelectiveRemoteCloudUUID, role != .owner else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        let invitation = try await createTeamInvitation(
            endpoint: endpoint,
            teamID: teamID,
            request: TeamInvitationRequest(username: nil, email: nil, type: "link", role: role)
        )
        guard invitation.type == .link, invitation.acceptanceURL != nil else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return invitation
    }

    private func createTeamInvitation(
        endpoint: URL,
        teamID: UUID,
        request: TeamInvitationRequest
    ) async throws -> SelectiveRemoteCloudTeamInvitation {
        let (data, http) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/invitations",
            method: "POST",
            body: try encoder.encode(request),
            headers: ["Idempotency-Key": Self.idempotencyKey("team-invite")]
        )
        guard http.statusCode == 201 else { throw serviceError(status: http.statusCode, data: data) }
        guard Self.validTeamInvitationJSON(data),
              let result = try? decoder.decode(TeamInvitationResponse.self, from: data),
              Self.validTeamInvitation(result.invitation, teamID: teamID, endpoint: endpoint)
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.invitation
    }

    func acceptTeamInvitation(endpoint: URL, invitationID: UUID) async throws -> SelectiveRemoteCloudTeamMember {
        guard invitationID.isSelectiveRemoteCloudUUID else { throw SelectiveRemoteCloudError.invalidRequest }
        let (data, http) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/team-invitations/accept",
            method: "POST",
            body: try encoder.encode(TeamInvitationAcceptanceRequest(invitationID: invitationID)),
            headers: ["Idempotency-Key": Self.idempotencyKey("team-invite-accept")]
        )
        guard http.statusCode == 200,
              Self.validTeamInvitationAcceptanceJSON(data),
              let result = try? decoder.decode(TeamInvitationAcceptanceResponse.self, from: data),
              Self.validTeamMember(result.membership)
        else {
            if http.statusCode != 200 { throw serviceError(status: http.statusCode, data: data) }
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return result.membership
    }

    func cancelTeamInvitation(
        endpoint: URL,
        teamID: UUID,
        invitationID: UUID
    ) async throws {
        guard teamID.isSelectiveRemoteCloudUUID, invitationID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        let (data, http) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/invitations/\(invitationID.canonicalCloudString)",
            method: "DELETE",
            headers: ["Idempotency-Key": Self.idempotencyKey("team-invite-cancel")]
        )
        guard http.statusCode == 200,
              Self.validTeamInvitationCancellationJSON(data),
              (try? decoder.decode(TeamInvitationCancellationResponse.self, from: data).cancelled) == true
        else {
            if http.statusCode != 200 { throw serviceError(status: http.statusCode, data: data) }
            throw SelectiveRemoteCloudError.invalidResponse
        }
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

    func createSharedVault(
        endpoint: URL,
        teamID: UUID,
        name: String
    ) async throws -> SelectiveRemoteCloudSharedVault {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard teamID.isSelectiveRemoteCloudUUID,
              !normalizedName.isEmpty,
              normalizedName.count <= 120
        else { throw SelectiveRemoteCloudError.invalidRequest }
        let (data, http) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/vaults",
            method: "POST",
            body: try encoder.encode(TeamNameRequest(name: normalizedName)),
            headers: ["Idempotency-Key": Self.idempotencyKey("vault-create")]
        )
        guard http.statusCode == 201 else { throw serviceError(status: http.statusCode, data: data) }
        guard Self.validSingleSharedVaultJSON(data),
              let result = try? decoder.decode(SharedVaultResponse.self, from: data),
              Self.validSharedVault(result.vault, teamID: teamID)
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.vault
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

    func grantSharedVaultWrapper(
        endpoint: URL,
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int,
        wrapper: SelectiveRemoteTeamVaultKeyWrapper,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWrapperGrant {
        let wrapperIsValid = (try? Self.validWrapper(
            wrapper,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: keyGeneration
        )) == true
        guard teamID.isSelectiveRemoteCloudUUID,
              vaultID.isSelectiveRemoteCloudUUID,
              keyGeneration > 0,
              Self.validIdempotencyKey(idempotencyKey),
              wrapperIsValid
        else { throw SelectiveRemoteCloudError.invalidRequest }

        let (data, http) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)/wrappers",
            method: "POST",
            body: try encoder.encode(TeamVaultWrapperGrantRequest(
                keyGeneration: keyGeneration,
                wrapper: wrapper
            )),
            headers: ["Idempotency-Key": idempotencyKey]
        )
        guard http.statusCode == 201 else {
            throw serviceError(status: http.statusCode, data: data)
        }
        guard Self.validTeamVaultWrapperGrantJSON(data),
              let response = try? decoder.decode(TeamVaultWrapperGrantResponse.self, from: data),
              response.granted,
              response.keyGeneration == keyGeneration,
              response.deviceID == wrapper.deviceID
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return .init(
            granted: true,
            keyGeneration: response.keyGeneration,
            deviceID: response.deviceID
        )
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

    func authorizedResponse(
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
            && !user.username.isEmpty
            && user.username.count <= 32
            && !user.displayName.isEmpty
            && user.displayName.count <= 120
    }

    private static func validUserObject(_ value: Any?) -> Bool {
        guard exactKeys(
            value,
            expected: ["id", "email", "username", "displayName", "createdAt"]
        ), let createdAt = (value as? [String: Any])?["createdAt"] as? String
        else { return false }
        return !createdAt.isEmpty && createdAt.count <= 64
    }

    private static func validUserJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        guard exactKeys(object, expected: ["id", "email", "username", "displayName", "deviceID"]),
              let deviceID = (object as? [String: Any])?["deviceID"] as? String,
              UUID(uuidString: deviceID)?.isSelectiveRemoteCloudUUID == true
        else { return false }
        return true
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

    private static func validTeam(_ team: SelectiveRemoteCloudTeam) -> Bool {
        team.id.isSelectiveRemoteCloudUUID
            && team.membershipID.isSelectiveRemoteCloudUUID
            && team.membershipEpoch > 0
            && !team.name.isEmpty
            && team.name.count <= 120
            && !team.createdAt.isEmpty
            && !team.updatedAt.isEmpty
    }

    private static func validSingleTeamJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["team"]),
              let team = (object as? [String: Any])?["team"]
        else { return false }
        return exactKeys(team, expected: [
            "id", "name", "membershipID", "role", "membershipEpoch", "createdAt", "updatedAt"
        ])
    }

    private static func validTeamMember(_ member: SelectiveRemoteCloudTeamMember) -> Bool {
        member.id.isSelectiveRemoteCloudUUID
            && member.userID.isSelectiveRemoteCloudUUID
            && !member.username.isEmpty && member.username.count <= 32
            && !member.displayName.isEmpty && member.displayName.count <= 120
            && member.epoch > 0 && !member.joinedAt.isEmpty
    }

    private static func validTeamMembersJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["members"]),
              let members = (object as? [String: Any])?["members"] as? [Any]
        else { return false }
        return members.allSatisfy { exactKeys($0, expected: [
            "id", "userID", "username", "displayName", "role", "epoch", "joinedAt"
        ]) }
    }

    private static func validTeamInvitationJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["invitation"]),
              let invitation = (object as? [String: Any])?["invitation"]
        else { return false }
        return exactKeys(invitation, expected: [
            "id", "teamID", "teamName", "type", "targetUsername", "role", "status",
            "createdAt", "expiresAt", "acceptanceURL"
        ])
    }

    private static func validTeamInvitation(
        _ invitation: SelectiveRemoteCloudTeamInvitation,
        teamID: UUID,
        endpoint: URL
    ) -> Bool {
        guard invitation.id.isSelectiveRemoteCloudUUID
            && invitation.teamID == teamID
            && invitation.role != .owner
            && invitation.status == "pending"
            && !invitation.createdAt.isEmpty
            && !invitation.expiresAt.isEmpty
            && invitation.teamName.map({ !$0.isEmpty && $0.count <= 120 }) ?? true
        else { return false }
        switch invitation.type {
        case .username:
            guard let username = invitation.targetUsername,
                  username.range(
                    of: #"^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$"#,
                    options: .regularExpression
                  ) != nil,
                  invitation.acceptanceURL == nil
            else { return false }
        case .email:
            guard invitation.targetUsername == nil, invitation.acceptanceURL == nil else { return false }
        case .link:
            guard invitation.targetUsername == nil else { return false }
            if let value = invitation.acceptanceURL {
                guard let url = URL(string: value),
                      url.scheme == endpoint.scheme,
                      url.host == endpoint.host,
                      url.port == endpoint.port,
                      url.user == nil,
                      url.password == nil,
                      url.path == "/",
                      url.query == nil,
                      url.fragment?.range(
                        of: #"^accept-team-invitation\?token=[A-Za-z0-9_-]{43}$"#,
                        options: .regularExpression
                      ) != nil
                else { return false }
            }
        }
        return true
    }

    private static func decodeTeamInvitations(
        _ data: Data,
        expectedTeamID: UUID?,
        endpoint: URL
    ) throws -> [SelectiveRemoteCloudTeamInvitation] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["invitations"]),
              let invitations = (object as? [String: Any])?["invitations"] as? [Any],
              invitations.allSatisfy({ value in
                  exactKeys(value, expected: [
                    "id", "teamID", "teamName", "type", "targetUsername", "role", "status",
                    "createdAt", "expiresAt", "acceptanceURL"
                  ])
              }),
              let result = try? JSONDecoder().decode(TeamInvitationsResponse.self, from: data),
              result.invitations.count <= 10_000,
              Set(result.invitations.map(\.id)).count == result.invitations.count,
              result.invitations.allSatisfy({ invitation in
                  (expectedTeamID == nil || invitation.teamID == expectedTeamID)
                      && validTeamInvitation(invitation, teamID: invitation.teamID, endpoint: endpoint)
              })
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result.invitations
    }

    private static func validTeamInvitationAcceptanceJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["membership"]),
              let membership = (object as? [String: Any])?["membership"]
        else { return false }
        return exactKeys(membership, expected: [
            "id", "userID", "username", "displayName", "role", "epoch", "joinedAt"
        ])
    }

    private static func validTeamInvitationCancellationJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return exactKeys(object, expected: ["cancelled"])
            && (object as? [String: Any])?["cancelled"] as? Bool == true
    }

    private static func validSingleSharedVaultJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              exactKeys(object, expected: ["vault"]),
              let vault = (object as? [String: Any])?["vault"]
        else { return false }
        return exactKeys(vault, expected: [
            "id", "teamID", "name", "revision", "keyGeneration", "rotationRequired",
            "createdAt", "updatedAt"
        ])
    }

    private static func idempotencyKey(_ scope: String) -> String {
        "macos:\(scope):\(UUID().uuidString.lowercased())"
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

    private static func validTeamVaultWrapperGrantJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return exactKeys(object, expected: ["granted", "keyGeneration", "deviceID"])
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

    private static func validWrapper(
        _ wrapper: SelectiveRemoteTeamVaultKeyWrapper,
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int
    ) throws -> Bool {
        let context = try SelectiveRemoteTeamWrapperContext(
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: keyGeneration,
            membershipID: wrapper.membershipID,
            membershipEpoch: wrapper.membershipEpoch,
            deviceID: wrapper.deviceID
        )
        return wrapper.contextHash == SelectiveRemoteTeamVaultCrypto.wrapperContextHash(context)
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
        return try wrappers.allSatisfy {
            try validWrapper(
                $0,
                teamID: teamID,
                vaultID: vaultID,
                keyGeneration: upload.envelope.keyGeneration
            )
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

private struct RegistrationRequest: Encodable {
    var email: String
    var password: String
    var username: String
    var displayName: String
    var device: SelectiveRemoteCloudDeviceRegistration
}

private struct RegistrationResponse: Decodable {
    var verificationRequired: Bool
}

private struct LoginResponse: Decodable {
    var token: String
    var user: SelectiveRemoteCloudUser
    var deviceID: UUID
}

private struct TeamsResponse: Decodable {
    var teams: [SelectiveRemoteCloudTeam]
}

private struct TeamResponse: Decodable {
    var team: SelectiveRemoteCloudTeam
}

private struct TeamMembersResponse: Decodable {
    var members: [SelectiveRemoteCloudTeamMember]
}

private struct TeamInvitationResponse: Decodable {
    var invitation: SelectiveRemoteCloudTeamInvitation
}

private struct TeamInvitationsResponse: Decodable {
    var invitations: [SelectiveRemoteCloudTeamInvitation]
}

private struct TeamInvitationAcceptanceResponse: Decodable {
    var membership: SelectiveRemoteCloudTeamMember
}

private struct TeamInvitationCancellationResponse: Decodable {
    var cancelled: Bool
}

private struct SharedVaultResponse: Decodable {
    var vault: SelectiveRemoteCloudSharedVault
}

private struct TeamNameRequest: Encodable {
    var name: String
}

private struct TeamInvitationRequest: Encodable {
    var username: String?
    var email: String?
    var type: String?
    var role: SelectiveRemoteCloudTeamRole
}

private struct TeamInvitationAcceptanceRequest: Encodable {
    var invitationID: UUID
}

private struct SharedVaultsResponse: Decodable {
    var vaults: [SelectiveRemoteCloudSharedVault]
}

private struct TeamKeyDevicesResponse: Decodable {
    var devices: [SelectiveRemoteCloudTeamKeyDevice]
}

private struct TeamVaultWrapperGrantRequest: Encodable {
    var keyGeneration: Int
    var wrapper: SelectiveRemoteTeamVaultKeyWrapper
}

private struct TeamVaultWrapperGrantResponse: Decodable {
    var granted: Bool
    var keyGeneration: Int
    var deviceID: UUID
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
