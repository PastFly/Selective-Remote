import CryptoKit
import Foundation

enum SelectiveRemoteResourceCryptoV2Error: Error {
    case invalidContext
    case invalidKey
    case invalidEnvelope
    case contextMismatch
    case decryptionFailed
}

enum SelectiveRemoteResourcePart: String, Codable, Sendable {
    case general = "GENERAL"
    case metadata = "METADATA"
    case secret = "SECRET"
}

struct SelectiveRemoteResourceCipherContext: Codable, Equatable, Sendable {
    let teamID: UUID
    let vaultID: UUID
    let resourceID: UUID
    let part: SelectiveRemoteResourcePart
    let keyVersion: Int
    let policyVersion: Int
    let registryVersion: Int
    let resourceVersion: Int
    let manifestVersion: Int
}

struct SelectiveRemoteResourceWrapperContext: Codable, Equatable, Sendable {
    let teamID: UUID
    let vaultID: UUID
    let resourceID: UUID
    let part: SelectiveRemoteResourcePart
    let keyVersion: Int
    let membershipID: UUID
    let membershipEpoch: Int
    let deviceID: UUID
}

struct SelectiveRemoteResourceCipherEnvelope: Codable, Equatable, Sendable {
    let formatVersion: Int
    let algorithm: String
    let aadVersion: Int
    let context: SelectiveRemoteResourceCipherContext
    let nonce: String
    let ciphertext: String
    let authTag: String

    init(context: SelectiveRemoteResourceCipherContext, nonce: Data,
         ciphertext: Data, authTag: Data) {
        formatVersion = 2
        algorithm = "AES-256-GCM"
        aadVersion = 2
        self.context = context
        self.nonce = nonce.selectiveRemoteBase64URL
        self.ciphertext = ciphertext.selectiveRemoteBase64URL
        self.authTag = authTag.selectiveRemoteBase64URL
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self).allKeys.map(\.stringValue).sorted()
        guard keys == ["aadVersion", "algorithm", "authTag", "ciphertext", "context", "formatVersion", "nonce"]
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidEnvelope }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        algorithm = try values.decode(String.self, forKey: .algorithm)
        aadVersion = try values.decode(Int.self, forKey: .aadVersion)
        context = try values.decode(SelectiveRemoteResourceCipherContext.self, forKey: .context)
        nonce = try values.decode(String.self, forKey: .nonce)
        ciphertext = try values.decode(String.self, forKey: .ciphertext)
        authTag = try values.decode(String.self, forKey: .authTag)
        guard formatVersion == 2, algorithm == "AES-256-GCM", aadVersion == 2,
              Data(selectiveRemoteBase64URL: nonce, expectedLength: 12) != nil,
              (ciphertext.isEmpty || Data(selectiveRemoteBase64URL: ciphertext) != nil),
              Data(selectiveRemoteBase64URL: authTag, expectedLength: 16) != nil
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidEnvelope }
    }
}

struct SelectiveRemoteResourceKeyWrapper: Codable, Equatable, Sendable {
    let wrapperVersion: Int
    let algorithm: String
    let aadVersion: Int
    let context: SelectiveRemoteResourceWrapperContext
    let ephemeralPublicKey: SelectiveRemoteTeamDevicePublicKey
    let nonce: String
    let ciphertext: String
    let authTag: String

    init(context: SelectiveRemoteResourceWrapperContext,
         ephemeralPublicKey: SelectiveRemoteTeamDevicePublicKey,
         nonce: Data, ciphertext: Data, authTag: Data) {
        wrapperVersion = 2
        algorithm = "P256-ECDH-HKDF-SHA256-AES-256-GCM"
        aadVersion = 2
        self.context = context
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce.selectiveRemoteBase64URL
        self.ciphertext = ciphertext.selectiveRemoteBase64URL
        self.authTag = authTag.selectiveRemoteBase64URL
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self).allKeys.map(\.stringValue).sorted()
        guard keys == ["aadVersion", "algorithm", "authTag", "ciphertext", "context",
                       "ephemeralPublicKey", "nonce", "wrapperVersion"]
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidEnvelope }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        wrapperVersion = try values.decode(Int.self, forKey: .wrapperVersion)
        algorithm = try values.decode(String.self, forKey: .algorithm)
        aadVersion = try values.decode(Int.self, forKey: .aadVersion)
        context = try values.decode(SelectiveRemoteResourceWrapperContext.self, forKey: .context)
        ephemeralPublicKey = try values.decode(SelectiveRemoteTeamDevicePublicKey.self, forKey: .ephemeralPublicKey)
        nonce = try values.decode(String.self, forKey: .nonce)
        ciphertext = try values.decode(String.self, forKey: .ciphertext)
        authTag = try values.decode(String.self, forKey: .authTag)
        guard wrapperVersion == 2, algorithm == "P256-ECDH-HKDF-SHA256-AES-256-GCM",
              aadVersion == 2,
              Data(selectiveRemoteBase64URL: nonce, expectedLength: 12) != nil,
              Data(selectiveRemoteBase64URL: ciphertext, expectedLength: 32) != nil,
              Data(selectiveRemoteBase64URL: authTag, expectedLength: 16) != nil
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidEnvelope }
    }
}

enum SelectiveRemoteResourceCryptoV2 {
    static func generateCEK() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func ciphertextAAD(_ context: SelectiveRemoteResourceCipherContext) throws -> Data {
        try encodeAAD(domain: "selective-remote/resource-ciphertext/v2\0", values: [
            context.teamID.canonicalCloudString, context.vaultID.canonicalCloudString,
            context.resourceID.canonicalCloudString, context.part.rawValue,
            String(context.keyVersion), String(context.policyVersion),
            String(context.registryVersion), String(context.resourceVersion),
            String(context.manifestVersion)
        ], ids: [context.teamID, context.vaultID, context.resourceID],
        versions: [context.keyVersion, context.policyVersion, context.registryVersion,
                   context.resourceVersion, context.manifestVersion])
    }

