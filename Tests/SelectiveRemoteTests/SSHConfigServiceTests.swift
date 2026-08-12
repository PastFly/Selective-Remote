import Foundation
import Testing
@testable import SelectiveRemote

@Test("SSH config импортирует только конкретные Host и основные параметры")
func parsesConcreteSSHConfigHosts() throws {
    let hosts = SSHConfigService.parse(
        """
        Host *
          ServerAliveInterval 30

        Host bastion
          HostName bastion.example.com
          User admin
          Port 2222
          IdentityFile ~/.ssh/id_ed25519

        Host prod-db
          HostName 10.10.20.30
          User root
          ProxyJump bastion

        Host wildcard-*
          User ignored
        """
    )

    #expect(hosts.count == 2)
    let bastion = try #require(hosts.first(where: { $0.alias == "bastion" }))
    #expect(bastion.hostName == "bastion.example.com")
    #expect(bastion.user == "admin")
    #expect(bastion.port == 2222)
    #expect(bastion.identityFile?.hasSuffix("/.ssh/id_ed25519") == true)

    let prod = try #require(hosts.first(where: { $0.alias == "prod-db" }))
    #expect(prod.proxyJump == "bastion")
    #expect(prod.port == 22)
}

@Test("ProxyJump добавляется в аргументы системного OpenSSH")
func buildsProxyJumpArguments() throws {
    var target = ConnectionProfile(connectionType: .ssh)
    target.host = "internal.example.com"
    target.username = "root"

    var jump = ConnectionProfile(connectionType: .ssh)
    jump.host = "bastion.example.com"
    jump.username = "admin"
    jump.sshPort = 2222

    let settings = try SSHConnectionSettings(
        profile: target,
        identity: nil,
        jumpHost: jump
    )
    let arguments = SSHService.interactiveSSHArguments(settings: settings)

    let index = try #require(arguments.firstIndex(of: "-J"))
    #expect(arguments[index + 1] == "admin@bastion.example.com:2222")
    #expect(arguments.last == "internal.example.com")
}

@Test("Jump Host имеет приоритет над HTTP/SOCKS proxy целевого профиля")
func proxyJumpSuppressesTargetProxyCommand() throws {
    var target = ConnectionProfile(connectionType: .ssh)
    target.host = "internal.example.com"
    target.sshProxyMode = .http
    target.sshProxyHost = "proxy.example.com"
    target.sshProxyPort = 8080

    var jump = ConnectionProfile(connectionType: .ssh)
    jump.host = "bastion.example.com"

    let settings = try SSHConnectionSettings(profile: target, identity: nil, jumpHost: jump)
    let arguments = SSHService.interactiveSSHArguments(settings: settings)

    #expect(arguments.contains("-J"))
    #expect(!arguments.contains(where: { $0.hasPrefix("ProxyCommand=") }))
}
