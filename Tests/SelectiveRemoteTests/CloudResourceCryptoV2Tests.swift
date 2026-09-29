import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("dormant resource crypto v2")
struct CloudResourceCryptoV2Tests {
    private let team = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let vault = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let resource = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let membership = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let device = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    private var context: SelectiveRemoteResourceCipherContext {
        .init(teamID: team, vaultID: vault, resourceID: resource, part: .metadata,
              keyVersion: 1, policyVersion: 2, registryVersion: 4,
              resourceVersion: 5, manifestVersion: 7)
    }

    private var recipient: SelectiveRemoteResourceWrapperContext {
        .init(teamID: team, vaultID: vault, resourceID: resource, part: .metadata,
              keyVersion: 1, membershipID: membership, membershipEpoch: 3, deviceID: device)
    }

    @Test("browser and macOS use identical canonical AAD")
    func canonicalAAD() throws {
        #expect(try SelectiveRemoteResourceCryptoV2.ciphertextAAD(context).selectiveRemoteBase64URL ==
            "c2VsZWN0aXZlLXJlbW90ZS9yZXNvdXJjZS1jaXBoZXJ0ZXh0L3YyAAACACQxMTExMTExMS0xMTExLTQxMTEtODExMS0xMTExMTExMTExMTEAJDIyMjIyMjIyLTIyMjItNDIyMi04MjIyLTIyMjIyMjIyMjIyMgAkMzMzMzMzMzMtMzMzMy00MzMzLTgzMzMtMzMzMzMzMzMzMzMzAAhNRVRBREFUQQABMQABMgABNAABNQABNw")
        #expect(try SelectiveRemoteResourceCryptoV2.wrapperAAD(recipient).selectiveRemoteBase64URL ==
            "c2VsZWN0aXZlLXJlbW90ZS9yZXNvdXJjZS13cmFwcGVyL3YyAAACACQxMTExMTExMS0xMTExLTQxMTEtODExMS0xMTExMTExMTExMTEAJDIyMjIyMjIyLTIyMjItNDIyMi04MjIyLTIyMjIyMjIyMjIyMgAkMzMzMzMzMzMtMzMzMy00MzMzLTgzMzMtMzMzMzMzMzMzMzMzAAhNRVRBREFUQQABMQAkNDQ0NDQ0NDQtNDQ0NC00NDQ0LTg0NDQtNDQ0NDQ0NDQ0NDQ0AAEzACQ1NTU1NTU1NS01NTU1LTQ1NTUtODU1NS01NTU1NTU1NTU1NTU")
    }

    @Test("CEK, ciphertext and device wrapper reject changed scope")
    func roundtripAndMutation() throws {
        let cek = SelectiveRemoteResourceCryptoV2.generateCEK()
        #expect(cek.count == 32)
        #expect(cek != SelectiveRemoteResourceCryptoV2.generateCEK())
        let plaintext = Data("resource secret".utf8)
        let envelope = try SelectiveRemoteResourceCryptoV2.encrypt(plaintext, cek: cek, context: context)
        #expect(try SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: cek, context: context) == plaintext)
        let changed = SelectiveRemoteResourceCipherContext(teamID: team, vaultID: vault,
            resourceID: UUID(), part: .metadata, keyVersion: 1, policyVersion: 2,
            registryVersion: 4, resourceVersion: 5, manifestVersion: 7)
        #expect(throws: Error.self) {
            try SelectiveRemoteResourceCryptoV2.decrypt(envelope, cek: cek, context: changed)
        }
        let identity = P256.KeyAgreement.PrivateKey()
        let wrapper = try SelectiveRemoteResourceCryptoV2.wrap(cek,
            for: SelectiveRemoteTeamDevicePublicKey(identity.publicKey), context: recipient)
        #expect(try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: identity,
            context: recipient) == cek)
        let wrong = SelectiveRemoteResourceWrapperContext(teamID: team, vaultID: vault,
            resourceID: resource, part: .secret, keyVersion: 1, membershipID: membership,
            membershipEpoch: 3, deviceID: device)
        #expect(throws: Error.self) {
            try SelectiveRemoteResourceCryptoV2.unwrap(wrapper, with: identity, context: wrong)
        }
    }

    @Test("macOS opens a browser-produced ciphertext and wrapper")
    func browserInterop() throws {
        struct Fixture: Decodable {
            let testOnly: Bool
            let recipientPrivateScalar: String
            let plaintext: String
            let ciphertext: SelectiveRemoteResourceCipherEnvelope
            let wrapper: SelectiveRemoteResourceKeyWrapper
        }
        let url = try #require(Bundle.module.url(forResource: "resource-v2-browser",
                                                  withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.testOnly)
        let scalar = try #require(Data(selectiveRemoteBase64URL: fixture.recipientPrivateScalar,
                                       expectedLength: 32))
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar)
        let cek = try SelectiveRemoteResourceCryptoV2.unwrap(fixture.wrapper,
            with: privateKey, context: recipient)
        #expect(try SelectiveRemoteResourceCryptoV2.decrypt(fixture.ciphertext,
            cek: cek, context: context) == Data(fixture.plaintext.utf8))
    }
}
