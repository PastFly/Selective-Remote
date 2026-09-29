import CryptoKit
import Foundation

protocol SelectiveRemoteDeviceTrustPinStore {
    func pin(endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustPin?
    func advance(endpoint: URL, expected: SelectiveRemoteDeviceTrustPin,
                 next: SelectiveRemoteDeviceTrustPin) throws
}

struct SelectiveRemoteDeviceTrustLocalStore: SelectiveRemoteDeviceTrustPinStore {
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
