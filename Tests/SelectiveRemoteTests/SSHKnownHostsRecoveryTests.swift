import Foundation
import Testing
import Darwin
@testable import SelectiveRemote

private func recoveryFixture(_ contents: String) throws -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemoteRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("known_hosts")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return (directory, file)
}

@Test("Changed destination key yields one route-bound candidate without editing known_hosts")
func changedDestinationCandidate() throws {
    let oldKey = Data("old-host-key".utf8).base64EncodedString()
    let newKey = Data("new-host-key".utf8).base64EncodedString()
    let original = "server.example.test ssh-ed25519 \(oldKey) note\nother.example.test ssh-ed25519 \(oldKey)\n"
    let fixture = try recoveryFixture(original)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: "server.example.test ssh-ed25519 \(newKey)\n",
        from: fixture.file
    ))

    #expect(candidate.role == .destination)
    #expect(candidate.endpoint == "server.example.test:22")
    #expect(candidate.oldFingerprint.hasPrefix("SHA256:"))
    #expect(candidate.newFingerprint.hasPrefix("SHA256:"))
    #expect(candidate.oldFingerprint != candidate.newFingerprint)
    #expect(try String(contentsOf: fixture.file, encoding: .utf8) == original)
}

@Test("Duplicate, marker, and changed source algorithms fail closed")
func ambiguousRecoveryCandidates() throws {
    let oldKey = Data("old-host-key".utf8).base64EncodedString()
    let newKey = Data("new-host-key".utf8).base64EncodedString()
    let scan = "server.example.test ssh-ed25519 \(newKey)\n"
    for source in [
        "server.example.test ssh-ed25519 \(oldKey)\nserver.example.test ssh-ed25519 \(oldKey)\n",
        "@revoked server.example.test ssh-ed25519 \(oldKey)\n",
        "server.example.test ssh-rsa \(oldKey)\n",
    ] {
        let fixture = try recoveryFixture(source)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = SSHKnownHostsService.recoveryCandidate(
            host: "server.example.test", port: 22, role: .destination,
            profileID: UUID(), scannedContents: scan, from: fixture.file
        )
        #expect(candidate == nil)
    }
}

@Test("Custom-port IPv6 candidate keeps exact endpoint identity")
func customPortIPv6RecoveryCandidate() throws {
    let oldKey = Data("old-ipv6-key".utf8).base64EncodedString()
    let newKey = Data("new-ipv6-key".utf8).base64EncodedString()
    let fixture = try recoveryFixture("[2001:db8::10]:2222 ssh-ed25519 \(oldKey)\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "2001:db8::10", port: 2222, role: .jumpHost,
        profileID: UUID(), scannedContents: "[2001:db8::10]:2222 ssh-ed25519 \(newKey)\n",
        from: fixture.file
    ))
    #expect(candidate.role == .jumpHost)
    #expect(candidate.endpoint == "[2001:db8::10]:2222")
}

@Test("Scanned endpoint must match the trusted destination")
func scannedEndpointMustMatch() throws {
    let oldKey = Data("old".utf8).base64EncodedString()
    let newKey = Data("new".utf8).base64EncodedString()
    let fixture = try recoveryFixture("server.example.test ssh-ed25519 \(oldKey)\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    #expect(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: "other.example.test ssh-ed25519 \(newKey)\n",
        from: fixture.file
    ) == nil)
    #expect(SSHKnownHostsService.recoveryCandidate(
        host: "-oProxyCommand=evil", port: 22, role: .destination,
        profileID: UUID(), scannedContents: "-oProxyCommand=evil ssh-ed25519 \(newKey)\n",
        from: fixture.file
    ) == nil)
}

@Test("Confirmed replacement changes only the matching key and preserves the source")
func confirmedReplacement() async throws {
    let oldKey = Data("old".utf8).base64EncodedString()
    let newKey = Data("new".utf8).base64EncodedString()
    let original = "# header\nserver.example.test  ssh-ed25519  \(oldKey)  comment\nother.test ssh-ed25519 \(oldKey)\n"
    let scan = "server.example.test ssh-ed25519 \(newKey)\n"
    let fixture = try recoveryFixture(original)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: scan, from: fixture.file
    ))
    let backup = try await SSHKnownHostsService.replaceConfirmed(candidate, from: fixture.file) { scan }
    #expect(try String(contentsOf: backup, encoding: .utf8) == original)
    #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "# header\nserver.example.test  ssh-ed25519  \(newKey)  comment\nother.test ssh-ed25519 \(oldKey)\n")
    let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
}

@Test("Changed source or second scan rejects replacement")
func changedSourceOrScanRejects() async throws {
    let oldKey = Data("old".utf8).base64EncodedString()
    let newKey = Data("new".utf8).base64EncodedString()
    let scan = "server.example.test ssh-ed25519 \(newKey)\n"
    let fixture = try recoveryFixture("server.example.test ssh-ed25519 \(oldKey)\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: scan, from: fixture.file
    ))
    try "# edited\nserver.example.test ssh-ed25519 \(oldKey)\n".write(to: fixture.file, atomically: true, encoding: .utf8)
    await #expect(throws: Error.self) {
        try await SSHKnownHostsService.replaceConfirmed(candidate, from: fixture.file) { scan }
    }
    try candidate.sourceContents.write(to: fixture.file)
    await #expect(throws: Error.self) {
        try await SSHKnownHostsService.replaceConfirmed(candidate, from: fixture.file) {
            "server.example.test ssh-ed25519 \(Data("third".utf8).base64EncodedString())\n"
        }
    }
    #expect(try Data(contentsOf: fixture.file) == candidate.sourceContents)
}

