import CryptoKit
import Foundation

protocol SelectiveRemoteDeviceTrustPinStore {
    func pin(endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustPin?
    func advance(endpoint: URL, expected: SelectiveRemoteDeviceTrustPin,
                 next: SelectiveRemoteDeviceTrustPin) throws
}

struct SelectiveRemoteDeviceTrustBootstrapBundle: Codable, Equatable {
    let rootPublicKey: String
    let certificate: SelectiveRemoteSignedDeviceCertificate
    let checkpoint: SelectiveRemoteSignedDeviceDirectory
}

protocol SelectiveRemoteDeviceTrustLocalStoring: SelectiveRemoteDeviceTrustPinStore {
    func root(endpoint: URL, accountID: UUID) throws -> P256.Signing.PrivateKey?
    func saveRootIfAbsent(_ root: P256.Signing.PrivateKey, endpoint: URL, accountID: UUID) throws -> P256.Signing.PrivateKey
    func bootstrapBundle(endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustBootstrapBundle?
    func saveBootstrapBundleIfAbsent(_ bundle: SelectiveRemoteDeviceTrustBootstrapBundle, endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustBootstrapBundle
    func pendingRekey(endpoint: URL, accountID: UUID, deviceID: UUID) throws -> SelectiveRemoteTeamDeviceIdentity?
    func savePendingRekeyIfAbsent(_ identity: SelectiveRemoteTeamDeviceIdentity, endpoint: URL, accountID: UUID) throws -> SelectiveRemoteTeamDeviceIdentity
    func commitPendingRekey(endpoint: URL, accountID: UUID, deviceID: UUID, expectedPublicKey: SelectiveRemoteTeamDevicePublicKey) throws -> SelectiveRemoteTeamDeviceIdentity
    func savePinIfAbsent(_ pin: SelectiveRemoteDeviceTrustPin, endpoint: URL) throws -> SelectiveRemoteDeviceTrustPin
}

struct SelectiveRemoteDeviceTrustLocalStore: SelectiveRemoteDeviceTrustLocalStoring {
    private let envelopeStore = SelectiveRemoteCloudSecureEnvelopeStore()

    func root(endpoint: URL, accountID: UUID) throws -> P256.Signing.PrivateKey? {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        guard let raw = try envelopeStore.envelope(for: endpoint)?
            .deviceTrustRootKeys[accountID.canonicalCloudString] else { return nil }
        guard raw.count == 32, let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return key
    }

    func saveRootIfAbsent(_ root: P256.Signing.PrivateKey,
                          endpoint: URL, accountID: UUID) throws -> P256.Signing.PrivateKey {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        guard accountID.isSelectiveRemoteCloudUUID else {
            throw SelectiveRemoteDeviceTrustError.invalidRecord
        }
        var committed = root.rawRepresentation
        try envelopeStore.update(for: endpoint) { envelope in
            let key = accountID.canonicalCloudString
            if let existing = envelope.deviceTrustRootKeys[key] {
                guard existing == committed else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
                committed = existing
            }
            else { envelope.deviceTrustRootKeys[key] = committed }
        }
        guard let result = try? P256.Signing.PrivateKey(rawRepresentation: committed)
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return result
    }

    func pin(endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustPin? {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        return try envelopeStore.envelope(for: endpoint)?
            .deviceTrustPins[accountID.canonicalCloudString]
    }

    func bootstrapBundle(endpoint: URL, accountID: UUID) throws
        -> SelectiveRemoteDeviceTrustBootstrapBundle? {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        return try envelopeStore.envelope(for: endpoint)?
            .deviceTrustBootstrapBundles[accountID.canonicalCloudString]
    }

    func saveBootstrapBundleIfAbsent(_ bundle: SelectiveRemoteDeviceTrustBootstrapBundle,
        endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustBootstrapBundle {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        var committed = bundle
        try envelopeStore.update(for: endpoint) { envelope in
            let key = accountID.canonicalCloudString
            if let existing = envelope.deviceTrustBootstrapBundles[key] {
                guard existing == bundle else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
                committed = existing
            } else { envelope.deviceTrustBootstrapBundles[key] = bundle }
        }
        return committed
    }

    private func pendingKey(accountID: UUID, deviceID: UUID) -> String {
        "\(accountID.canonicalCloudString)|\(deviceID.canonicalCloudString)"
    }

    func pendingRekey(endpoint: URL, accountID: UUID, deviceID: UUID) throws
        -> SelectiveRemoteTeamDeviceIdentity? {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        guard let data = try envelopeStore.envelope(for: endpoint)?
            .deviceTrustPendingRekeys[pendingKey(accountID: accountID, deviceID: deviceID)]
        else { return nil }
        return try SelectiveRemoteTeamDeviceIdentity(deviceID: deviceID,
            privateKeyRepresentation: data)
    }

    func savePendingRekeyIfAbsent(_ identity: SelectiveRemoteTeamDeviceIdentity,
        endpoint: URL, accountID: UUID) throws -> SelectiveRemoteTeamDeviceIdentity {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        let key = pendingKey(accountID: accountID, deviceID: identity.deviceID)
        var committed = identity.privateKey.rawRepresentation
        try envelopeStore.update(for: endpoint) { envelope in
            if let existing = envelope.deviceTrustPendingRekeys[key] {
                committed = existing
            } else { envelope.deviceTrustPendingRekeys[key] = committed }
        }
        return try SelectiveRemoteTeamDeviceIdentity(deviceID: identity.deviceID,
            privateKeyRepresentation: committed)
    }

    func commitPendingRekey(endpoint: URL, accountID: UUID, deviceID: UUID,
        expectedPublicKey: SelectiveRemoteTeamDevicePublicKey) throws
        -> SelectiveRemoteTeamDeviceIdentity {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        let key = pendingKey(accountID: accountID, deviceID: deviceID)
        var committed: Data?
        try envelopeStore.update(for: endpoint) { envelope in
            guard let data = envelope.deviceTrustPendingRekeys[key],
                  let pending = try? SelectiveRemoteTeamDeviceIdentity(
                    deviceID: deviceID, privateKeyRepresentation: data),
                  pending.publicKey == expectedPublicKey
            else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
            envelope.teamDevicePrivateKeys[deviceID.canonicalCloudString] = data
            envelope.deviceTrustPendingRekeys.removeValue(forKey: key)
            committed = data
        }
        guard let committed else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return try SelectiveRemoteTeamDeviceIdentity(deviceID: deviceID,
            privateKeyRepresentation: committed)
    }

    func savePinIfAbsent(_ pin: SelectiveRemoteDeviceTrustPin, endpoint: URL)
        throws -> SelectiveRemoteDeviceTrustPin {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        try validate(pin)
        var committed = pin
        try envelopeStore.update(for: endpoint) { envelope in
            let key = pin.accountID.canonicalCloudString
            if let existing = envelope.deviceTrustPins[key] {
                guard existing == pin else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
                committed = existing
            }
            else { envelope.deviceTrustPins[key] = pin }
        }
        return committed
    }

    func advance(endpoint: URL, expected: SelectiveRemoteDeviceTrustPin,
                 next: SelectiveRemoteDeviceTrustPin) throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized(endpoint.absoluteString)
        try validate(expected)
        try validate(next)
        guard expected.accountID == next.accountID,
              expected.rootFingerprint == next.rootFingerprint,
              next.highWater >= expected.highWater,
              next.highWater != expected.highWater ||
                next.checkpointDigest == expected.checkpointDigest
        else { throw SelectiveRemoteDeviceTrustError.staleDirectory }
        try envelopeStore.update(for: endpoint) { envelope in
            let key = expected.accountID.canonicalCloudString
            guard envelope.deviceTrustPins[key] == expected
            else { throw SelectiveRemoteDeviceTrustError.staleDirectory }
            envelope.deviceTrustPins[key] = next
        }
    }

    private func validate(_ pin: SelectiveRemoteDeviceTrustPin) throws {
        guard pin.accountID.isSelectiveRemoteCloudUUID,
              pin.rootFingerprint.count == 64,
              pin.rootFingerprint.allSatisfy({ $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }),
              pin.highWater > 0 && pin.highWater <= 9_007_199_254_740_991,
              Data(selectiveRemoteBase64URL: pin.checkpointDigest, expectedLength: 32) != nil
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
    }
}
