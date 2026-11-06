import CryptoKit
import Foundation

@MainActor
final class SelectiveRemoteCloudDeviceTrustCoordinator {
    enum Phase { case firstDevice, publishPending, pairingRequired, pinMissing
        case custodian, paired, certified, revoked }

    struct Inspection {
        let phase: Phase
        let snapshot: SelectiveRemoteCloudDeviceTrustSnapshot
        let pin: SelectiveRemoteDeviceTrustPin?
        let root: P256.Signing.PrivateKey?
        let identity: SelectiveRemoteTeamDeviceIdentity
        let rekeyCommitted: Bool
    }

    struct PendingApproval: @unchecked Sendable {
        let requestID: UUID
        let deviceID: UUID
        let keyVersion: Int
        let publicKey: SelectiveRemoteTeamDevicePublicKey
        let challengeID: UUID
        let challenge: SelectiveRemoteDevicePossessionChallenge
        let privateKey: P256.KeyAgreement.PrivateKey
    }

    let endpoint: URL
    let client: SelectiveRemoteCloudAPIClient
    let accountID: UUID
    let deviceID: UUID
    private let local: any SelectiveRemoteDeviceTrustLocalStoring
    private let identities: SelectiveRemoteTeamDeviceIdentityManager

    init(endpoint: URL, client: SelectiveRemoteCloudAPIClient, accountID: UUID, deviceID: UUID,
         local: any SelectiveRemoteDeviceTrustLocalStoring = SelectiveRemoteDeviceTrustLocalStore(),
         identities: SelectiveRemoteTeamDeviceIdentityManager = SelectiveRemoteTeamDeviceIdentityManager()) {
        self.endpoint = endpoint
        self.client = client
        self.accountID = accountID
        self.deviceID = deviceID
        self.local = local
        self.identities = identities
    }

    static func keyFingerprint(_ key: SelectiveRemoteTeamDevicePublicKey) -> String {
        let text = "selective-remote/team-device-key/v1\0\(key.x)\0\(key.y)"
        let hex = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(4, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: "-")
    }

    private func rootKey(_ value: String) throws -> P256.Signing.PublicKey {
        guard let raw = Data(selectiveRemoteBase64URL: value, expectedLength: 65),
              raw.first == 4 else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return try P256.Signing.PublicKey(x963Representation: raw)
    }

