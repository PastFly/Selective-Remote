import Foundation

struct SelectiveRemoteCloudDeviceTrustSnapshot: Decodable, Sendable {
    let state: String
    let rootPublicKey: String?
    let rootFingerprint: String?
    let custodianDeviceID: UUID?
    let checkpoint: SelectiveRemoteSignedDeviceDirectory?
    let certificates: [SelectiveRemoteSignedDeviceCertificate]?
}

struct SelectiveRemoteCloudDeviceTrustRequest: Decodable, Identifiable, Sendable {
    let requestID: UUID
    let deviceID: UUID
    let keyVersion: Int
    let publicKey: SelectiveRemoteTeamDevicePublicKey
    let status: String
    let createdAt: String
    let expiresAt: String
    let name: String
    let platform: String
    let challengeID: UUID?
    let challengeState: String?

    var id: UUID { requestID }
}

struct SelectiveRemoteCloudDeviceTrustChallenge: Decodable, Sendable {
    let challenge: SelectiveRemoteDevicePossessionChallenge
    let state: String
    let proof: String?
}

extension SelectiveRemoteCloudAPIClient {
    private func trustRequest<T: Decodable & Sendable>(endpoint: URL, path: String,
        method: String = "GET", body: Data? = nil) async throws -> T {
        let headers = method == "GET" ? [:] :
            ["Idempotency-Key": "macos:device-trust:\(UUID().uuidString.lowercased())"]
        let (data, response) = try await authorizedResponse(endpoint: endpoint,
            path: path, method: method, body: body, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            throw SelectiveRemoteCloudError.serviceError(response.statusCode, object?["error"])
        }
        guard let result = try? JSONDecoder().decode(T.self, from: data)
        else { throw SelectiveRemoteCloudError.invalidResponse }
        return result
    }

    func deviceTrustSnapshot(endpoint: URL) async throws -> SelectiveRemoteCloudDeviceTrustSnapshot {
        try await trustRequest(endpoint: endpoint, path: "v1/device-trust")
    }

    func deviceTrustRequests(endpoint: URL) async throws -> [SelectiveRemoteCloudDeviceTrustRequest] {
        struct Response: Decodable { let requests: [SelectiveRemoteCloudDeviceTrustRequest] }
        let response: Response = try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/requests")
        guard response.requests.count <= 100 else { throw SelectiveRemoteCloudError.invalidResponse }
        return response.requests
    }

    func deviceTrustPublishRoot(endpoint: URL, rootPublicKey: String,
        certificate: SelectiveRemoteSignedDeviceCertificate,
        checkpoint: SelectiveRemoteSignedDeviceDirectory) async throws {
        struct Body: Encodable {
            let rootPublicKey: String
            let certificate: SelectiveRemoteSignedDeviceCertificate
            let checkpoint: SelectiveRemoteSignedDeviceDirectory
        }
        struct Response: Decodable { let published: Bool }
        let response: Response = try await trustRequest(endpoint: endpoint, path: "v1/device-trust",
            method: "POST", body: JSONEncoder().encode(Body(rootPublicKey: rootPublicKey,
                certificate: certificate, checkpoint: checkpoint)))
        guard response.published else { throw SelectiveRemoteCloudError.invalidResponse }
    }

    func deviceTrustCreateRequest(endpoint: URL,
        publicKey: SelectiveRemoteTeamDevicePublicKey, keyVersion: Int) async throws -> UUID {
        struct Body: Encodable {
            let publicKey: SelectiveRemoteTeamDevicePublicKey
            let keyVersion: Int
        }
        struct Response: Decodable { let requestID: UUID; let status: String }
        let response: Response = try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/requests", method: "POST",
            body: JSONEncoder().encode(Body(publicKey: publicKey, keyVersion: keyVersion)))
        guard response.status == "pending" else { throw SelectiveRemoteCloudError.invalidResponse }
        return response.requestID
    }

    func deviceTrustStartChallenge(endpoint: URL, requestID: UUID,
        challenge: SelectiveRemoteDevicePossessionChallenge) async throws -> UUID {
        struct Body: Encodable { let challenge: SelectiveRemoteDevicePossessionChallenge }
        struct Response: Decodable { let challengeID: UUID; let status: String }
        let response: Response = try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/requests/\(requestID.canonicalCloudString)/challenges",
            method: "POST", body: JSONEncoder().encode(Body(challenge: challenge)))
        guard response.status == "challenged" else { throw SelectiveRemoteCloudError.invalidResponse }
        return response.challengeID
    }

    func deviceTrustChallenge(endpoint: URL, requestID: UUID,
        challengeID: UUID) async throws -> SelectiveRemoteCloudDeviceTrustChallenge {
        try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/requests/\(requestID.canonicalCloudString)/challenges/\(challengeID.canonicalCloudString)")
    }

    func deviceTrustAnswerChallenge(endpoint: URL, requestID: UUID, challengeID: UUID,
        proof: String) async throws {
        struct Body: Encodable { let proof: String }
        struct Response: Decodable { let status: String }
        let response: Response = try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/requests/\(requestID.canonicalCloudString)/challenges/\(challengeID.canonicalCloudString)",
            method: "POST", body: JSONEncoder().encode(Body(proof: proof)))
        guard response.status == "answered" else { throw SelectiveRemoteCloudError.invalidResponse }
    }

    func deviceTrustApprove(endpoint: URL, requestID: UUID, challengeID: UUID,
        rootPublicKey: String, certificate: SelectiveRemoteSignedDeviceCertificate,
        checkpoint: SelectiveRemoteSignedDeviceDirectory) async throws {
        struct Body: Encodable {
            let challengeID: UUID
            let rootPublicKey: String
            let certificate: SelectiveRemoteSignedDeviceCertificate
            let checkpoint: SelectiveRemoteSignedDeviceDirectory
        }
        struct Response: Decodable { let status: String }
        let response: Response = try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/requests/\(requestID.canonicalCloudString)/approve",
            method: "POST", body: JSONEncoder().encode(Body(challengeID: challengeID,
                rootPublicKey: rootPublicKey, certificate: certificate, checkpoint: checkpoint)))
        guard response.status == "approved" else { throw SelectiveRemoteCloudError.invalidResponse }
    }

    func deviceTrustReject(endpoint: URL, requestID: UUID) async throws {
        struct Response: Decodable { let status: String }
        let response: Response = try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/requests/\(requestID.canonicalCloudString)/reject",
            method: "POST")
        guard response.status == "rejected" else { throw SelectiveRemoteCloudError.invalidResponse }
    }

    func deviceTrustRevoke(endpoint: URL, deviceID: UUID, rootPublicKey: String,
        checkpoint: SelectiveRemoteSignedDeviceDirectory) async throws {
        struct Body: Encodable { let rootPublicKey: String; let checkpoint: SelectiveRemoteSignedDeviceDirectory }
        struct Response: Decodable { let status: String }
        let response: Response = try await trustRequest(endpoint: endpoint,
            path: "v1/device-trust/devices/\(deviceID.canonicalCloudString)/revoke",
            method: "POST", body: JSONEncoder().encode(Body(rootPublicKey: rootPublicKey,
                checkpoint: checkpoint)))
        guard response.status == "revoked" else { throw SelectiveRemoteCloudError.invalidResponse }
    }
}
