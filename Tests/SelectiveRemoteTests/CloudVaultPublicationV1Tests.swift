import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("authenticated publication reader protocol")
struct CloudVaultPublicationV1Tests {
    @Test("canonical signing bytes match independent browser vector")
    func canonicalBytes() throws {
        let value = SelectiveRemoteJSONValue.object(["b": .string("é"), "a": .number(1)])
        #expect(try SelectiveRemoteVaultPublicationV1.hash("vector", value) ==
            "257d82987fce97825cedb0acac86e742bbbae1fb6b6ba84251df7f8d64fd3b19")
    }

    @Test("Mac verifies browser signature, own wrapper proof and exact ciphertext before decrypt")
    func browserInterop() throws {
        let f = try fixture()
        let h = try SelectiveRemoteVaultPublicationV1.verifyHeader(f.header, rootPublicKey: f.rootPublicKey,
            teamID: f.teamID, vaultID: f.vaultID, highWater: nil)
        #expect(h.sequence == 1)
        try SelectiveRemoteVaultPublicationV1.verifyDescriptor(f.descriptor, header: f.header,
            rootPublicKey: f.rootPublicKey, envelope: f.envelope, entry: f.entry, proof: f.proof)
        try SelectiveRemoteVaultPublicationV1.verifyInventory(f.inventory, descriptors: [f.descriptor],
            header: f.header, rootPublicKey: f.rootPublicKey, subject: f.subject)
        let wrapper = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceKeyWrapper.self,
            from: f.entry.publicationObject()["wrapper"]!)
        let envelope = try SelectiveRemoteVaultPublicationV1.decode(SelectiveRemoteResourceCipherEnvelope.self, from: f.envelope)
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(selectiveRemoteBase64URL: f.recipientPrivateScalar)!)
        let cek = try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: key, context: wrapper.context)
        #expect(try SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: cek, context: envelope.context) == Data(f.plaintext.utf8))
    }

    @Test("rollback and same-sequence fork cannot replace durable high-water")
    func rollback() throws {
        let f = try fixture()
        #expect(throws: SelectiveRemotePublicationError.rollback) {
            try SelectiveRemoteVaultPublicationV1.verifyHeader(f.header, rootPublicKey: f.rootPublicKey,
                teamID: f.teamID, vaultID: f.vaultID, highWater: .init(sequence: 2, hash: String(repeating: "a", count: 64)))
        }
        #expect(throws: SelectiveRemotePublicationError.fork) {
            try SelectiveRemoteVaultPublicationV1.verifyHeader(f.header, rootPublicKey: f.rootPublicKey,
                teamID: f.teamID, vaultID: f.vaultID, highWater: .init(sequence: 1, hash: String(repeating: "a", count: 64)))
        }
    }

    @Test("partial inventory and substituted device wrapper fail closed")
    func incompleteAndSubstitution() throws {
        let f = try fixture()
        #expect(throws: SelectiveRemotePublicationError.incomplete) {
            try SelectiveRemoteVaultPublicationV1.verifyInventory(f.inventory, descriptors: [],
                header: f.header, rootPublicKey: f.rootPublicKey, subject: f.subject)
        }
        var e = try f.entry.publicationObject(), w = try e["wrapper"]!.publicationObject()
        var c = try w["context"]!.publicationObject(); c["deviceID"] = .string(UUID().canonicalCloudString)
        w["context"] = .object(c); e["wrapper"] = .object(w)
        #expect(throws: Error.self) {
            try SelectiveRemoteVaultPublicationV1.verifyDescriptor(f.descriptor, header: f.header,
                rootPublicKey: f.rootPublicKey, envelope: f.envelope, entry: .object(e), proof: f.proof)
        }
    }

    private struct Fixture: Decodable {
        let testOnly: Bool
        let rootPublicKey: String
        let teamID: String
        let vaultID: String
        let recipientPrivateScalar: String
        let plaintext: String
        let header: SelectiveRemoteJSONValue
        let descriptor: SelectiveRemoteJSONValue
        let inventory: SelectiveRemoteJSONValue
        let envelope: SelectiveRemoteJSONValue
        let entry: SelectiveRemoteJSONValue
        let proof: SelectiveRemoteJSONValue
        let subject: SelectiveRemoteJSONValue
    }
    @Test("signed browser empty inventory is complete without a fake resource or wrapper")
    func emptyGeneration() throws {
        struct Empty: Decodable {
            let testOnly: Bool
            let rootPublicKey, teamID, vaultID: String
            let header, inventory, subject: SelectiveRemoteJSONValue
        }
        let url = try #require(Bundle.module.url(forResource: "vault-publication-empty-v1", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode(Empty.self, from: Data(contentsOf: url))
        #expect(f.testOnly)
        _ = try SelectiveRemoteVaultPublicationV1.verifyHeader(f.header, rootPublicKey: f.rootPublicKey,
            teamID: f.teamID, vaultID: f.vaultID, highWater: nil)
        try SelectiveRemoteVaultPublicationV1.verifyInventory(f.inventory, descriptors: [],
            header: f.header, rootPublicKey: f.rootPublicKey, subject: f.subject)
        var altered = try f.inventory.publicationObject(), payload = try altered["payload"]!.publicationObject()
        payload["count"] = .number(1); altered["payload"] = .object(payload)
        #expect(throws: Error.self) {
            try SelectiveRemoteVaultPublicationV1.verifyInventory(.object(altered), descriptors: [],
                header: f.header, rootPublicKey: f.rootPublicKey, subject: f.subject)
        }
    }
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "vault-publication-v1", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)); #expect(f.testOnly)
        return f
    }
}
