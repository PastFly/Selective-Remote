import CryptoKit
import Foundation

enum SelectiveRemoteTeamCryptoError: Error, Equatable {
    case invalidPublicKey
    case invalidGeneration
    case invalidEnvelope
}

struct SelectiveRemoteTeamDevicePublicKey: Codable, Equatable, Sendable {
    let kty: String
    let crv: String
    let x: String
    let y: String
    let ext: Bool
    let keyOps: [String]

    enum CodingKeys: String, CodingKey {
        case kty, crv, x, y, ext
        case keyOps = "key_ops"
    }

    init(x: String, y: String) throws {
        guard let xData = Data(selectiveRemoteBase64URL: x, expectedLength: 32),
              let yData = Data(selectiveRemoteBase64URL: y, expectedLength: 32)
        else { throw SelectiveRemoteTeamCryptoError.invalidPublicKey }
        let representation = Data([0x04]) + xData + yData
        guard (try? P256.KeyAgreement.PublicKey(x963Representation: representation)) != nil else {
            throw SelectiveRemoteTeamCryptoError.invalidPublicKey
        }
        self.kty = "EC"
        self.crv = "P-256"
        self.x = x
        self.y = y
        self.ext = true
        self.keyOps = []
    }

    init(from decoder: any Decoder) throws {
        let actualKeys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
            .allKeys.map(\.stringValue).sorted()
        guard actualKeys == ["crv", "ext", "key_ops", "kty", "x", "y"] else {
            throw SelectiveRemoteTeamCryptoError.invalidPublicKey
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kty = try values.decode(String.self, forKey: .kty)
        let crv = try values.decode(String.self, forKey: .crv)
        let x = try values.decode(String.self, forKey: .x)
        let y = try values.decode(String.self, forKey: .y)
        let ext = try values.decode(Bool.self, forKey: .ext)
        let keyOps = try values.decode([String].self, forKey: .keyOps)
        guard kty == "EC", crv == "P-256", ext, keyOps.isEmpty else {
            throw SelectiveRemoteTeamCryptoError.invalidPublicKey
        }
        try self.init(x: x, y: y)
    }
}

struct SelectiveRemoteTeamWrapperContext: Equatable, Sendable {
    let teamID: UUID
    let vaultID: UUID
    let keyGeneration: Int
    let membershipID: UUID
    let membershipEpoch: Int
    let deviceID: UUID

    init(
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int,
        membershipID: UUID,
        membershipEpoch: Int,
        deviceID: UUID
    ) throws {
        guard teamID.isSelectiveRemoteCloudUUID,
              vaultID.isSelectiveRemoteCloudUUID,
              membershipID.isSelectiveRemoteCloudUUID,
              deviceID.isSelectiveRemoteCloudUUID,
              keyGeneration > 0,
              membershipEpoch > 0
        else {
            throw SelectiveRemoteTeamCryptoError.invalidGeneration
        }
        self.teamID = teamID
        self.vaultID = vaultID
        self.keyGeneration = keyGeneration
        self.membershipID = membershipID
        self.membershipEpoch = membershipEpoch
        self.deviceID = deviceID
    }
}

enum SelectiveRemoteTeamVaultCrypto {
    static let wrapperContextLabel = "selective-remote/team-vault-wrapper/v1"
    static let wrapperKeyInfo = "selective-remote/team-vault-wrapper-key/v1"
    static let payloadContextLabel = "selective-remote/team-vault-payload/v1"
    static let envelopeVersion: UInt8 = 1

    static func deviceFingerprint(_ key: SelectiveRemoteTeamDevicePublicKey) -> String {
        let canonical = "selective-remote/team-device-key/v1\0\(key.x)\0\(key.y)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return stride(from: 0, to: digest.count, by: 2).map { offset in
            digest[offset..<min(offset + 2, digest.count)].map { String(format: "%02x", $0) }.joined()
        }.joined(separator: "-")
    }

    static func wrapperContext(_ value: SelectiveRemoteTeamWrapperContext) -> Data {
        Data([
            wrapperContextLabel,
            value.teamID.canonicalCloudString,
            value.vaultID.canonicalCloudString,
            String(value.keyGeneration),
            value.membershipID.canonicalCloudString,
            String(value.membershipEpoch),
            value.deviceID.canonicalCloudString
        ].joined(separator: "\0").utf8)
    }

    static func wrapperContextHash(_ value: SelectiveRemoteTeamWrapperContext) -> String {
        Data(SHA256.hash(data: wrapperContext(value))).selectiveRemoteBase64URL
    }

    static func payloadContext(teamID: UUID, vaultID: UUID, keyGeneration: Int) throws -> Data {
        guard teamID.isSelectiveRemoteCloudUUID,
              vaultID.isSelectiveRemoteCloudUUID,
              keyGeneration > 0
        else { throw SelectiveRemoteTeamCryptoError.invalidGeneration }
        return Data([
            payloadContextLabel,
            teamID.canonicalCloudString,
            vaultID.canonicalCloudString,
            String(keyGeneration)
        ].joined(separator: "\0").utf8)
    }

    static func payloadContentHash(
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int,
        nonce: String,
        ciphertext: String,
        authTag: String
    ) throws -> String {
        guard let nonceData = Data(selectiveRemoteBase64URL: nonce, expectedLength: 12),
              let ciphertextData = Data(selectiveRemoteBase64URL: ciphertext),
              ciphertextData.count <= 24 * 1024 * 1024,
              let authTagData = Data(selectiveRemoteBase64URL: authTag, expectedLength: 16)
        else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        let context = try payloadContext(teamID: teamID, vaultID: vaultID, keyGeneration: keyGeneration)
        let bytes = Data([envelopeVersion]) + context + nonceData + ciphertextData + authTagData
        return Data(SHA256.hash(data: bytes)).selectiveRemoteBase64URL
    }
}

private extension UUID {
    var canonicalCloudString: String { uuidString.lowercased() }

    var isSelectiveRemoteCloudUUID: Bool {
        let value = Array(canonicalCloudString)
        guard value.count == 36 else { return false }
        return "12345678".contains(value[14])
            && "89ab".contains(value[19])
    }
}

private struct SelectiveRemoteAnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Data {
    init?(selectiveRemoteBase64URL value: String, expectedLength: Int? = nil) {
        guard !value.isEmpty,
              value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let decoded = Data(base64Encoded: base64),
              decoded.selectiveRemoteBase64URL == value,
              expectedLength.map({ decoded.count == $0 }) ?? true
        else { return nil }
        self = decoded
    }

    var selectiveRemoteBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
