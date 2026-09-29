import CryptoKit
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("dormant device trust v1")
struct CloudDeviceTrustV1Tests {
    private let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let device = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let serial = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!

    private final class MemoryPinStore: SelectiveRemoteDeviceTrustPinStore {
        var current: SelectiveRemoteDeviceTrustPin?
        var rejectAdvance = false
        func pin(endpoint: URL, accountID: UUID) throws -> SelectiveRemoteDeviceTrustPin? {
            current?.accountID == accountID ? current : nil
        }
        func advance(endpoint: URL, expected: SelectiveRemoteDeviceTrustPin,
                     next: SelectiveRemoteDeviceTrustPin) throws {
            guard !rejectAdvance, current == expected else {
                throw SelectiveRemoteDeviceTrustError.staleDirectory
            }
            current = next
        }
    }

    @Test("wrapper is withheld if the local high-water cannot be persisted")
    func persistenceBeforeWrapper() throws {
        let root = P256.Signing.PrivateKey()
        let key = try SelectiveRemoteTeamDevicePublicKey(P256.KeyAgreement.PrivateKey().publicKey)
        let certificate = try SelectiveRemoteDeviceTrustV1.issueCertificate(root: root,
            accountID: account, deviceID: device, publicKey: key, keyVersion: 1,
            issuedAt: 1_800_000_000, serial: serial)
        let directory = try SelectiveRemoteDeviceTrustV1.signDirectory(root: root,
            accountID: account, version: 1, certificates: [certificate])
        let store = MemoryPinStore()
        store.current = SelectiveRemoteDeviceTrustPin(accountID: account,
            rootFingerprint: SelectiveRemoteDeviceTrustV1.fingerprint(root.publicKey),
            highWater: 1, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        store.rejectAdvance = true
        let context = SelectiveRemoteResourceWrapperContext(
            teamID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            vaultID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            resourceID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            part: .secret, keyVersion: 1,
            membershipID: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
            membershipEpoch: 1, deviceID: device)
        #expect(throws: Error.self) {
            try SelectiveRemoteDeviceTrustV1.wrapForVerifiedDevice(Data(repeating: 1, count: 32),
                context: context, endpoint: URL(string: "https://cloud.example.test")!,
                pinStore: store, rootPublicKey: root.publicKey,
                certificate: certificate, directory: directory)
        }
    }

    @Test("macOS verifies a browser-signed device and directory")
    func browserInterop() throws {
        struct Fixture: Decodable {
            let testOnly: Bool
            let rootPublicKey: String
            let rootFingerprint: String
            let certificate: SelectiveRemoteSignedDeviceCertificate
            let directory: SelectiveRemoteSignedDeviceDirectory
        }
        let url = try #require(Bundle.module.url(forResource: "device-trust-browser",
                                                  withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.testOnly)
        let raw = try #require(Data(selectiveRemoteBase64URL: fixture.rootPublicKey,
                                    expectedLength: 65))
        let root = try P256.Signing.PublicKey(x963Representation: raw)
        #expect(SelectiveRemoteDeviceTrustV1.fingerprint(root) == fixture.rootFingerprint)
        let pin = SelectiveRemoteDeviceTrustPin(accountID: account,
            rootFingerprint: fixture.rootFingerprint, highWater: 1,
            checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(fixture.directory))
        #expect(try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: root,
            certificate: fixture.certificate, directory: fixture.directory,
            pin: pin, expectedDeviceID: device).highWater == 1)
        let encoded = try JSONEncoder().encode(fixture.certificate)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains(account.uuidString.lowercased()))
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(SelectiveRemoteSignedDeviceCertificate.self,
                from: Data(text.replacingOccurrences(of: "\"payload\":{",
                    with: "\"payload\":{\"unknown\":true,").utf8))
        }
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(SelectiveRemoteSignedDeviceCertificate.self,
                from: Data(text.replacingOccurrences(of: account.uuidString.lowercased(),
                    with: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA").utf8))
        }
    }

    @Test("root signs certificate and directory; changed recipient fails")
    func approvedDevice() throws {
        let root = P256.Signing.PrivateKey()
        let identity = P256.KeyAgreement.PrivateKey()
        let key = try SelectiveRemoteTeamDevicePublicKey(identity.publicKey)
        let certificate = try SelectiveRemoteDeviceTrustV1.issueCertificate(
            root: root, accountID: account, deviceID: device, publicKey: key,
            keyVersion: 1, issuedAt: 1_800_000_000, serial: serial)
        let directory = try SelectiveRemoteDeviceTrustV1.signDirectory(
            root: root, accountID: account, version: 1, certificates: [certificate])
        let pin = SelectiveRemoteDeviceTrustPin(accountID: account,
            rootFingerprint: SelectiveRemoteDeviceTrustV1.fingerprint(root.publicKey), highWater: 1,
            checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(directory))
        #expect(try SelectiveRemoteDeviceTrustV1.verify(
            rootPublicKey: root.publicKey, certificate: certificate,
            directory: directory, pin: pin, expectedDeviceID: device).publicKey == key)
        #expect(throws: Error.self) {
            try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: root.publicKey,
                certificate: certificate, directory: directory, pin: pin,
                expectedDeviceID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)
        }
    }

    @Test("rollback, revoked certificate and unpaired root fail")
    func rollbackAndRevocation() throws {
        let root = P256.Signing.PrivateKey()
        let key = try SelectiveRemoteTeamDevicePublicKey(P256.KeyAgreement.PrivateKey().publicKey)
        let certificate = try SelectiveRemoteDeviceTrustV1.issueCertificate(root: root,
            accountID: account, deviceID: device, publicKey: key, keyVersion: 1,
            issuedAt: 1_800_000_000, serial: serial)
        let old = try SelectiveRemoteDeviceTrustV1.signDirectory(root: root,
            accountID: account, version: 1, certificates: [certificate])
        let revoked = try SelectiveRemoteDeviceTrustV1.signDirectory(root: root,
            accountID: account, version: 2, certificates: [])
        let pin = SelectiveRemoteDeviceTrustPin(accountID: account,
            rootFingerprint: SelectiveRemoteDeviceTrustV1.fingerprint(root.publicKey), highWater: 2,
            checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(revoked))
        #expect(throws: Error.self) {
            try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: root.publicKey,
                certificate: certificate, directory: old, pin: pin, expectedDeviceID: device)
        }
        #expect(throws: Error.self) {
            try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: root.publicKey,
                certificate: certificate, directory: revoked, pin: pin, expectedDeviceID: device)
        }
        #expect(throws: Error.self) {
            try SelectiveRemoteDeviceTrustV1.verify(rootPublicKey: root.publicKey,
                certificate: certificate, directory: revoked,
                pin: .init(accountID: account, rootFingerprint: String(repeating: "0", count: 64),
                           highWater: 1, checkpointDigest: try SelectiveRemoteDeviceTrustV1.directoryDigest(revoked)), expectedDeviceID: device)
        }
    }
}
