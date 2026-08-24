import Foundation
import Testing
@testable import SelectiveRemote

@Test("Legacy SSH profile keeps OpenSSH as the Terminal protocol")
func moshProfileLegacyDefaultsAndRoundTrip() throws {
    let legacyJSON = #"{"connectionType":"ssh","friendlyName":"Legacy","host":"example.test","username":"admin"}"#.data(using: .utf8)!
    let legacy = try JSONDecoder().decode(ConnectionProfile.self, from: legacyJSON)

    #expect(legacy.sshTerminalProtocol == .ssh)
    #expect(legacy.moshUDPPort == 0)
    #expect(legacy.moshServerPath.isEmpty)

    var profile = legacy
    profile.sshTerminalProtocol = .mosh
    profile.moshUDPPort = 60_001
    profile.moshServerPath = "/usr/local/bin/mosh-server"
    let restored = try JSONDecoder().decode(
        ConnectionProfile.self,
        from: JSONEncoder().encode(profile)
    )

    #expect(restored.sshTerminalProtocol == .mosh)
    #expect(restored.moshUDPPort == 60_001)
    #expect(restored.moshServerPath == "/usr/local/bin/mosh-server")
}

@Test("Mosh client discovery prefers standard package manager locations")
func moshExecutableDiscovery() {
    let found = MoshService.executablePath(
        environment: ["PATH": "/custom/bin:/another/bin"],
        isExecutable: { $0 == "/usr/local/bin/mosh" || $0 == "/custom/bin/mosh" }
    )
    #expect(found == "/usr/local/bin/mosh")

    let pathFallback = MoshService.executablePath(
        environment: ["PATH": "/custom/bin:/another/bin"],
        isExecutable: { $0 == "/custom/bin/mosh" }
    )
    #expect(pathFallback == "/custom/bin/mosh")
}

@Test("Mosh launch reuses safe OpenSSH bootstrap arguments")
func moshLaunchArguments() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.friendlyName = "Mobile server"
    profile.host = "server.example.com"
    profile.username = "alice"
    profile.sshPort = 2_222
    profile.sshTerminalProtocol = .mosh
    profile.moshUDPPort = 60_007
    profile.moshServerPath = "/opt/mosh server/bin/mosh-server"
    profile.sshCompression = true
    profile.sshAgentForwarding = true

    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let launch = try MoshService.launchConfiguration(
        settings: settings,
        executablePath: "/opt/homebrew/bin/mosh"
    )

    #expect(launch.executable == "/opt/homebrew/bin/mosh")
    #expect(launch.arguments.contains("--port"))
    #expect(launch.arguments.contains("60007"))
    #expect(launch.arguments.contains("--server=/opt/mosh server/bin/mosh-server"))
    #expect(launch.arguments.last == "server.example.com")
    let sshOption = try #require(launch.arguments.first)
    #expect(sshOption.hasPrefix("--ssh="))
    #expect(sshOption.contains("'/usr/bin/ssh'"))
    #expect(sshOption.contains("'2222'"))
    #expect(sshOption.contains("'User=alice'"))
    #expect(sshOption.contains("'-A'"))
    #expect(!sshOption.contains("-tt"))
}

@Test("Mosh validates UDP port and local client availability")
func moshLaunchValidation() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.moshUDPPort = 70_000
    let invalidPortSettings = try SSHConnectionSettings(profile: profile, identity: nil)
    #expect(throws: MoshServiceError.self) {
        try MoshService.launchConfiguration(
            settings: invalidPortSettings,
            executablePath: "/opt/homebrew/bin/mosh"
        )
    }

    profile.moshUDPPort = 0
    let missingClientSettings = try SSHConnectionSettings(profile: profile, identity: nil)
    #expect(throws: MoshServiceError.self) {
        try MoshService.launchConfiguration(
            settings: missingClientSettings,
            executableLookup: { nil }
        )
    }
}

@Test("Missing remote mosh-server gets an actionable message")
func moshMissingServerFailureMessage() {
    let output = """
    bash: line 1: mosh-server: command not found
    /opt/homebrew/bin/mosh: Did not find mosh server startup message.
    """
    let message = MoshService.userFacingFailure(output: output, exitCode: 10)
    #expect(message?.contains("Установите пакет mosh на сервере") == true)
    #expect(MoshService.userFacingFailure(output: output, exitCode: 0) == nil)
    #expect(MoshService.userFacingFailure(output: "network error", exitCode: 1) == nil)
}
