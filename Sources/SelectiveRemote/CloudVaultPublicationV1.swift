import CryptoKit
import Foundation

enum SelectiveRemotePublicationError: Error, Equatable {
    case invalid, signature, scope, wrapperProof, ciphertext, subject, incomplete, rollback, fork
}

struct SelectiveRemotePublicationHighWater: Codable, Equatable, Sendable {
    let sequence: Int
    let hash: String
}

extension SelectiveRemoteJSONValue {
    func publicationObject(_ keys: [String]? = nil) throws -> [String: Self] {
        guard case let .object(value) = self,
              keys == nil || Set(value.keys) == Set(keys!) else { throw SelectiveRemotePublicationError.invalid }
        return value
    }
    func publicationString() throws -> String {
        guard case let .string(value) = self else { throw SelectiveRemotePublicationError.invalid }; return value
    }
    func publicationInteger(min: Int = 1, max: Int = 9_007_199_254_740_991) throws -> Int {
        guard case let .number(value) = self, value.isFinite, value.rounded() == value,
              value >= Double(min), value <= Double(max) else { throw SelectiveRemotePublicationError.invalid }
        return Int(value)
    }
    func publicationArray() throws -> [Self] {
        guard case let .array(value) = self else { throw SelectiveRemotePublicationError.invalid }; return value
    }
}

