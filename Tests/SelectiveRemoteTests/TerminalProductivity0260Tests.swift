import Foundation
import Testing
@testable import SelectiveRemote

@Test("Remote probe parses Host Insights without losing server commands")
func parsesHostInsights() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.test"
    profile.username = "admin"
    let settings = try SSHConnectionSettings(profile: profile, identity: nil, jumpHost: nil)
    let output = """
    SYSTEM\tUbuntu 24.04
    OS\tubuntu\tdebian
    HOSTNAME\tprod-api-01
    UPTIME\t183845
    LOAD\t0.12\t0.20\t0.30
    MEMORY\t4294967296\t8589934592
    DISK\t10737418240\t21474836480\t50
    PORTS\t17
    USERS\t3
    UPDATES\t12
    COMMAND\tsystemctl
    COMMAND\tuptime
    SERVICE\tnginx.service\tactive\trunning
    """

    let snapshot = TerminalRemoteContextService.parse(output: output, settings: settings)
    #expect(snapshot.insights.hostname == "prod-api-01")
    #expect(snapshot.insights.uptimeSeconds == 183845)
    #expect(snapshot.insights.load1 == 0.12)
    #expect(snapshot.insights.memoryTotalBytes == 8_589_934_592)
    #expect(snapshot.insights.rootDiskPercent == 50)
    #expect(snapshot.insights.listeningPorts == 17)
    #expect(snapshot.insights.loggedInUsers == 3)
    #expect(snapshot.insights.updatesAvailable == 12)
    #expect(snapshot.services.map(\.name) == ["nginx.service"])
    #expect(snapshot.suggestions.contains(where: { $0.command == "uptime" }))
}

@Test("Terminal autocomplete supports token-prefix arguments and sudo normalization")
func smartAutocompleteSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.js"),
        encoding: .utf8
    )
    #expect(source.contains("const orderedTokenPrefixMatch"))
    #expect(source.contains("replace(/^sudo\\s+/, \"\")"))
    #expect(source.contains("tokenMatch ? 2"))
}
