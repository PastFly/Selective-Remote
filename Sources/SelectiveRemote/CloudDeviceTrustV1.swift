import CryptoKit
import Foundation

enum SelectiveRemoteDeviceTrustError: Error {
    case invalidRecord
    case invalidSignature
    case untrustedRoot
    case staleDirectory
    case inactiveDevice
}

private func deviceTrustKeys(_ decoder: any Decoder, _ expected: [String]) throws {
    let keys = try decoder.container(keyedBy: SelectiveRemoteAnyCodingKey.self)
        .allKeys.map(\.stringValue).sorted()
    guard keys == expected.sorted() else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
}

private func deviceTrustUUID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value), id.isSelectiveRemoteCloudUUID,
          id.canonicalCloudString == value else {
        throw SelectiveRemoteDeviceTrustError.invalidRecord
    }
    return id
}

struct SelectiveRemoteDeviceCertificatePayload: Codable, Equatable, Sendable {
    let accountID: UUID
    let deviceID: UUID
    let publicKey: SelectiveRemoteTeamDevicePublicKey
    let keyVersion: Int
    let issuerFingerprint: String
    let issuedAt: Int
    let serial: UUID

    private enum CodingKeys: String, CodingKey {
        case accountID, deviceID, publicKey, keyVersion, issuerFingerprint, issuedAt, serial
    }

    init(accountID: UUID, deviceID: UUID, publicKey: SelectiveRemoteTeamDevicePublicKey,
         keyVersion: Int, issuerFingerprint: String, issuedAt: Int, serial: UUID) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.publicKey = publicKey
        self.keyVersion = keyVersion
        self.issuerFingerprint = issuerFingerprint
        self.issuedAt = issuedAt
        self.serial = serial
    }

    init(from decoder: any Decoder) throws {
        try deviceTrustKeys(decoder, ["accountID", "deviceID", "publicKey", "keyVersion",
                                      "issuerFingerprint", "issuedAt", "serial"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try deviceTrustUUID(values.decode(String.self, forKey: .accountID))
        deviceID = try deviceTrustUUID(values.decode(String.self, forKey: .deviceID))
        publicKey = try values.decode(SelectiveRemoteTeamDevicePublicKey.self, forKey: .publicKey)
        keyVersion = try values.decode(Int.self, forKey: .keyVersion)
        issuerFingerprint = try values.decode(String.self, forKey: .issuerFingerprint)
        issuedAt = try values.decode(Int.self, forKey: .issuedAt)
        serial = try deviceTrustUUID(values.decode(String.self, forKey: .serial))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountID.canonicalCloudString, forKey: .accountID)
        try values.encode(deviceID.canonicalCloudString, forKey: .deviceID)
        try values.encode(publicKey, forKey: .publicKey)
        try values.encode(keyVersion, forKey: .keyVersion)
        try values.encode(issuerFingerprint, forKey: .issuerFingerprint)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encode(serial.canonicalCloudString, forKey: .serial)
    }
}

struct SelectiveRemoteSignedDeviceCertificate: Codable, Equatable, Sendable {
    let payload: SelectiveRemoteDeviceCertificatePayload
    let signature: String