@Test("A symlink is never a guided recovery source")
func symlinkSourceRejected() throws {
    let oldKey = Data("old".utf8).base64EncodedString()
    let newKey = Data("new".utf8).base64EncodedString()
    let fixture = try recoveryFixture("server.example.test ssh-ed25519 \(oldKey)\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let link = fixture.directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
    #expect(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: "server.example.test ssh-ed25519 \(newKey)\n",
        from: link
    ) == nil)
}

@Test("OpenSSH hashed lookup can select one exact source line")
func hashedRecoveryCandidate() throws {
    let oldKey = Data("old".utf8).base64EncodedString()
    let newKey = Data("new".utf8).base64EncodedString()
    let fixture = try recoveryFixture("server.example.test ssh-ed25519 \(oldKey)\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-H", "-f", fixture.file.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: "server.example.test ssh-ed25519 \(newKey)\n",
        from: fixture.file
    ))
    #expect(candidate.originalEntry.isHashed)
    let hashedLine = try String(contentsOf: fixture.file, encoding: .utf8)
    try (hashedLine + hashedLine).write(to: fixture.file, atomically: true, encoding: .utf8)
    #expect(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: "server.example.test ssh-ed25519 \(newKey)\n",
        from: fixture.file
    ) == nil)
}

@Test("One changed algorithm remains identifiable alongside an unchanged algorithm")
func multipleAlgorithmsOneChanged() throws {
    let oldEd = Data("old-ed".utf8).base64EncodedString()
    let newEd = Data("new-ed".utf8).base64EncodedString()
    let sameRSA = Data("same-rsa".utf8).base64EncodedString()
    let fixture = try recoveryFixture("server.example.test ssh-ed25519 \(oldEd)\nserver.example.test ssh-rsa \(sameRSA)\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(),
        scannedContents: "server.example.test ssh-ed25519 \(newEd)\n",
        from: fixture.file
    ))
    #expect(candidate.originalEntry.algorithm == "ssh-ed25519")
}

@Test("A failed lock write leaves the original host entry intact")
func failedWriteLeavesSourceIntact() async throws {
    let oldKey = Data("old".utf8).base64EncodedString()
    let newKey = Data("new".utf8).base64EncodedString()
    let original = "server.example.test ssh-ed25519 \(oldKey)\n"
    let scan = "server.example.test ssh-ed25519 \(newKey)\n"
    let fixture = try recoveryFixture(original)
    defer {
        _ = chmod(fixture.directory.path, 0o700)
        try? FileManager.default.removeItem(at: fixture.directory)
    }
    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: scan, from: fixture.file
    ))
    #expect(chmod(fixture.directory.path, 0o500) == 0)
    await #expect(throws: Error.self) {
        try await SSHKnownHostsService.replaceConfirmed(candidate, from: fixture.file) { scan }
    }
    #expect(try String(contentsOf: fixture.file, encoding: .utf8) == original)
}

@Test("Versioned recovery backups retain only the latest ten successful states")
func boundedRecoveryBackups() async throws {
    let fixture = try recoveryFixture("server.example.test ssh-ed25519 \(Data("key-0".utf8).base64EncodedString())\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var latestBackup: URL?
    for index in 1...12 {
        let scan = "server.example.test ssh-ed25519 \(Data("key-\(index)".utf8).base64EncodedString())\n"
        let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
            host: "server.example.test", port: 22, role: .destination,
            profileID: UUID(), scannedContents: scan, from: fixture.file
        ))
        latestBackup = try await SSHKnownHostsService.replaceConfirmed(candidate, from: fixture.file) { scan }
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    let backups = names.filter { $0.hasPrefix("known_hosts.selectiveremote.") && $0.hasSuffix(".bak") }
    #expect(backups.count == 10)
    #expect(FileManager.default.fileExists(atPath: try #require(latestBackup).path))
}

@Test("A concurrent recovery lock prevents a second mutation")
func concurrentRecoveryRejected() async throws {
    let oldKey = Data("old".utf8).base64EncodedString()
    let newKey = Data("new".utf8).base64EncodedString()
    let original = "server.example.test ssh-ed25519 \(oldKey)\n"
    let scan = "server.example.test ssh-ed25519 \(newKey)\n"
    let fixture = try recoveryFixture(original)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let candidate = try #require(SSHKnownHostsService.recoveryCandidate(
        host: "server.example.test", port: 22, role: .destination,
        profileID: UUID(), scannedContents: scan, from: fixture.file
    ))
    let lockPath = fixture.file.appendingPathExtension("selectiveremote.lock").path
    let fd = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    await #expect(throws: Error.self) {
        try await SSHKnownHostsService.replaceConfirmed(candidate, from: fixture.file) { scan }
    }
    #expect(try String(contentsOf: fixture.file, encoding: .utf8) == original)
}
