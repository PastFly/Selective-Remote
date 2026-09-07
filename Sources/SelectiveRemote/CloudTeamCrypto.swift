import CryptoKit
import Foundation

enum SelectiveRemoteTeamCryptoError: Error, Equatable {
    case invalidPublicKey
    case invalidPrivateKey
    case invalidGeneration
    case invalidEnvelope
    case wrapperDeviceMismatch
    case wrapperContextMismatch
    case keyUnwrapFailed
    case payloadContentHashMismatch
    case payloadEncryptionFailed
    case payloadDecryptionFailed
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

    init(_ key: P256.KeyAgreement.PublicKey) throws {
        let representation = key.x963Representation
        guard representation.count == 65, representation.first == 0x04 else {
            throw SelectiveRemoteTeamCryptoError.invalidPublicKey
        }
        try self.init(
            x: Data(representation[1..<33]).selectiveRemoteBase64URL,
            y: Data(representation[33..<65]).selectiveRemoteBase64URL
        )
    }

    var keyAgreementPublicKey: P256.KeyAgreement.PublicKey {
        get throws {
            guard let xData = Data(selectiveRemoteBase64URL: x, expectedLength: 32),
                  let yData = Data(selectiveRemoteBase64URL: y, expectedLength: 32)
            else { throw SelectiveRemoteTeamCryptoError.invalidPublicKey }
            return try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + xData + yData)
        }
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

struct SelectiveRemoteTeamVaultKeyWrapper: Codable, Equatable, Sendable {
    let membershipID: UUID
    let membershipEpoch: Int
    let deviceID: UUID
    let wrapperVersion: Int
    let ephemeralPublicKey: SelectiveRemoteTeamDevicePublicKey
    let ciphertext: String
    let nonce: String
    let authTag: String
    let contextHash: String

    enum CodingKeys: String, CodingKey {
        case membershipID, membershipEpoch, deviceID, wrapperVersion
        case ephemeralPublicKey, ciphertext, nonce, authTag, contextHash
    }

    init(
        membershipID: UUID,
        membershipEpoch: Int,
        deviceID: UUID,
        wrapperVersion: Int = 1,
        ephemeralPublicKey: SelectiveRemoteTeamDevicePublicKey,
        ciphertext: String,
        nonce: String,
        authTag: String,
        contextHash: String
    ) throws {
        guard membershipID.isSelectiveRemoteCloudUUID,
              deviceID.isSelectiveRemoteCloudUUID,
              membershipEpoch > 0,
              wrapperVersion == 1,
              Data(selectiveRemoteBase64URL: ciphertext, expectedLength: 32) != nil,
              Data(selectiveRemoteBase64URL: nonce, expectedLength: 12) != nil,
              Data(selectiveRemoteBase64URL: authTag, expectedLength: 16) != nil,
              Data(selectiveRemoteBase64URL: contextHash, expectedLength: 32) != nil
        else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        self.membershipID = membershipID
        self.membershipEpoch = membershipEpoch
        self.deviceID = deviceID
        self.wrapperVersion = wrapperVersion
        self.ephemeralPublicKey = ephemeralPublicKey
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.authTag = authTag
        self.contextHash = contextHash
    }

    init(from decoder: any Decoder) throws {
        let actualKeys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
            .allKeys.map(\.stringValue).sorted()
        guard actualKeys == [
            "authTag", "ciphertext", "contextHash", "deviceID", "ephemeralPublicKey",
            "membershipEpoch", "membershipID", "nonce", "wrapperVersion"
        ] else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let membershipID = UUID(uuidString: try values.decode(String.self, forKey: .membershipID)),
              let deviceID = UUID(uuidString: try values.decode(String.self, forKey: .deviceID))
        else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        try self.init(
            membershipID: membershipID,
            membershipEpoch: try values.decode(Int.self, forKey: .membershipEpoch),
            deviceID: deviceID,
            wrapperVersion: try values.decode(Int.self, forKey: .wrapperVersion),
            ephemeralPublicKey: try values.decode(SelectiveRemoteTeamDevicePublicKey.self, forKey: .ephemeralPublicKey),
            ciphertext: try values.decode(String.self, forKey: .ciphertext),
            nonce: try values.decode(String.self, forKey: .nonce),
            authTag: try values.decode(String.self, forKey: .authTag),
            contextHash: try values.decode(String.self, forKey: .contextHash)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(membershipID.canonicalCloudString, forKey: .membershipID)
        try values.encode(membershipEpoch, forKey: .membershipEpoch)
        try values.encode(deviceID.canonicalCloudString, forKey: .deviceID)
        try values.encode(wrapperVersion, forKey: .wrapperVersion)
        try values.encode(ephemeralPublicKey, forKey: .ephemeralPublicKey)
        try values.encode(ciphertext, forKey: .ciphertext)
        try values.encode(nonce, forKey: .nonce)
        try values.encode(authTag, forKey: .authTag)
        try values.encode(contextHash, forKey: .contextHash)
    }
}

struct SelectiveRemoteTeamVaultPayloadEnvelope: Codable, Equatable, Sendable {
    let baseRevision: Int
    let keyGeneration: Int
    let envelopeVersion: Int
    let ciphertext: String
    let nonce: String
    let authTag: String
    let contentHash: String

