import Foundation
import Testing
@testable import SelectiveRemote

private func makeKnownHost(_ hosts: String, marker: String? = nil) throws -> SSHKnownHostEntry {
    let key = Data("known-host-key".utf8).base64EncodedString()
    let prefix = marker.map { "\($0) " } ?? ""
    return try #require(SSHKnownHostsService.parse(contents: "\(prefix)\(hosts) ssh-ed25519 \(key)", path: "/tmp/known_hosts").first)
}

@Test("Known Host преобразуется в hostname endpoint")
func knownHostProfileEndpointHostname() throws {
    #expect(SSHKnownHostsService.profileEndpoints(for: try makeKnownHost("server.example.com")) == [SSHKnownHostEndpoint(host: "server.example.com", port: 22)])
}

@Test("Known Host понимает IPv4, IPv6 и custom port")
func knownHostProfileEndpointAddresses() throws {
    let endpoints = SSHKnownHostsService.profileEndpoints(for: try makeKnownHost("10.0.0.10,[server.example.com]:49222,[2001:db8::10]:2200"))
    #expect(endpoints == [
        SSHKnownHostEndpoint(host: "10.0.0.10", port: 22),
        SSHKnownHostEndpoint(host: "server.example.com", port: 49_222),
        SSHKnownHostEndpoint(host: "2001:db8::10", port: 2_200)
    ])
}

@Test("Hashed, marker и wildcard Known Host нельзя конвертировать")
func knownHostProfileRejectsNonConcreteEntries() throws {
    for entry in [try makeKnownHost("|1|salt|hash"), try makeKnownHost("*.corp.example", marker: "@cert-authority"), try makeKnownHost("*.example.com")] {
        #expect(SSHKnownHostsService.profileEndpoints(for: entry).isEmpty)
        #expect(SSHKnownHostsService.profileConversionUnavailableReason(for: entry) != nil)
    }
}

@Test("Duplicate Known Host profile учитывает host, port и username")
func knownHostProfileDuplicateMatching() {
    var first = ConnectionProfile(connectionType: .ssh); first.friendlyName = "Admin"; first.host = "server.example.com"; first.username = "admin"; first.sshPort = 22
    var second = ConnectionProfile(connectionType: .ssh); second.friendlyName = "Root"; second.host = "server.example.com"; second.username = "root"; second.sshPort = 2200
    let endpoint = SSHKnownHostEndpoint(host: "SERVER.EXAMPLE.COM", port: 22)
    #expect(SSHKnownHostProfileMatcher.exactDuplicate(in: [first, second], endpoint: endpoint, username: "admin")?.id == first.id)
    #expect(SSHKnownHostProfileMatcher.exactDuplicate(in: [first, second], endpoint: endpoint, username: "root") == nil)
}

@Test("Разбор endpoint не изменяет known_hosts")
func knownHostProfileEndpointParsingIsReadOnly() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SelectiveRemoteKnownHostProfile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("known_hosts"); let key = Data("key".utf8).base64EncodedString(); let original = "server.example.com ssh-ed25519 \(key)\n"
    try original.write(to: url, atomically: true, encoding: .utf8)
    let entry = try #require(SSHKnownHostsService.load(from: url).first); _ = SSHKnownHostsService.profileEndpoints(for: entry)
    #expect(try String(contentsOf: url, encoding: .utf8) == original)
}