// Keep the original wire JSON when hashing: Codable UUID re-encoding changes letter case.
enum SelectiveRemoteVaultPublicationV1 {
    static func canonical(_ value: SelectiveRemoteJSONValue) throws -> String {
        switch value {
        case .null: return "null"
        case let .boolean(b): return b ? "true" : "false"
        case let .number(n):
            guard n.isFinite, n.rounded() == n, abs(n) <= 9_007_199_254_740_991 else {
                throw SelectiveRemotePublicationError.invalid
            }
            return String(Int64(n))
        case let .string(s):
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(s), as: UTF8.self)
        case let .array(a): return "[" + (try a.map(canonical)).joined(separator: ",") + "]"
        case let .object(o):
            let keys = o.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + (try keys.map { try canonical(.string($0)) + ":" + canonical(o[$0]!) }).joined(separator: ",") + "}"
        }
    }
    static func bytes(_ purpose: String, _ value: SelectiveRemoteJSONValue) throws -> Data {
        guard !purpose.isEmpty, purpose.unicodeScalars.allSatisfy({ (97...122).contains($0.value) || $0.value == 45 })
        else { throw SelectiveRemotePublicationError.invalid }
        return Data(("selective-remote/publication/v1\0" + purpose + "\0" + (try canonical(value))).utf8)
    }
    static func hash(_ purpose: String, _ value: SelectiveRemoteJSONValue) throws -> String {
        SHA256.hash(data: try bytes(purpose, value)).map { String(format: "%02x", $0) }.joined()
    }
    static func decode<T: Decodable>(_ type: T.Type, from value: SelectiveRemoteJSONValue) throws -> T {
        try JSONDecoder().decode(type, from: Data(canonical(value).utf8))
    }
    private static func uuid(_ value: SelectiveRemoteJSONValue) throws -> String {
        let s = try value.publicationString()
        guard let u = UUID(uuidString: s), u.isSelectiveRemoteCloudUUID, u.canonicalCloudString == s
        else { throw SelectiveRemotePublicationError.invalid }; return s
    }
    private static func digest(_ value: SelectiveRemoteJSONValue) throws -> String {
        let s = try value.publicationString()
        guard s.utf8.count == 64, s.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw SelectiveRemotePublicationError.invalid }; return s
    }
    private static func signed(_ record: SelectiveRemoteJSONValue, purpose: String, root: String) throws -> [String: SelectiveRemoteJSONValue] {
        let r = try record.publicationObject(["payload", "signature"])
        guard let raw = Data(selectiveRemoteBase64URL: root, expectedLength: 65),
              let signature = Data(selectiveRemoteBase64URL: try r["signature"]!.publicationString(), expectedLength: 64)
        else { throw SelectiveRemotePublicationError.invalid }
        let key = try P256.Signing.PublicKey(x963Representation: raw)
        guard key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature),
                                  for: try bytes(purpose, r["payload"]!)) else { throw SelectiveRemotePublicationError.signature }
        return try r["payload"]!.publicationObject()
    }
    static func headerPayload(_ header: SelectiveRemoteJSONValue) throws -> [String: SelectiveRemoteJSONValue] {
        let record = try header.publicationObject(["payload", "signature"])
        let p = try record["payload"]!.publicationObject(["version", "teamID", "vaultID", "generationID", "sequence", "previousHash",
            "descriptorCommitment", "publisherAccountID", "publisherDeviceID", "publisherKeyVersion"])
        guard try p["version"]!.publicationInteger() == 1 else { throw SelectiveRemotePublicationError.invalid }
        for field in ["teamID", "vaultID", "generationID", "publisherAccountID", "publisherDeviceID"] { _ = try uuid(p[field]!) }
        _ = try p["publisherKeyVersion"]!.publicationInteger(); _ = try digest(p["descriptorCommitment"]!)
        if try p["sequence"]!.publicationInteger() == 1 {
            guard p["previousHash"] == .null else { throw SelectiveRemotePublicationError.invalid }
        } else { _ = try digest(p["previousHash"]!) }
        return p
    }
    static func verifyHeader(_ header: SelectiveRemoteJSONValue, rootPublicKey: String, teamID: String,
                             vaultID: String, highWater: SelectiveRemotePublicationHighWater?) throws -> SelectiveRemotePublicationHighWater {
        let p = try headerPayload(header)
        guard p["teamID"] == .string(teamID), p["vaultID"] == .string(vaultID) else { throw SelectiveRemotePublicationError.scope }
        _ = try signed(header, purpose: "header", root: rootPublicKey)
        let sequence = try p["sequence"]!.publicationInteger(), digest = try hash("header", header)
        if let highWater {
            guard highWater.sequence > 0 else { throw SelectiveRemotePublicationError.invalid }
            if sequence < highWater.sequence { throw SelectiveRemotePublicationError.rollback }
            if sequence == highWater.sequence, digest != highWater.hash { throw SelectiveRemotePublicationError.fork }
        }
        return .init(sequence: sequence, hash: digest)
    }
    static func descriptorPayload(_ descriptor: SelectiveRemoteJSONValue) throws -> [String: SelectiveRemoteJSONValue] {
        let r = try descriptor.publicationObject(["payload", "signature"])
        let p = try r["payload"]!.publicationObject(["headerHash", "resourceID", "kind", "part", "parentFolderID", "context", "ciphertextHash", "wrapperRoot"])
        _ = try digest(p["headerHash"]!); _ = try digest(p["ciphertextHash"]!); _ = try digest(p["wrapperRoot"]!)
        let resourceID = try uuid(p["resourceID"]!), kind = try p["kind"]!.publicationString(), part = try p["part"]!.publicationString()
        guard ["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].contains(kind),
              (kind == "CREDENTIAL" ? ["METADATA", "SECRET"] : ["GENERAL"]).contains(part) else { throw SelectiveRemotePublicationError.invalid }
        if p["parentFolderID"] != .null { guard try uuid(p["parentFolderID"]!) != resourceID else { throw SelectiveRemotePublicationError.invalid } }
        let c = try p["context"]!.publicationObject(["teamID", "vaultID", "resourceID", "part", "keyVersion", "policyVersion", "registryVersion", "resourceVersion", "manifestVersion"])
        for field in ["teamID", "vaultID", "resourceID"] { _ = try uuid(c[field]!) }
        let context = try decode(SelectiveRemoteResourceCipherContext.self, from: p["context"]!)
        _ = try SelectiveRemoteResourceCryptoV2.ciphertextAAD(context)
        guard c["resourceID"] == p["resourceID"], c["part"] == p["part"] else { throw SelectiveRemotePublicationError.scope }
        return p
    }
    private static func leaf(_ entry: SelectiveRemoteJSONValue) throws -> String {
        let e = try entry.publicationObject(["accountID", "deviceKeyVersion", "wrapper"])
        _ = try uuid(e["accountID"]!); _ = try e["deviceKeyVersion"]!.publicationInteger()
        let wrapper = try decode(SelectiveRemoteResourceKeyWrapper.self, from: e["wrapper"]!)
        let context = try e["wrapper"]!.publicationObject()["context"]!.publicationObject(["teamID", "vaultID", "resourceID", "part", "keyVersion", "membershipID", "membershipEpoch", "deviceID"])
        for field in ["teamID", "vaultID", "resourceID", "membershipID", "deviceID"] { _ = try uuid(context[field]!) }
        _ = try SelectiveRemoteResourceCryptoV2.wrapperAAD(wrapper.context)
        return try hash("wrapper-leaf", entry)
    }
    static func verifyWrapper(entry: SelectiveRemoteJSONValue, proof: SelectiveRemoteJSONValue, root: String) throws {
        _ = try digest(.string(root))
        let p = try proof.publicationObject(["index", "total", "siblings"])
        var index = try p["index"]!.publicationInteger(min: 0, max: 9999)
        var total = try p["total"]!.publicationInteger(max: 10000)
        let siblings = try p["siblings"]!.publicationArray()
        var levels = 0, width = total
        while width > 1 { width = (width + 1) / 2; levels += 1 }
        guard index < total, siblings.count == levels else { throw SelectiveRemotePublicationError.wrapperProof }
        var node = try leaf(entry)
        for item in siblings {
            let sibling = try digest(item)
            if index % 2 == 0, index + 1 == total, sibling != node { throw SelectiveRemotePublicationError.wrapperProof }
            node = try hash("wrapper-parent", .object(["left": .string(index % 2 == 0 ? node : sibling),
                "right": .string(index % 2 == 0 ? sibling : node)]))
            index /= 2; total = (total + 1) / 2
        }
        guard node == root else { throw SelectiveRemotePublicationError.wrapperProof }
    }
    static func verifyDescriptor(_ descriptor: SelectiveRemoteJSONValue, header: SelectiveRemoteJSONValue,
                                 rootPublicKey: String, envelope: SelectiveRemoteJSONValue? = nil,
                                 entry: SelectiveRemoteJSONValue? = nil, proof: SelectiveRemoteJSONValue? = nil) throws {
        let p = try descriptorPayload(descriptor), h = try headerPayload(header), c = try p["context"]!.publicationObject()
        guard p["headerHash"] == .string(try hash("header", header)), c["teamID"] == h["teamID"], c["vaultID"] == h["vaultID"]
        else { throw SelectiveRemotePublicationError.scope }
        _ = try signed(descriptor, purpose: "descriptor", root: rootPublicKey)
        if let envelope {
            _ = try decode(SelectiveRemoteResourceCipherEnvelope.self, from: envelope)
            guard try envelope.publicationObject()["context"] == p["context"],
                  p["ciphertextHash"] == .string(try hash("ciphertext", envelope)) else { throw SelectiveRemotePublicationError.ciphertext }
        }
        if let entry {
            guard let proof else { throw SelectiveRemotePublicationError.wrapperProof }
            let e = try entry.publicationObject(), w = try e["wrapper"]!.publicationObject()["context"]!.publicationObject()
            guard ["teamID", "vaultID", "resourceID", "part", "keyVersion"].allSatisfy({ w[$0] == c[$0] })
            else { throw SelectiveRemotePublicationError.scope }
            try verifyWrapper(entry: entry, proof: proof, root: p["wrapperRoot"]!.publicationString())
        }
    }
    static func verifyInventory(_ inventory: SelectiveRemoteJSONValue, descriptors: [SelectiveRemoteJSONValue],
                                header: SelectiveRemoteJSONValue, rootPublicKey: String, subject: SelectiveRemoteJSONValue) throws {
        let r = try inventory.publicationObject(["payload", "signature"])
        let p = try r["payload"]!.publicationObject(["headerHash", "accountID", "deviceID", "membershipID", "membershipEpoch", "count", "digest"])
        let s = try subject.publicationObject()
        for field in ["accountID", "deviceID", "membershipID"] { _ = try uuid(p[field]!) }
        _ = try p["membershipEpoch"]!.publicationInteger(); _ = try digest(p["digest"]!)
        guard ["accountID", "deviceID", "membershipID", "membershipEpoch"].allSatisfy({ p[$0] == s[$0] }) else { throw SelectiveRemotePublicationError.subject }
        guard p["headerHash"] == .string(try hash("header", header)) else { throw SelectiveRemotePublicationError.scope }
        _ = try signed(inventory, purpose: "inventory", root: rootPublicKey)
        let count = try p["count"]!.publicationInteger(min: 0, max: 2000)
        guard descriptors.count == count else { throw SelectiveRemotePublicationError.incomplete }
        var items: [(String, SelectiveRemoteJSONValue)] = []
        for descriptor in descriptors {
            let d = try descriptorPayload(descriptor), id = try d["resourceID"]!.publicationString(), part = try d["part"]!.publicationString()
            items.append((id + "/" + part, .object(["resourceID": .string(id), "part": .string(part),
                "descriptorHash": .string(try hash("descriptor", descriptor))])))
        }
        items.sort { $0.0 < $1.0 }
        guard Set(items.map(\.0)).count == count,
              p["digest"] == .string(try hash("inventory-items", .array(items.map(\.1)))) else { throw SelectiveRemotePublicationError.incomplete }
    }
}