    enum CodingKeys: String, CodingKey {
        case baseRevision, keyGeneration, envelopeVersion
        case ciphertext, nonce, authTag, contentHash
    }

    init(
        baseRevision: Int,
        keyGeneration: Int,
        envelopeVersion: Int = 1,
        ciphertext: String,
        nonce: String,
        authTag: String,
        contentHash: String
    ) throws {
        guard baseRevision >= 0,
              keyGeneration > 0,
              envelopeVersion == 1,
              let ciphertextData = Data(selectiveRemoteBase64URL: ciphertext),
              ciphertextData.count <= 24 * 1024 * 1024,
              Data(selectiveRemoteBase64URL: nonce, expectedLength: 12) != nil,
              Data(selectiveRemoteBase64URL: authTag, expectedLength: 16) != nil,
              Data(selectiveRemoteBase64URL: contentHash, expectedLength: 32) != nil
        else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        self.baseRevision = baseRevision
        self.keyGeneration = keyGeneration
        self.envelopeVersion = envelopeVersion
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.authTag = authTag
        self.contentHash = contentHash
    }

    init(from decoder: any Decoder) throws {
        let actualKeys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
            .allKeys.map(\.stringValue).sorted()
        guard actualKeys == [
            "authTag", "baseRevision", "ciphertext", "contentHash",
            "envelopeVersion", "keyGeneration", "nonce"
        ] else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baseRevision: try values.decode(Int.self, forKey: .baseRevision),
            keyGeneration: try values.decode(Int.self, forKey: .keyGeneration),
            envelopeVersion: try values.decode(Int.self, forKey: .envelopeVersion),
            ciphertext: try values.decode(String.self, forKey: .ciphertext),
            nonce: try values.decode(String.self, forKey: .nonce),
            authTag: try values.decode(String.self, forKey: .authTag),
            contentHash: try values.decode(String.self, forKey: .contentHash)
        )
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
        let digest = Array(SHA256.hash(data: Data(canonical.utf8)))
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

    static func encryptPayload(
        _ payload: Data,
        vaultKey: Data,
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int,
        baseRevision: Int,
        nonce: Data? = nil
    ) throws -> SelectiveRemoteTeamVaultPayloadEnvelope {
        guard vaultKey.count == 32,
              payload.count <= 24 * 1024 * 1024,
              baseRevision >= 0
        else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        let context = try payloadContext(
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: keyGeneration
        )
        let nonceData = nonce ?? Data(AES.GCM.Nonce())
        guard nonceData.count == 12 else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        do {
            let sealed = try AES.GCM.seal(
                payload,
                using: SymmetricKey(data: vaultKey),
                nonce: AES.GCM.Nonce(data: nonceData),
                authenticating: context
            )
            let ciphertext = sealed.ciphertext.selectiveRemoteBase64URL
            let authTag = sealed.tag.selectiveRemoteBase64URL
            return try SelectiveRemoteTeamVaultPayloadEnvelope(
                baseRevision: baseRevision,
                keyGeneration: keyGeneration,
                ciphertext: ciphertext,
                nonce: nonceData.selectiveRemoteBase64URL,
                authTag: authTag,
                contentHash: payloadContentHash(
                    teamID: teamID,
                    vaultID: vaultID,
                    keyGeneration: keyGeneration,
                    nonce: nonceData.selectiveRemoteBase64URL,
                    ciphertext: ciphertext,
                    authTag: authTag
                )
            )
        } catch let error as SelectiveRemoteTeamCryptoError {
            throw error
        } catch {
            throw SelectiveRemoteTeamCryptoError.payloadEncryptionFailed
        }
    }