    private enum CodingKeys: String, CodingKey { case payload, signature }
    init(payload: SelectiveRemoteDeviceCertificatePayload, signature: String) {
        self.payload = payload
        self.signature = signature
    }
    init(from decoder: any Decoder) throws {
        try deviceTrustKeys(decoder, ["payload", "signature"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        payload = try values.decode(SelectiveRemoteDeviceCertificatePayload.self, forKey: .payload)
        signature = try values.decode(String.self, forKey: .signature)
    }
}

struct SelectiveRemoteDeviceDirectoryEntry: Codable, Equatable, Sendable {
    let deviceID: UUID
    let keyVersion: Int
    let certificateDigest: String

    private enum CodingKeys: String, CodingKey { case deviceID, keyVersion, certificateDigest }
    init(deviceID: UUID, keyVersion: Int, certificateDigest: String) {
        self.deviceID = deviceID
        self.keyVersion = keyVersion
        self.certificateDigest = certificateDigest
    }
    init(from decoder: any Decoder) throws {
        try deviceTrustKeys(decoder, ["deviceID", "keyVersion", "certificateDigest"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try deviceTrustUUID(values.decode(String.self, forKey: .deviceID))
        keyVersion = try values.decode(Int.self, forKey: .keyVersion)
        certificateDigest = try values.decode(String.self, forKey: .certificateDigest)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(deviceID.canonicalCloudString, forKey: .deviceID)
        try values.encode(keyVersion, forKey: .keyVersion)
        try values.encode(certificateDigest, forKey: .certificateDigest)
    }
}

struct SelectiveRemoteDeviceDirectoryPayload: Codable, Equatable, Sendable {
    let accountID: UUID
    let version: Int
    let entries: [SelectiveRemoteDeviceDirectoryEntry]

    private enum CodingKeys: String, CodingKey { case accountID, version, entries }
    init(accountID: UUID, version: Int, entries: [SelectiveRemoteDeviceDirectoryEntry]) {
        self.accountID = accountID
        self.version = version
        self.entries = entries
    }
    init(from decoder: any Decoder) throws {
        try deviceTrustKeys(decoder, ["accountID", "version", "entries"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try deviceTrustUUID(values.decode(String.self, forKey: .accountID))
        version = try values.decode(Int.self, forKey: .version)
        entries = try values.decode([SelectiveRemoteDeviceDirectoryEntry].self, forKey: .entries)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountID.canonicalCloudString, forKey: .accountID)
        try values.encode(version, forKey: .version)
        try values.encode(entries, forKey: .entries)
    }
}

struct SelectiveRemoteSignedDeviceDirectory: Codable, Equatable, Sendable {
    let payload: SelectiveRemoteDeviceDirectoryPayload
    let signature: String

    private enum CodingKeys: String, CodingKey { case payload, signature }
    init(payload: SelectiveRemoteDeviceDirectoryPayload, signature: String) {
        self.payload = payload
        self.signature = signature
    }
    init(from decoder: any Decoder) throws {
        try deviceTrustKeys(decoder, ["payload", "signature"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        payload = try values.decode(SelectiveRemoteDeviceDirectoryPayload.self, forKey: .payload)
        signature = try values.decode(String.self, forKey: .signature)
    }
}

struct SelectiveRemoteDeviceTrustPin: Codable, Equatable, Sendable {
    let accountID: UUID
    let rootFingerprint: String
    let highWater: Int
    let checkpointDigest: String
}

enum SelectiveRemoteDeviceTrustV1 {
    private static let certificateDomain = "selective-remote/device-certificate/v1\0"
    private static let directoryDomain = "selective-remote/device-directory/v1\0"
    private static let maxVersion = 9_007_199_254_740_991

    static func fingerprint(_ key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.x963Representation).map { String(format: "%02x", $0) }.joined()
    }

    private static func valid(_ id: UUID) -> Bool { id.isSelectiveRemoteCloudUUID }
    private static func valid(_ version: Int) -> Bool { version > 0 && version <= maxVersion }
    private static func canonical(_ id: UUID) -> String { id.canonicalCloudString }

    private static func encode(_ domain: String, _ fields: [Data]) throws -> Data {
        var data = Data(domain.utf8) + Data([0, 1])
        for field in fields {
            guard field.count <= Int(UInt16.max) else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
            data.append(UInt8(field.count >> 8))
            data.append(UInt8(field.count & 255))
            data.append(field)
        }
        return data
    }

    private static func fields(_ values: [String]) -> [Data] { values.map { Data($0.utf8) } }

    static func certificateBytes(_ value: SelectiveRemoteDeviceCertificatePayload) throws -> Data {
        guard valid(value.accountID), valid(value.deviceID), valid(value.serial),
              valid(value.keyVersion), valid(value.issuedAt),
              value.issuerFingerprint.count == 64,
              value.issuerFingerprint.allSatisfy({ $0.isASCII && ($0.isNumber || "abcdef".contains($0)) })
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        let publicKey = try value.publicKey.keyAgreementPublicKey.x963Representation
        return try encode(certificateDomain, fields([canonical(value.accountID), canonical(value.deviceID)])
            + [publicKey] + fields([String(value.keyVersion), value.issuerFingerprint,
                                    String(value.issuedAt), canonical(value.serial)]))
    }

    static func directoryBytes(_ value: SelectiveRemoteDeviceDirectoryPayload) throws -> Data {
        guard valid(value.accountID), valid(value.version), value.entries.count <= 4096
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        var items = fields([canonical(value.accountID), String(value.version), String(value.entries.count)])
        var previous = ""
        for entry in value.entries {
            let current = canonical(entry.deviceID)
            guard valid(entry.deviceID), valid(entry.keyVersion), current > previous,
                  let digest = Data(selectiveRemoteBase64URL: entry.certificateDigest, expectedLength: 32)
            else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
            previous = current
            items += fields([current, String(entry.keyVersion)]) + [digest]
        }
        let encoded = try encode(directoryDomain, items)
        guard encoded.count <= 65_535 else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return encoded
    }

    private static func digest(_ certificate: SelectiveRemoteSignedDeviceCertificate) throws -> String {
        guard let signature = Data(selectiveRemoteBase64URL: certificate.signature, expectedLength: 64)
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return Data(SHA256.hash(data: try certificateBytes(certificate.payload) + signature))
            .selectiveRemoteBase64URL
    }

    static func directoryDigest(_ directory: SelectiveRemoteSignedDeviceDirectory) throws -> String {
        guard let signature = Data(selectiveRemoteBase64URL: directory.signature, expectedLength: 64)
        else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
        return Data(SHA256.hash(data: try directoryBytes(directory.payload) + signature))
            .selectiveRemoteBase64URL
    }

    private static func verify(_ signature: String, message: Data, key: P256.Signing.PublicKey) throws {
        guard let raw = Data(selectiveRemoteBase64URL: signature, expectedLength: 64),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              key.isValidSignature(parsed, for: message)
        else { throw SelectiveRemoteDeviceTrustError.invalidSignature }
    }

    static func issueCertificate(root: P256.Signing.PrivateKey, accountID: UUID,
                                 deviceID: UUID, publicKey: SelectiveRemoteTeamDevicePublicKey,
                                 keyVersion: Int, issuedAt: Int, serial: UUID) throws
        -> SelectiveRemoteSignedDeviceCertificate {
        let payload = SelectiveRemoteDeviceCertificatePayload(accountID: accountID,
            deviceID: deviceID, publicKey: publicKey, keyVersion: keyVersion,
            issuerFingerprint: fingerprint(root.publicKey), issuedAt: issuedAt, serial: serial)
        let signature = try root.signature(for: certificateBytes(payload))
        return .init(payload: payload, signature: signature.rawRepresentation.selectiveRemoteBase64URL)
    }

    static func signDirectory(root: P256.Signing.PrivateKey, accountID: UUID, version: Int,
                              certificates: [SelectiveRemoteSignedDeviceCertificate]) throws
        -> SelectiveRemoteSignedDeviceDirectory {
        let entries = try certificates.map { certificate -> SelectiveRemoteDeviceDirectoryEntry in
            guard certificate.payload.accountID == accountID,
                  certificate.payload.issuerFingerprint == fingerprint(root.publicKey)
            else { throw SelectiveRemoteDeviceTrustError.invalidRecord }
            try verify(certificate.signature, message: certificateBytes(certificate.payload),
                       key: root.publicKey)
            return .init(deviceID: certificate.payload.deviceID,
                         keyVersion: certificate.payload.keyVersion,
                         certificateDigest: try digest(certificate))
        }.sorted { canonical($0.deviceID) < canonical($1.deviceID) }
        let payload = SelectiveRemoteDeviceDirectoryPayload(accountID: accountID,
                                                             version: version, entries: entries)
        let signature = try root.signature(for: directoryBytes(payload))
        return .init(payload: payload, signature: signature.rawRepresentation.selectiveRemoteBase64URL)
    }

    static func verify(rootPublicKey: P256.Signing.PublicKey,
                       certificate: SelectiveRemoteSignedDeviceCertificate,
                       directory: SelectiveRemoteSignedDeviceDirectory,
                       pin: SelectiveRemoteDeviceTrustPin,
                       expectedDeviceID: UUID) throws -> (publicKey: SelectiveRemoteTeamDevicePublicKey,
                                                           highWater: Int) {
        guard pin.rootFingerprint == fingerprint(rootPublicKey), pin.highWater > 0,
              pin.accountID == certificate.payload.accountID,
              pin.accountID == directory.payload.accountID,
              expectedDeviceID == certificate.payload.deviceID
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        guard directory.payload.version >= pin.highWater
        else { throw SelectiveRemoteDeviceTrustError.staleDirectory }
        guard certificate.payload.issuerFingerprint == pin.rootFingerprint
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        try verify(certificate.signature, message: certificateBytes(certificate.payload),
                   key: rootPublicKey)
        try verify(directory.signature, message: directoryBytes(directory.payload),
                   key: rootPublicKey)
        if directory.payload.version == pin.highWater,
           try directoryDigest(directory) != pin.checkpointDigest {
            throw SelectiveRemoteDeviceTrustError.staleDirectory
        }
        guard let entry = directory.payload.entries.first(where: { $0.deviceID == expectedDeviceID }),
              entry.keyVersion == certificate.payload.keyVersion,
              entry.certificateDigest == (try digest(certificate))
        else { throw SelectiveRemoteDeviceTrustError.inactiveDevice }
        return (certificate.payload.publicKey, directory.payload.version)
    }

    static func wrapForVerifiedDevice(_ cek: Data, context: SelectiveRemoteResourceWrapperContext,
                                      endpoint: URL, pinStore: any SelectiveRemoteDeviceTrustPinStore,
                                      rootPublicKey: P256.Signing.PublicKey,
                                      certificate: SelectiveRemoteSignedDeviceCertificate,
                                      directory: SelectiveRemoteSignedDeviceDirectory)
        throws -> (wrapper: SelectiveRemoteResourceKeyWrapper, highWater: Int) {
        guard let pin = try pinStore.pin(endpoint: endpoint, accountID: certificate.payload.accountID)
        else { throw SelectiveRemoteDeviceTrustError.untrustedRoot }
        let verified = try verify(rootPublicKey: rootPublicKey, certificate: certificate,
                                  directory: directory, pin: pin, expectedDeviceID: context.deviceID)
        let next = SelectiveRemoteDeviceTrustPin(accountID: pin.accountID,
            rootFingerprint: pin.rootFingerprint, highWater: verified.highWater,
            checkpointDigest: try directoryDigest(directory))
        try pinStore.advance(endpoint: endpoint, expected: pin, next: next)
        return (try SelectiveRemoteResourceCryptoV2.wrap(cek, for: verified.publicKey,
                                                         context: context), verified.highWater)
    }
}
