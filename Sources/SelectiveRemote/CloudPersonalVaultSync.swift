import CommonCrypto
import CryptoKit
import Foundation
import Security

enum SelectiveRemotePersonalVaultError: LocalizedError, Equatable {
    case invalidRecoveryPhrase
    case invalidEnvelope
    case cryptoFailure
    case emptyLocalVault
    case remoteVaultNotEmpty(Int)
    case uploadConflict(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRecoveryPhrase:
            UpdateLocalization.text(
                ru: "Recovery-фраза должна содержать от 16 до 1024 байт.",
                en: "The recovery phrase must contain between 16 and 1024 bytes."
            )
        case .invalidEnvelope, .cryptoFailure:
            UpdateLocalization.text(
                ru: "Не удалось безопасно зашифровать Personal Vault.",
                en: "Personal Vault could not be encrypted safely."
            )
        case .emptyLocalVault:
            UpdateLocalization.text(
                ru: "На этом Mac нет заполненных Hosts, Snippets или Forwarding для отправки.",
                en: "This Mac has no populated Hosts, Snippets or Forwarding records to upload."
            )
        case let .remoteVaultNotEmpty(revision):
            UpdateLocalization.text(
                ru: "Cloud Vault уже содержит ревизию \(revision). Автоматическая перезапись остановлена; сначала требуется безопасное объединение.",
                en: "Cloud Vault already contains revision \(revision). Automatic replacement was stopped; a safe merge is required first."
            )
        case let .uploadConflict(revision):
            UpdateLocalization.text(
                ru: "Cloud Vault изменился до ревизии \(revision). Локальные данные не перезаписаны.",
                en: "Cloud Vault changed to revision \(revision). Local data was not replaced."
            )
        }
    }
}

struct SelectiveRemotePersonalVaultWrappedKey: Codable, Equatable, Sendable {
    let algorithm: String
    let iterations: Int
    let salt: String
    let value: String

    init(salt: Data, value: Data) throws {
        guard salt.count == 16, value.count == 40 else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        algorithm = "PBKDF2-SHA256+A256KW"
        iterations = 600_000
        self.salt = salt.selectiveRemoteBase64URL
        self.value = value.selectiveRemoteBase64URL
    }
}

struct SelectiveRemotePersonalVaultEnvelope: Codable, Equatable, Sendable {
    let baseRevision: Int
    let envelopeVersion: Int
    let wrappedKey: SelectiveRemotePersonalVaultWrappedKey
    let ciphertext: String
    let nonce: String
    let authTag: String
    let contentHash: String

    init(
        baseRevision: Int,
        wrappedKey: SelectiveRemotePersonalVaultWrappedKey,
        ciphertext: Data,
        nonce: Data,
        authTag: Data
    ) throws {
        guard baseRevision >= 0,
              ciphertext.count <= 24 * 1024 * 1024,
              nonce.count == 12,
              authTag.count == 16
        else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
        self.baseRevision = baseRevision
        envelopeVersion = 1
        self.wrappedKey = wrappedKey
        self.ciphertext = ciphertext.selectiveRemoteBase64URL
        self.nonce = nonce.selectiveRemoteBase64URL
        self.authTag = authTag.selectiveRemoteBase64URL
        contentHash = Data(SHA256.hash(data: Data([1]) + nonce + ciphertext + authTag))
            .selectiveRemoteBase64URL
    }
}

struct SelectiveRemotePersonalVaultSetup: Equatable, Sendable {
    let envelope: SelectiveRemotePersonalVaultEnvelope
    let vaultKey: Data
}

struct SelectiveRemoteCloudPersonalVault: Equatable, Sendable {
    let id: UUID
    let revision: Int
    let envelope: SelectiveRemotePersonalVaultEnvelope?
    let updatedAt: String
}

struct SelectiveRemoteCloudPersonalVaultWriteResult: Equatable, Sendable {
    let conflict: Bool
    let revision: Int
}