    static func decryptPayload(
        _ envelope: SelectiveRemoteTeamVaultPayloadEnvelope,
        vaultKey: Data,
        teamID: UUID,
        vaultID: UUID
    ) throws -> Data {
        guard vaultKey.count == 32,
              let nonce = Data(selectiveRemoteBase64URL: envelope.nonce, expectedLength: 12),
              let ciphertext = Data(selectiveRemoteBase64URL: envelope.ciphertext),
              ciphertext.count <= 24 * 1024 * 1024,
              let tag = Data(selectiveRemoteBase64URL: envelope.authTag, expectedLength: 16)
        else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        let expectedHash = try payloadContentHash(
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: envelope.keyGeneration,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            authTag: envelope.authTag
        )
        guard envelope.contentHash == expectedHash else {
            throw SelectiveRemoteTeamCryptoError.payloadContentHashMismatch
        }
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: vaultKey),
                authenticating: payloadContext(
                    teamID: teamID,
                    vaultID: vaultID,
                    keyGeneration: envelope.keyGeneration
                )
            )
        } catch let error as SelectiveRemoteTeamCryptoError {
            throw error
        } catch {
            throw SelectiveRemoteTeamCryptoError.payloadDecryptionFailed
        }
    }

    static func wrapVaultKey(
        _ vaultKey: Data,
        for recipientPublicKey: SelectiveRemoteTeamDevicePublicKey,
        context: SelectiveRemoteTeamWrapperContext,
        ephemeralPrivateKeyRepresentation: Data? = nil,
        nonce: Data? = nil
    ) throws -> SelectiveRemoteTeamVaultKeyWrapper {
        guard vaultKey.count == 32 else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        let ephemeral: P256.KeyAgreement.PrivateKey
        do {
            if let ephemeralPrivateKeyRepresentation {
                ephemeral = try P256.KeyAgreement.PrivateKey(
                    rawRepresentation: ephemeralPrivateKeyRepresentation
                )
            } else {
                ephemeral = P256.KeyAgreement.PrivateKey()
            }
        } catch {
            throw SelectiveRemoteTeamCryptoError.invalidPrivateKey
        }
        let recipientKey = try recipientPublicKey.keyAgreementPublicKey
        let contextData = wrapperContext(context)
        let wrappingKey = try deriveWrapperKey(
            privateKey: ephemeral,
            publicKey: recipientKey,
            context: contextData
        )
        let nonceData = nonce ?? Data(AES.GCM.Nonce())
        guard nonceData.count == 12 else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        do {
            let sealed = try AES.GCM.seal(
                vaultKey,
                using: wrappingKey,
                nonce: AES.GCM.Nonce(data: nonceData),
                authenticating: contextData
            )
            return try SelectiveRemoteTeamVaultKeyWrapper(
                membershipID: context.membershipID,
                membershipEpoch: context.membershipEpoch,
                deviceID: context.deviceID,
                ephemeralPublicKey: SelectiveRemoteTeamDevicePublicKey(ephemeral.publicKey),
                ciphertext: sealed.ciphertext.selectiveRemoteBase64URL,
                nonce: nonceData.selectiveRemoteBase64URL,
                authTag: sealed.tag.selectiveRemoteBase64URL,
                contextHash: wrapperContextHash(context)
            )
        } catch let error as SelectiveRemoteTeamCryptoError {
            throw error
        } catch {
            throw SelectiveRemoteTeamCryptoError.invalidEnvelope
        }
    }

    static func unwrapVaultKey(
        _ wrapper: SelectiveRemoteTeamVaultKeyWrapper,
        with identity: SelectiveRemoteTeamDeviceIdentity,
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int
    ) throws -> Data {
        guard wrapper.deviceID == identity.deviceID else {
            throw SelectiveRemoteTeamCryptoError.wrapperDeviceMismatch
        }
        let context = try SelectiveRemoteTeamWrapperContext(
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: keyGeneration,
            membershipID: wrapper.membershipID,
            membershipEpoch: wrapper.membershipEpoch,
            deviceID: wrapper.deviceID
        )
        guard wrapper.contextHash == wrapperContextHash(context) else {
            throw SelectiveRemoteTeamCryptoError.wrapperContextMismatch
        }
        guard let nonce = Data(selectiveRemoteBase64URL: wrapper.nonce, expectedLength: 12),
              let ciphertext = Data(selectiveRemoteBase64URL: wrapper.ciphertext, expectedLength: 32),
              let tag = Data(selectiveRemoteBase64URL: wrapper.authTag, expectedLength: 16)
        else { throw SelectiveRemoteTeamCryptoError.invalidEnvelope }
        do {
            let wrappingKey = try deriveWrapperKey(
                privateKey: identity.privateKey,
                publicKey: wrapper.ephemeralPublicKey.keyAgreementPublicKey,
                context: wrapperContext(context)
            )
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let rawKey = try AES.GCM.open(sealed, using: wrappingKey, authenticating: wrapperContext(context))
            guard rawKey.count == 32 else { throw SelectiveRemoteTeamCryptoError.keyUnwrapFailed }
            return rawKey
        } catch let error as SelectiveRemoteTeamCryptoError {
            throw error
        } catch {
            throw SelectiveRemoteTeamCryptoError.keyUnwrapFailed
        }
    }

    private static func deriveWrapperKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        publicKey: P256.KeyAgreement.PublicKey,
        context: Data
    ) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: context)),
            sharedInfo: Data(wrapperKeyInfo.utf8),
            outputByteCount: 32
        )
    }
}

extension UUID {
    var canonicalCloudString: String { uuidString.lowercased() }

    var isSelectiveRemoteCloudUUID: Bool {
        let value = Array(canonicalCloudString)
        guard value.count == 36 else { return false }
        return "12345678".contains(value[14])
            && "89ab".contains(value[19])
    }
}

struct SelectiveRemoteAnyCodingKey: CodingKey {
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

extension Data {
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