    func inspect() async throws -> Inspection {
        let identity = try await identities.identity(endpoint: endpoint, deviceID: deviceID)
        let snapshot = try await client.deviceTrustSnapshot(endpoint: endpoint)
        let pin = try local.pin(endpoint: endpoint, accountID: accountID)
        let root = try local.root(endpoint: endpoint, accountID: accountID)
        if snapshot.state == "UNINITIALIZED" {
            if pin != nil && root == nil { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
            return Inspection(phase: root == nil ? .firstDevice : .publishPending,
                snapshot: snapshot, pin: pin, root: root, identity: identity,
                rekeyCommitted: false)
        }
        guard snapshot.state == "ROOT_PUBLISHED", let rootText = snapshot.rootPublicKey,
              let directory = snapshot.checkpoint, let certificates = snapshot.certificates,
              let serverFingerprint = snapshot.rootFingerprint
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        let publicRoot = try rootKey(rootText)
        guard serverFingerprint == SelectiveRemoteDeviceTrustV1.fingerprint(publicRoot),
              root == nil || root?.publicKey.x963Representation == publicRoot.x963Representation
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        guard let pin else {
            return Inspection(phase: root == nil ? .pairingRequired : .pinMissing,
                snapshot: snapshot, pin: nil, root: root, identity: identity,
                rekeyCommitted: false)
        }
        let version = try SelectiveRemoteDeviceTrustV1.verifyDirectory(
            rootPublicKey: publicRoot, directory: directory, pin: pin)
        let next = SelectiveRemoteDeviceTrustPin(accountID: accountID,
            rootFingerprint: pin.rootFingerprint, highWater: version,
            checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        if version > pin.highWater { try local.advance(endpoint: endpoint, expected: pin, next: next) }
        let isCustodian = snapshot.custodianDeviceID == deviceID && root != nil
        let entry = directory.payload.entries.first { $0.deviceID == deviceID }
        let certificate = certificates.first { $0.payload.deviceID == deviceID
            && $0.payload.keyVersion == entry?.keyVersion }
        var activeIdentity = identity
        var committed = false
        if let certificate {
            let verified = try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: publicRoot,
                certificate: certificate, directory: directory, pin: next,
                expectedDeviceID: deviceID)
            if verified.publicKey != identity.publicKey {
                guard let pending = try local.pendingRekey(endpoint: endpoint,
                    accountID: accountID, deviceID: deviceID),
                      pending.publicKey == verified.publicKey
                else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
                activeIdentity = try local.commitPendingRekey(endpoint: endpoint,
                    accountID: accountID, deviceID: deviceID,
                    expectedPublicKey: verified.publicKey)
                committed = true
            }
        } else if isCustodian { throw SelectiveRemoteDeviceTrustError.inactiveDevice }
        let phase: Phase = isCustodian ? .custodian :
            certificate != nil ? .certified :
            certificates.contains(where: { $0.payload.deviceID == deviceID }) ? .revoked : .paired
        return Inspection(phase: phase, snapshot: snapshot, pin: next, root: root,
            identity: activeIdentity, rekeyCommitted: committed)
    }

    func bootstrap(password: String) async throws -> Inspection {
        guard !password.isEmpty else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        let current = try await inspect()
        guard current.phase == .firstDevice || current.phase == .publishPending
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let root = try local.saveRootIfAbsent(current.root ?? P256.Signing.PrivateKey(),
            endpoint: endpoint, accountID: accountID)
        var bundle = try local.bootstrapBundle(endpoint: endpoint, accountID: accountID)
        if bundle == nil {
            let certificate = try SelectiveRemoteDeviceTrustV1.issueCertificate(root: root,
                accountID: accountID, deviceID: deviceID,
                publicKey: current.identity.publicKey, keyVersion: 1,
                issuedAt: Int(Date().timeIntervalSince1970), serial: UUID())
            let checkpoint = try SelectiveRemoteDeviceTrustV1.signDirectory(root: root,
                accountID: accountID, version: 1, certificates: [certificate])
            bundle = try local.saveBootstrapBundleIfAbsent(.init(
                rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL,
                certificate: certificate, checkpoint: checkpoint),
                endpoint: endpoint, accountID: accountID)
        }
        guard let bundle else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        let pin = SelectiveRemoteDeviceTrustPin(accountID: accountID,
            rootFingerprint: SelectiveRemoteDeviceTrustV1.fingerprint(root.publicKey),
            highWater: 1,
            checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(bundle.checkpoint))
        _ = try local.savePinIfAbsent(pin, endpoint: endpoint)
        try await client.deviceTrustPublishRoot(endpoint: endpoint, password: password,
            rootPublicKey: bundle.rootPublicKey, certificate: bundle.certificate,
            checkpoint: bundle.checkpoint)
        let checked = try await inspect()
        guard checked.phase == .custodian, checked.pin?.checkpointDigest == pin.checkpointDigest
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        return checked
    }

    func pair(fingerprint: String, checkpointDigest: String) async throws -> Inspection {
        let current = try await inspect()
        guard current.phase == .pairingRequired,
              let rootText = current.snapshot.rootPublicKey,
              let directory = current.snapshot.checkpoint
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let root = try rootKey(rootText)
        let actual = SelectiveRemoteDeviceTrustV1.fingerprint(root)
        let digest = try SelectiveRemoteDeviceTrustV1.directoryDigest(directory)
        guard actual == fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              digest == checkpointDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let pin = SelectiveRemoteDeviceTrustPin(accountID: accountID,
            rootFingerprint: actual, highWater: directory.payload.version,
            checkpointDigest: digest)
        _ = try SelectiveRemoteDeviceTrustV1.verifyDirectory(rootPublicKey: root,
            directory: directory, pin: pin)
        _ = try local.savePinIfAbsent(pin, endpoint: endpoint)
        return try await inspect()
    }

    func requestApproval() async throws {
        let current = try await inspect()
        guard current.phase == .paired else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        _ = try await client.deviceTrustCreateRequest(endpoint: endpoint,
            publicKey: current.identity.publicKey, keyVersion: 1)
    }

    func requestRekey() async throws {
        let current = try await inspect()
        guard current.phase == .certified || current.phase == .custodian,
              let version = current.snapshot.checkpoint?.payload.entries
                .first(where: { $0.deviceID == deviceID })?.keyVersion
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let generated = try SelectiveRemoteTeamDeviceIdentity(deviceID: deviceID,
            privateKeyRepresentation: P256.KeyAgreement.PrivateKey().rawRepresentation)
        let pending = try local.savePendingRekeyIfAbsent(generated,
            endpoint: endpoint, accountID: accountID)
        _ = try await client.deviceTrustCreateRequest(endpoint: endpoint,
            publicKey: pending.publicKey, keyVersion: version + 1)
    }

    func answer(_ request: SelectiveRemoteCloudDeviceTrustRequest) async throws {
        guard request.deviceID == deviceID, request.status == "challenged",
              let challengeID = request.challengeID
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        let current = try await inspect()
        let identity = request.keyVersion > 1
            ? try local.pendingRekey(endpoint: endpoint, accountID: accountID,
                deviceID: deviceID) : current.identity
        guard let identity, request.publicKey == identity.publicKey
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let relayed = try await client.deviceTrustChallenge(endpoint: endpoint,
            requestID: request.requestID, challengeID: challengeID)
        guard relayed.state == "offered", relayed.challenge.accountID == accountID,
              relayed.challenge.requestID == request.requestID,
              relayed.challenge.deviceID == deviceID,
              relayed.challenge.publicKey == identity.publicKey
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        let proof = try SelectiveRemoteDeviceTrustV1.answerPossessionChallenge(
            relayed.challenge, devicePrivateKey: identity.privateKey,
            devicePublicKey: identity.publicKey)
        try await client.deviceTrustAnswerChallenge(endpoint: endpoint,
            requestID: request.requestID, challengeID: challengeID, proof: proof)
    }

    func startApproval(_ request: SelectiveRemoteCloudDeviceTrustRequest,
        confirmedFingerprint: String) async throws -> PendingApproval {
        let current = try await inspect()
        guard current.phase == .custodian,
              ["pending", "challenged", "answered"].contains(request.status),
              request.challengeState == nil,
              request.deviceID != deviceID || request.keyVersion > 1,
              Self.keyFingerprint(request.publicKey) == confirmedFingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let made = try SelectiveRemoteDeviceTrustV1.createPossessionChallenge(
            accountID: accountID, requestID: request.requestID,
            deviceID: request.deviceID, publicKey: request.publicKey,
            issuedAt: Int(Date().timeIntervalSince1970))
        let challengeID = try await client.deviceTrustStartChallenge(endpoint: endpoint,
            requestID: request.requestID, challenge: made.challenge)
        return PendingApproval(requestID: request.requestID, deviceID: request.deviceID,
            keyVersion: request.keyVersion, publicKey: request.publicKey,
            challengeID: challengeID, challenge: made.challenge,
            privateKey: made.privateKey)
    }

    private func activeCertificates(_ current: Inspection, except: UUID)
        throws -> [SelectiveRemoteSignedDeviceCertificate] {
        guard let entries = current.snapshot.checkpoint?.payload.entries,
              let certificates = current.snapshot.certificates
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return try entries.filter { $0.deviceID != except }.map { entry in
            guard let certificate = try certificates.first(where: { candidate in
                guard candidate.payload.deviceID == entry.deviceID,
                      candidate.payload.keyVersion == entry.keyVersion else { return false }
                return try SelectiveRemoteDeviceTrustV1.certificateDigest(candidate)
                    == entry.certificateDigest
            }) else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
            return certificate
        }
    }

    func finishApproval(_ pending: PendingApproval) async throws {
        let current = try await inspect()
        guard current.phase == .custodian, let root = current.root,
              let version = current.snapshot.checkpoint?.payload.version
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let relayed = try await client.deviceTrustChallenge(endpoint: endpoint,
            requestID: pending.requestID, challengeID: pending.challengeID)
        guard relayed.state == "answered", relayed.challenge == pending.challenge,
              let proof = relayed.proof
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        _ = try SelectiveRemoteDeviceTrustV1.verifyPossessionAnswer(pending.challenge,
            proof: proof, approverPrivateKey: pending.privateKey,
            now: Int(Date().timeIntervalSince1970))
        let request = try await client.deviceTrustRequests(endpoint: endpoint)
            .first { $0.requestID == pending.requestID }
        guard request?.status == "answered", request?.deviceID == pending.deviceID,
              request?.publicKey == pending.publicKey,
              request?.keyVersion == pending.keyVersion
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        let certificate = try SelectiveRemoteDeviceTrustV1.issueCertificate(root: root,
            accountID: accountID, deviceID: pending.deviceID,
            publicKey: pending.publicKey, keyVersion: pending.keyVersion,
            issuedAt: Int(Date().timeIntervalSince1970), serial: UUID())
        let certificates = try activeCertificates(current, except: pending.deviceID) + [certificate]
        let checkpoint = try SelectiveRemoteDeviceTrustV1.signDirectory(root: root,
            accountID: accountID, version: version + 1, certificates: certificates)
        try await client.deviceTrustApprove(endpoint: endpoint, requestID: pending.requestID,
            challengeID: pending.challengeID,
            rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL,
            certificate: certificate, checkpoint: checkpoint)
        _ = try await inspect()
    }

    func reject(_ requestID: UUID) async throws {
        let current = try await inspect()
        guard current.phase == .custodian else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        try await client.deviceTrustReject(endpoint: endpoint, requestID: requestID)
    }

    func revoke(_ target: UUID) async throws {
        let current = try await inspect()
        guard current.phase == .custodian, target != deviceID,
              let root = current.root, let directory = current.snapshot.checkpoint,
              directory.payload.entries.contains(where: { $0.deviceID == target })
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let remaining = try activeCertificates(current, except: target)
        let checkpoint = try SelectiveRemoteDeviceTrustV1.signDirectory(root: root,
            accountID: accountID, version: directory.payload.version + 1,
            certificates: remaining)
        try await client.deviceTrustRevoke(endpoint: endpoint, deviceID: target,
            rootPublicKey: root.publicKey.x963Representation.selectiveRemoteBase64URL,
            checkpoint: checkpoint)
        _ = try await inspect()
    }
}