    static func wrapperAAD(_ context: SelectiveRemoteResourceWrapperContext) throws -> Data {
        try encodeAAD(domain: "selective-remote/resource-wrapper/v2\0", values: [
            context.teamID.canonicalCloudString, context.vaultID.canonicalCloudString,
            context.resourceID.canonicalCloudString, context.part.rawValue,
            String(context.keyVersion), context.membershipID.canonicalCloudString,
            String(context.membershipEpoch), context.deviceID.canonicalCloudString
        ], ids: [context.teamID, context.vaultID, context.resourceID,
                context.membershipID, context.deviceID],
        versions: [context.keyVersion, context.membershipEpoch])
    }

    private static func encodeAAD(domain: String, values: [String], ids: [UUID],
                                  versions: [Int]) throws -> Data {
        guard ids.allSatisfy(\.isSelectiveRemoteCloudUUID),
              versions.allSatisfy({ $0 > 0 && $0 <= 9_007_199_254_740_991 })
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidContext }
        var data = Data(domain.utf8) + Data([0, 2])
        for value in values {
            let bytes = Data(value.utf8)
            guard bytes.count <= Int(UInt16.max) else { throw SelectiveRemoteResourceCryptoV2Error.invalidContext }
            data.append(UInt8(bytes.count >> 8))
            data.append(UInt8(bytes.count & 255))
            data.append(bytes)
        }
        return data
    }

    static func encrypt(_ plaintext: Data, cek: Data,
                        context: SelectiveRemoteResourceCipherContext) throws -> SelectiveRemoteResourceCipherEnvelope {
        guard cek.count == 32, plaintext.count <= 24 * 1024 * 1024
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidKey }
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: cek), nonce: nonce,
                                      authenticating: ciphertextAAD(context))
        return SelectiveRemoteResourceCipherEnvelope(context: context, nonce: Data(nonce),
            ciphertext: sealed.ciphertext, authTag: sealed.tag)
    }

    static func decrypt(_ envelope: SelectiveRemoteResourceCipherEnvelope, cek: Data,
                        context: SelectiveRemoteResourceCipherContext) throws -> Data {
        guard cek.count == 32, envelope.context == context,
              envelope.formatVersion == 2, envelope.algorithm == "AES-256-GCM", envelope.aadVersion == 2,
              let nonce = Data(selectiveRemoteBase64URL: envelope.nonce, expectedLength: 12),
              let body = envelope.ciphertext.isEmpty ? Data() : Data(selectiveRemoteBase64URL: envelope.ciphertext),
              body.count <= 24 * 1024 * 1024,
              let tag = Data(selectiveRemoteBase64URL: envelope.authTag, expectedLength: 16)
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidEnvelope }
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                               ciphertext: body, tag: tag)
            return try AES.GCM.open(sealed, using: SymmetricKey(data: cek),
                                    authenticating: ciphertextAAD(context))
        } catch { throw SelectiveRemoteResourceCryptoV2Error.decryptionFailed }
    }

    static func wrap(_ cek: Data, for recipient: SelectiveRemoteTeamDevicePublicKey,
                     context: SelectiveRemoteResourceWrapperContext) throws -> SelectiveRemoteResourceKeyWrapper {
        guard cek.count == 32 else { throw SelectiveRemoteResourceCryptoV2Error.invalidKey }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let aad = try wrapperAAD(context)
        let key = try derive(privateKey: ephemeral, publicKey: recipient.keyAgreementPublicKey, aad: aad)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(cek, using: key, nonce: nonce, authenticating: aad)
        return SelectiveRemoteResourceKeyWrapper(context: context,
            ephemeralPublicKey: try SelectiveRemoteTeamDevicePublicKey(ephemeral.publicKey),
            nonce: Data(nonce), ciphertext: sealed.ciphertext, authTag: sealed.tag)
    }

    static func unwrap(_ wrapper: SelectiveRemoteResourceKeyWrapper,
                       with identity: P256.KeyAgreement.PrivateKey,
                       context: SelectiveRemoteResourceWrapperContext) throws -> Data {
        guard wrapper.context == context, wrapper.wrapperVersion == 2,
              wrapper.algorithm == "P256-ECDH-HKDF-SHA256-AES-256-GCM", wrapper.aadVersion == 2,
              let nonce = Data(selectiveRemoteBase64URL: wrapper.nonce, expectedLength: 12),
              let body = Data(selectiveRemoteBase64URL: wrapper.ciphertext, expectedLength: 32),
              let tag = Data(selectiveRemoteBase64URL: wrapper.authTag, expectedLength: 16)
        else { throw SelectiveRemoteResourceCryptoV2Error.invalidEnvelope }
        do {
            let aad = try wrapperAAD(context)
            let key = try derive(privateKey: identity,
                publicKey: wrapper.ephemeralPublicKey.keyAgreementPublicKey, aad: aad)
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                               ciphertext: body, tag: tag)
            let value = try AES.GCM.open(sealed, using: key, authenticating: aad)
            guard value.count == 32 else { throw SelectiveRemoteResourceCryptoV2Error.invalidKey }
            return value
        } catch { throw SelectiveRemoteResourceCryptoV2Error.decryptionFailed }
    }

    private static func derive(privateKey: P256.KeyAgreement.PrivateKey,
                               publicKey: P256.KeyAgreement.PublicKey, aad: Data) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data(SHA256.hash(data: aad)),
            sharedInfo: Data("selective-remote/resource-wrapper-key/v2".utf8), outputByteCount: 32)
    }
}
