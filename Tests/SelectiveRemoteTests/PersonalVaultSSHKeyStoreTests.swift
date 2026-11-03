import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Personal Vault SSH key installation")
struct PersonalVaultSSHKeyStoreTests {
    @Test("dot path components cannot remove installed keys", arguments: [
        "/synthetic/..", "/synthetic/../", "/synthetic/.", "/synthetic/./"
    ])
    func rejectsDirectoryBasenames(path: String) throws {
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("sr-key-store-test-\(UUID().uuidString)", isDirectory: true)
        let fileManager = SSHKeyStoreTestFileManager(root: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Selective Remote/Cloud SSH Keys", isDirectory: true)
        let sentinel = root.appendingPathComponent("existing-key/id_ed25519")
        try fileManager.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previousKey = Data("synthetic-existing-private-key".utf8)
        try previousKey.write(to: sentinel)

        #expect(throws: CocoaError(.fileWriteInvalidFileName)) {
            try SelectiveRemotePersonalVaultSSHKeyStore.install(
                [input(path: path)], fileManager: fileManager
            )
        }
        #expect(try Data(contentsOf: sentinel) == previousKey)
    }

    @Test("ordinary key names preserve private, public and certificate files")
    func installsOrdinaryKey() throws {
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("sr-key-store-test-\(UUID().uuidString)", isDirectory: true)
        let fileManager = SSHKeyStoreTestFileManager(root: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        let value = input(path: "/synthetic/id_ed25519")
        let restored = try #require(SelectiveRemotePersonalVaultSSHKeyStore.install(
            [value], fileManager: fileManager
        ).first)
        let expectedDirectory = temporary
            .appendingPathComponent("Selective Remote/Cloud SSH Keys", isDirectory: true)
            .appendingPathComponent(value.record.id.uuidString.lowercased(), isDirectory: true)
        let privateURL = expectedDirectory.appendingPathComponent("id_ed25519")
        #expect(restored.privateKeyPath == privateURL.path)
        #expect(try Data(contentsOf: privateURL) == value.privateKey)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(restored.publicKeyPath))) == value.publicKey)
        #expect(try Data(contentsOf: expectedDirectory.appendingPathComponent("id_ed25519-cert.pub")) == value.certificate)
        let attributes = try fileManager.attributesOfItem(atPath: privateURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    private func input(path: String) -> SelectiveRemotePersonalVaultSSHKeyInput {
        .init(
            record: SSHKeyRecord(name: "synthetic", privateKeyPath: path, fingerprint: "synthetic", algorithm: "ed25519"),
            privateKey: Data("synthetic-private".utf8),
            publicKey: Data("synthetic-public".utf8),
            certificate: Data("synthetic-certificate".utf8)
        )
    }
}

private final class SSHKeyStoreTestFileManager: FileManager, @unchecked Sendable {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root]
    }
}
