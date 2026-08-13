import Foundation
import Testing
@testable import SelectiveRemote

private func serverCommandsSettings() throws -> SSHConnectionSettings {
    var profile = ConnectionProfile()
    profile.connectionType = .ssh
    profile.host = "server.example.test"
    profile.username = "operator"
    return try SSHConnectionSettings(profile: profile, identity: nil)
}

@Test("Server Commands 2.0 разбирает реальные службы, контейнеры и capabilities")
func serverCommandsParsesStructuredDiscovery() throws {
    let snapshot = TerminalRemoteContextService.parse(
        output: """
        SYSTEM\tDebian GNU/Linux 13
        OS\tdebian\t
        COMMAND\tsystemctl
        COMMAND\tjournalctl
        COMMAND\tdocker
        COMMAND\tapt
        COMMAND\tip
        COMMAND\tss
        COMMAND\tdf
        COMMAND\tlsblk
        COMMAND\twho
        SERVICE\tssh.service\tactive\trunning
        SERVICE\tnginx.service\tfailed\tfailed
        CONTAINER\tdocker\tweb-api\tUp 4 hours
        """,
        settings: try serverCommandsSettings()
    )

    #expect(snapshot.systemLabel == "Debian GNU/Linux 13")
    #expect(snapshot.osID == "debian")
    #expect(snapshot.hasCommand("systemctl"))
    #expect(snapshot.hasCommand("docker"))
    #expect(snapshot.services.count == 2)
    #expect(snapshot.services.first(where: { $0.name == "ssh.service" })?.isActive == true)
    #expect(snapshot.services.first(where: { $0.name == "nginx.service" })?.activeState == "failed")
    #expect(snapshot.containers == [
        TerminalRemoteContainer(tool: "docker", name: "web-api", status: "Up 4 hours")
    ])
}

@Test("Server Commands 2.0 строит действия только из реально найденных утилит")
func serverCommandsCatalogUsesDiscoveredCapabilities() throws {
    let snapshot = TerminalRemoteContextService.parse(
        output: """
        SYSTEM\tDebian GNU/Linux 13
        OS\tdebian\t
        COMMAND\tsystemctl
        COMMAND\tjournalctl
        COMMAND\tapt
        COMMAND\tip
        COMMAND\tdf
        COMMAND\twho
        SERVICE\tssh.service\tactive\trunning
        """,
        settings: try serverCommandsSettings()
    )

    let system = ServerCommandCatalog.actions(for: .system, context: snapshot)
    let network = ServerCommandCatalog.actions(for: .network, context: snapshot)
    let disks = ServerCommandCatalog.actions(for: .disks, context: snapshot)
    let security = ServerCommandCatalog.actions(for: .security, context: snapshot)

    #expect(system.contains { $0.command == "apt list --upgradable 2>/dev/null" })
    #expect(!system.contains { $0.command.contains("dnf") })
    #expect(network.contains { $0.command == "ip -brief address" })
    #expect(!network.contains { $0.command.hasPrefix("ss ") })
    #expect(disks.contains { $0.command == "df -hT" })
    #expect(security.contains { $0.command == "who" })

    let ssh = try #require(snapshot.services.first)
    let serviceActions = ServerCommandCatalog.serviceActions(ssh, context: snapshot)
    #expect(serviceActions.contains { $0.command == "systemctl status ssh.service --no-pager" })
    #expect(serviceActions.contains { $0.command == "sudo systemctl restart ssh.service" })
    #expect(serviceActions.contains { $0.command == "sudo systemctl reload ssh.service" })
    #expect(serviceActions.contains { $0.command == "journalctl -u ssh.service -n 100 --no-pager" })
}

@Test("RHEL-like discovery предлагает DNF и Podman без выдуманного Docker")
func serverCommandsUsesRHELLikeTools() throws {
    let snapshot = TerminalRemoteContextService.parse(
        output: """
        SYSTEM\tRocky Linux 9.6
        OS\trocky\trhel fedora
        COMMAND\tdnf
        COMMAND\tpodman
        CONTAINER\tpodman\tworker\tExited (0) 2 hours ago
        """,
        settings: try serverCommandsSettings()
    )

    let system = ServerCommandCatalog.actions(for: .system, context: snapshot)
    #expect(system.contains { $0.command == "dnf check-update" })
    #expect(!snapshot.hasCommand("docker"))
    #expect(snapshot.containers.first?.tool == "podman")
    #expect(ServerCommandCatalog.containerActions(try #require(snapshot.containers.first)).contains {
        $0.command == "podman restart worker"
    })
}

@Test("Discovery не принимает shell-метасимволы в именах runtime entities")
func serverCommandsRejectsUnsafeRuntimeNames() throws {
    let snapshot = TerminalRemoteContextService.parse(
        output: """
        SYSTEM\tLinux
        COMMAND\tsystemctl
        COMMAND\tdocker
        SERVICE\tgood.service\tactive\trunning
        SERVICE\tbad;rm.service\tactive\trunning
        CONTAINER\tdocker\tgood-container\tUp
        CONTAINER\tdocker\tbad$(id)\tUp
        """,
        settings: try serverCommandsSettings()
    )

    #expect(snapshot.services.map(\.name) == ["good.service"])
    #expect(snapshot.containers.map(\.name) == ["good-container"])
    #expect(ServerCommandCatalog.isSafeRemoteIdentifier("ssh.service"))
    #expect(!ServerCommandCatalog.isSafeRemoteIdentifier("ssh.service; reboot"))
}
