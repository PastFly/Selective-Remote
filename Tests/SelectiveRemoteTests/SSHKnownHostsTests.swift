import Foundation
import Testing
@testable import SelectiveRemote

@Test("Known Hosts парсер читает обычные, hashed и marker записи")
func parsesKnownHostsEntries() throws {
    let key1 = Data("first-key".utf8).base64EncodedString()
    let key2 = Data("second-key".utf8).base64EncodedString()
    let key3 = Data("third-key".utf8).base64EncodedString()
    let contents = """
    # comment
    server.example.com,10.0.0.10 ssh-ed25519 \(key1) workstation
    |1|salt|hash ssh-rsa \(key2)
    @cert-authority *.corp.example ecdsa-sha2-nistp256 \(key3) corp-ca
    """

    let entries = SSHKnownHostsService.parse(contents: contents, path: "/tmp/known_hosts")

    #expect(entries.count == 3)
    #expect(entries[0].displayHost == "server.example.com")
    #expect(entries[0].directHosts == ["server.example.com", "10.0.0.10"])
    #expect(entries[0].algorithm == "ssh-ed25519")
    #expect(entries[0].fingerprint.hasPrefix("SHA256:"))
    #expect(entries[1].isHashed)
    #expect(entries[1].displayHost == "Хешированный хост")
    #expect(entries[2].marker == "@cert-authority")
}

@Test("Known Hosts понимает нестандартный SSH порт")
func parsesKnownHostVerificationTarget() throws {
    let key = Data("key".utf8).base64EncodedString()
    let entry = try #require(
        SSHKnownHostsService.parse(
            contents: "[server.example.com]:49222 ssh-ed25519 \(key)",
            path: "/tmp/known_hosts"
        ).first
    )
    let target = try #require(SSHKnownHostsService.verificationTarget(for: entry))
    #expect(target.host == "server.example.com")
    #expect(target.port == 49_222)
}

@Test("Удаление Known Host создаёт резервную копию")
func deletesKnownHostWithBackup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemoteKnownHosts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("known_hosts")
    let key1 = Data("first".utf8).base64EncodedString()
    let key2 = Data("second".utf8).base64EncodedString()
    let original = "one.example ssh-ed25519 \(key1)\ntwo.example ssh-ed25519 \(key2)\n"
    try original.write(to: url, atomically: true, encoding: .utf8)

    let entry = try #require(SSHKnownHostsService.load(from: url).first)
    try SSHKnownHostsService.delete(entry, from: url)

    let updated = try String(contentsOf: url, encoding: .utf8)
    let backup = directory.appendingPathComponent("known_hosts.selectiveremote.bak")
    let backupText = try String(contentsOf: backup, encoding: .utf8)
    #expect(!updated.contains("one.example"))
    #expect(updated.contains("two.example"))
    #expect(backupText == original)
}