struct SelectiveRemotePersonalVaultCredentialInput: Equatable, Sendable {
    let sourceID: UUID
    let kind: KeychainCredentialKind
    let title: String
    let username: String
    let secret: String
}

struct SelectiveRemotePersonalVaultSSHKeyInput: Equatable, Sendable {
    let record: SSHKeyRecord
    let privateKey: Data
    let publicKey: Data?
    let certificate: Data?
}

struct SelectiveRemotePersonalVaultExportSummary: Equatable, Sendable {
    let hosts: Int
    let credentials: Int
    let snippets: Int
    let forwarding: Int
    let sshKeys: Int

    var total: Int { hosts + credentials + snippets + forwarding + sshKeys }

    init(hosts: Int, credentials: Int, snippets: Int, forwarding: Int, sshKeys: Int = 0) {
        self.hosts = hosts
        self.credentials = credentials
        self.snippets = snippets
        self.forwarding = forwarding
        self.sshKeys = sshKeys
    }
}

struct SelectiveRemotePersonalVaultExport: Equatable, Sendable {
    let document: SelectiveRemoteVaultDocument
    let summary: SelectiveRemotePersonalVaultExportSummary
}

enum SelectiveRemotePersonalVaultExporter {
    static func makeExport(
        profiles: [ConnectionProfile],
        credentials: [SelectiveRemotePersonalVaultCredentialInput],
        snippets: [TerminalCommandTemplate],
        forwarding: [IndependentPortForward],
        sshKeys: [SelectiveRemotePersonalVaultSSHKeyInput] = [],
        deviceID: UUID,
        now: Date = Date(),
        allowEmpty: Bool = false
    ) throws -> SelectiveRemotePersonalVaultExport {
        let timestamp = timestamp(now)
        let version = try SelectiveRemoteVaultVersion([deviceID: 1])
        let populatedProfiles = profiles.filter { profile in
            !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !profile.serialDevicePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var records: [SelectiveRemoteVaultRecord] = try populatedProfiles.map { profile in
            let address = profile.connectionType == .serial ? profile.serialDevicePath : profile.host
            return try SelectiveRemoteVaultRecord(
                id: profile.id,
                type: .host,
                version: version,
                modifiedAt: timestamp,
                data: .object([
                    "title": .string(boundedTitle(profile.friendlyName, fallback: address)),
                    "address": .string(address),
                    "username": .string(profile.username),
                    "connectionType": .string(profile.connectionType.rawValue),
                    "profile": .string(try encoded(profile))
                ])
            )
        }
        records += try credentials.map { credential in
            try SelectiveRemoteVaultRecord(
                id: derivedID(sourceID: credential.sourceID, discriminator: "credential:\(credential.kind.rawValue)"),
                type: .credential,
                version: version,
                modifiedAt: timestamp,
                data: .object([
                    "title": .string(boundedTitle(credential.title, fallback: credential.kind.rawValue)),
                    "username": .string(credential.username),
                    "secret": .string(credential.secret),
                    "kind": .string(credential.kind.rawValue),
                    "sourceID": .string(credential.sourceID.canonicalCloudString)
                ])
            )
        }
        records += try snippets.map { snippet in
            try SelectiveRemoteVaultRecord(
                id: snippet.id,
                type: .snippet,
                version: version,
                modifiedAt: timestamp,
                data: .object([
                    "title": .string(boundedTitle(snippet.title, fallback: "Snippet")),
                    "body": .string(snippet.command),
                    "category": .string(snippet.category),
                    "template": .string(try encoded(snippet))
                ])
            )
        }
        records += try forwarding.map { item in
            let destination = item.rule.kind == .dynamic
                ? "\(item.rule.bindAddress):\(item.rule.sourcePort)"
                : "\(item.rule.destinationHost):\(item.rule.destinationPort)"
            return try SelectiveRemoteVaultRecord(
                id: item.id,
                type: .forwarding,
                version: version,
                modifiedAt: timestamp,
                data: .object([
                    "title": .string(boundedTitle(item.rule.displayName, fallback: "Forwarding")),
                    "destination": .string(destination),
                    "configuration": .string(try encoded(item)),
                    "kind": .string(item.rule.kind.rawValue)
                ])
            )
        }
        records += try sshKeys.map { key in
            try SelectiveRemoteVaultRecord(
                id: key.record.id,
                type: .sshKey,
                version: version,
                modifiedAt: timestamp,
                data: .object([
                    "title": .string(boundedTitle(key.record.name, fallback: "SSH Key")),
                    "record": .string(try encoded(key.record)),
                    "privateKey": .string(key.privateKey.selectiveRemoteBase64URL),
                    "publicKey": key.publicKey.map { .string($0.selectiveRemoteBase64URL) } ?? .null,
                    "certificate": key.certificate.map { .string($0.selectiveRemoteBase64URL) } ?? .null
                ])
            )
        }
        let document = try SelectiveRemoteVaultDocument(records: records)
        let summary = SelectiveRemotePersonalVaultExportSummary(
            hosts: populatedProfiles.count,
            credentials: credentials.count,
            snippets: snippets.count,
            forwarding: forwarding.count,
            sshKeys: sshKeys.count
        )
        guard allowEmpty || summary.total > 0 else {
            throw SelectiveRemotePersonalVaultError.emptyLocalVault
        }
        return .init(document: document, summary: summary)
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value).selectiveRemoteBase64URL
    }

    private static func boundedTitle(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = normalized.isEmpty ? fallback : normalized
        return String(selected.prefix(120))
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private static func derivedID(sourceID: UUID, discriminator: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("selective-remote/personal-vault/v1\0\(sourceID.canonicalCloudString)\0\(discriminator)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum SelectiveRemotePersonalVaultCrypto {
    static let recoveryIterations: UInt32 = 600_000
    private static let additionalData = Data("selective-remote:vault-envelope:v1".utf8)

    static func accountPassphrase(_ password: String) throws -> String {
        let normalized = password.precomposedStringWithCanonicalMapping
        guard (12...1_024).contains(normalized.utf8.count) else {
            throw SelectiveRemotePersonalVaultError.invalidRecoveryPhrase
        }
        return "selective-remote:account-password:v1:\(normalized)"
    }

    static func unwrapVaultKey(
        _ wrappedKey: SelectiveRemotePersonalVaultWrappedKey,
        passphrase: String
    ) throws -> Data {
        guard wrappedKey.algorithm == "PBKDF2-SHA256+A256KW",
              wrappedKey.iterations == Int(recoveryIterations),
              let salt = Data(selectiveRemoteBase64URL: wrappedKey.salt, expectedLength: 16),
              let value = Data(selectiveRemoteBase64URL: wrappedKey.value, expectedLength: 40)
        else { throw SelectiveRemotePersonalVaultError.invalidEnvelope }
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        let keyEncryptionKey = try deriveKey(password: Data(normalized.utf8), salt: salt)
        return try unwrapRFC3394(value, keyEncryptionKey: keyEncryptionKey)
    }

    static func seal(
        _ document: SelectiveRemoteVaultDocument,
        recoveryPhrase: String,
        baseRevision: Int,
        vaultKey: Data? = nil,
        salt: Data? = nil,
        nonce: Data? = nil
    ) throws -> SelectiveRemotePersonalVaultEnvelope {
        let normalized = recoveryPhrase.precomposedStringWithCanonicalMapping
        let phrase = Data(normalized.utf8)
        guard (16...1_024).contains(phrase.count), baseRevision >= 0 else {
            throw SelectiveRemotePersonalVaultError.invalidRecoveryPhrase
        }
        let rawVaultKey = try vaultKey ?? randomData(count: 32)
        let rawSalt = try salt ?? randomData(count: 16)
        let rawNonce = try nonce ?? randomData(count: 12)
        guard rawVaultKey.count == 32, rawSalt.count == 16, rawNonce.count == 12 else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let recoveryKey = try deriveKey(password: phrase, salt: rawSalt)
        let wrapped = try wrapRFC3394(rawVaultKey, keyEncryptionKey: recoveryKey)
        do {
            let sealed = try AES.GCM.seal(
                document.encoded(),
                using: SymmetricKey(data: rawVaultKey),
                nonce: AES.GCM.Nonce(data: rawNonce),
                authenticating: additionalData
            )
            return try .init(
                baseRevision: baseRevision,
                wrappedKey: .init(salt: rawSalt, value: wrapped),
                ciphertext: sealed.ciphertext,
                nonce: rawNonce,
                authTag: sealed.tag
            )
        } catch let error as SelectiveRemotePersonalVaultError {
            throw error
        } catch {
            throw SelectiveRemotePersonalVaultError.cryptoFailure
        }
    }

    static func createSetup(
        _ document: SelectiveRemoteVaultDocument,
        recoveryPhrase: String,
        baseRevision: Int
    ) throws -> SelectiveRemotePersonalVaultSetup {
        let key = try randomData(count: 32)
        return try .init(
            envelope: seal(
                document,
                recoveryPhrase: recoveryPhrase,
                baseRevision: baseRevision,
                vaultKey: key
            ),
            vaultKey: key
        )
    }

    static func reseal(
        _ document: SelectiveRemoteVaultDocument,
        vaultKey: Data,
        wrappedKey: SelectiveRemotePersonalVaultWrappedKey,
        baseRevision: Int,
        nonce: Data? = nil
    ) throws -> SelectiveRemotePersonalVaultEnvelope {
        let rawNonce = try nonce ?? randomData(count: 12)
        guard vaultKey.count == 32, rawNonce.count == 12, baseRevision > 0 else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        do {
            let sealed = try AES.GCM.seal(
                document.encoded(),
                using: SymmetricKey(data: vaultKey),
                nonce: AES.GCM.Nonce(data: rawNonce),
                authenticating: additionalData
            )
            return try .init(
                baseRevision: baseRevision,
                wrappedKey: wrappedKey,
                ciphertext: sealed.ciphertext,
                nonce: rawNonce,
                authTag: sealed.tag
            )
        } catch let error as SelectiveRemotePersonalVaultError {
            throw error
        } catch {
            throw SelectiveRemotePersonalVaultError.cryptoFailure
        }
    }

    static func open(
        _ envelope: SelectiveRemotePersonalVaultEnvelope,
        vaultKey: Data
    ) throws -> SelectiveRemoteVaultDocument {
        guard vaultKey.count == 32,
              let nonce = Data(selectiveRemoteBase64URL: envelope.nonce, expectedLength: 12),
              let ciphertext = Data(selectiveRemoteBase64URL: envelope.ciphertext),
              let authTag = Data(selectiveRemoteBase64URL: envelope.authTag, expectedLength: 16)
        else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: authTag
            )
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: vaultKey),
                authenticating: additionalData
            )
            return try SelectiveRemoteVaultDocument.decode(plaintext)
        } catch let error as SelectiveRemotePersonalVaultError {
            throw error
        } catch {
            throw SelectiveRemotePersonalVaultError.cryptoFailure
        }
    }

    static func wrapRFC3394(_ value: Data, keyEncryptionKey: Data) throws -> Data {
        guard keyEncryptionKey.count == 32, value.count >= 16, value.count.isMultiple(of: 8) else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let blockCount = value.count / 8
        var accumulator = Data(repeating: 0xa6, count: 8)
        var blocks = stride(from: 0, to: value.count, by: 8).map { offset in
            Data(value[offset..<offset + 8])
        }
        for round in 0..<6 {
            for index in 0..<blockCount {
                let encrypted = try encryptAESBlock(accumulator + blocks[index], key: keyEncryptionKey)
                var nextAccumulator = Data(encrypted.prefix(8))
                var counter = UInt64(blockCount * round + index + 1).bigEndian
                withUnsafeBytes(of: &counter) { counterBytes in
                    for offset in 0..<8 { nextAccumulator[offset] ^= counterBytes[offset] }
                }
                accumulator = nextAccumulator
                blocks[index] = Data(encrypted.suffix(8))
            }
        }
        return blocks.reduce(into: accumulator) { $0.append($1) }
    }

    static func unwrapRFC3394(_ value: Data, keyEncryptionKey: Data) throws -> Data {
        guard keyEncryptionKey.count == 32, value.count >= 24, value.count.isMultiple(of: 8) else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        let blockCount = value.count / 8 - 1
        var accumulator = Data(value.prefix(8))
        var blocks = stride(from: 8, to: value.count, by: 8).map { offset in
            Data(value[offset..<offset + 8])
        }
        for round in stride(from: 5, through: 0, by: -1) {
            for index in stride(from: blockCount - 1, through: 0, by: -1) {
                var counter = UInt64(blockCount * round + index + 1).bigEndian
                var masked = accumulator
                withUnsafeBytes(of: &counter) { counterBytes in
                    for offset in 0..<8 { masked[offset] ^= counterBytes[offset] }
                }
                let decrypted = try decryptAESBlock(masked + blocks[index], key: keyEncryptionKey)
                accumulator = Data(decrypted.prefix(8))
                blocks[index] = Data(decrypted.suffix(8))
            }
        }
        guard accumulator == Data(repeating: 0xa6, count: 8) else {
            throw SelectiveRemotePersonalVaultError.invalidRecoveryPhrase
        }
        return blocks.reduce(into: Data()) { $0.append($1) }
    }

    private static func deriveKey(password: Data, salt: Data) throws -> Data {
        var derived = Data(count: 32)
        let outputLength = derived.count
        let status = derived.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        recoveryIterations,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SelectiveRemotePersonalVaultError.cryptoFailure }
        return derived
    }

    private static func encryptAESBlock(_ block: Data, key: Data) throws -> Data {
        guard block.count == kCCBlockSizeAES128, key.count == kCCKeySizeAES256 else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        var output = Data(count: kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            block.withUnsafeBytes { blockBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        blockBytes.baseAddress,
                        block.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == kCCBlockSizeAES128 else {
            throw SelectiveRemotePersonalVaultError.cryptoFailure
        }
        return output
    }

    private static func decryptAESBlock(_ block: Data, key: Data) throws -> Data {
        guard block.count == kCCBlockSizeAES128, key.count == kCCKeySizeAES256 else {
            throw SelectiveRemotePersonalVaultError.invalidEnvelope
        }
        var output = Data(count: kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            block.withUnsafeBytes { blockBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil, blockBytes.baseAddress, block.count,
                        outputBytes.baseAddress, outputCapacity, &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == kCCBlockSizeAES128 else {
            throw SelectiveRemotePersonalVaultError.cryptoFailure
        }
        return output
    }

    private static func randomData(count: Int) throws -> Data {
        var value = Data(count: count)
        let status = value.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw SelectiveRemotePersonalVaultError.cryptoFailure }
        return value
    }
}

extension SelectiveRemoteCloudAPIClient {
    func personalVault(endpoint: URL) async throws -> SelectiveRemoteCloudPersonalVault {
        let (data, response) = try await authorizedResponse(endpoint: endpoint, path: "v1/vault")
        guard (200..<300).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [
                "id", "revision", "envelopeVersion", "wrappedKey", "ciphertext",
                "nonce", "authTag", "contentHash", "updatedAt"
              ],
              let idText = object["id"] as? String,
              let id = UUID(uuidString: idText),
              id.isSelectiveRemoteCloudUUID,
              let revision = object["revision"] as? Int,
              revision >= 0,
              let updatedAt = object["updatedAt"] as? String,
              !updatedAt.isEmpty
        else {
            if !(200..<300).contains(response.statusCode) {
                throw SelectiveRemoteCloudError.serviceError(response.statusCode, nil)
            }
            throw SelectiveRemoteCloudError.invalidResponse
        }
        if revision == 0 {
            let emptyPayloadKeys = ["wrappedKey", "ciphertext", "nonce", "authTag", "contentHash"]
            let emptyEnvelopeVersion = object["envelopeVersion"] is NSNull
                || object["envelopeVersion"] as? Int == 1
            guard emptyEnvelopeVersion,
                  emptyPayloadKeys.allSatisfy({ object[$0] is NSNull })
            else {
                throw SelectiveRemoteCloudError.invalidResponse
            }
            return .init(id: id, revision: 0, envelope: nil, updatedAt: updatedAt)
        }
        do {
            let decoder = JSONDecoder()
            guard object["envelopeVersion"] as? Int == 1,
                  let wrappedObject = object["wrappedKey"] as? [String: Any],
                  Set(wrappedObject.keys) == ["algorithm", "iterations", "salt", "value"]
            else { throw SelectiveRemoteCloudError.invalidResponse }
            let wrappedData = try JSONSerialization.data(withJSONObject: wrappedObject)
            let wrapped = try decoder.decode(SelectiveRemotePersonalVaultWrappedKey.self, from: wrappedData)
            guard wrapped.algorithm == "PBKDF2-SHA256+A256KW", wrapped.iterations == 600_000,
                  Data(selectiveRemoteBase64URL: wrapped.salt, expectedLength: 16) != nil,
                  Data(selectiveRemoteBase64URL: wrapped.value, expectedLength: 40) != nil,
                  let ciphertext = Data(selectiveRemoteBase64URL: object["ciphertext"] as? String ?? ""),
                  ciphertext.count <= 24 * 1024 * 1024,
                  let nonce = Data(selectiveRemoteBase64URL: object["nonce"] as? String ?? "", expectedLength: 12),
                  let authTag = Data(selectiveRemoteBase64URL: object["authTag"] as? String ?? "", expectedLength: 16),
                  Data(selectiveRemoteBase64URL: object["contentHash"] as? String ?? "", expectedLength: 32) != nil
            else { throw SelectiveRemoteCloudError.invalidResponse }
            let envelope = try SelectiveRemotePersonalVaultEnvelope(
                baseRevision: revision - 1,
                wrappedKey: wrapped,
                ciphertext: ciphertext,
                nonce: nonce,
                authTag: authTag
            )
            guard envelope.contentHash == object["contentHash"] as? String else {
                throw SelectiveRemoteCloudError.invalidResponse
            }
            return .init(id: id, revision: revision, envelope: envelope, updatedAt: updatedAt)
        } catch let error as SelectiveRemoteCloudError {
            throw error
        } catch {
            throw SelectiveRemoteCloudError.invalidResponse
        }
    }

    func putPersonalVault(
        endpoint: URL,
        envelope: SelectiveRemotePersonalVaultEnvelope
    ) async throws -> SelectiveRemoteCloudPersonalVaultWriteResult {
        let body = try JSONEncoder().encode(envelope)
        let (data, response) = try await authorizedResponse(
            endpoint: endpoint,
            path: "v1/vault",
            method: "PUT",
            body: body
        )
        guard response.statusCode == 200 || response.statusCode == 409,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["conflict", "revision"],
              let conflict = object["conflict"] as? Bool,
              let revision = object["revision"] as? Int,
              revision >= 0,
              conflict == (response.statusCode == 409)
        else {
            if !(200..<300).contains(response.statusCode), response.statusCode != 409 {
                throw SelectiveRemoteCloudError.serviceError(response.statusCode, nil)
            }
            throw SelectiveRemoteCloudError.invalidResponse
        }
        return .init(conflict: conflict, revision: revision)
    }
}
