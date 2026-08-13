import Foundation
import Testing
@testable import SelectiveRemote

@Test("Forwarding Manager namespace различает Profile и Independent с одинаковым UUID")
func forwardingManagerNamespacesTunnelIDs() {
    let shared = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let profileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    let profile = ForwardingManagerSource.profile(profileID: profileID, ruleID: shared)
    let independent = ForwardingManagerSource.independent(tunnelID: shared)

    #expect(profile.stableID != independent.stableID)
    #expect(profile.tunnelID == shared)
    #expect(independent.tunnelID == shared)
}

@Test("Forwarding Manager классифицирует только подтверждаемые точки ошибок")
func forwardingManagerClassifiesKnownFailures() {
    #expect(
        ForwardingFailureStage.classify("bind [127.0.0.1]:5432: Address already in use")
            == .localBind
    )
    #expect(
        ForwardingFailureStage.classify("Permission denied (publickey,password).")
            == .authentication
    )
    #expect(
        ForwardingFailureStage.classify("Could not resolve hostname server.invalid")
            == .sshServer
    )
    #expect(
        ForwardingFailureStage.classify("SOCKS5 proxy connection failed")
            == .proxy
    )
    #expect(
        ForwardingFailureStage.classify("unexpected child exit")
            == .unknown
    )
}

@Test("Forwarding Manager не считает Dynamic туннель фиксированным Destination")
func forwardingManagerDynamicDestinationIsNotInvented() {
    let rule = PortForwardRule(kind: .dynamic)
    let item = ForwardingManagerItem(
        source: .independent(tunnelID: rule.id),
        ownership: .independent,
        profileName: "SOCKS",
        connection: .custom(host: "server.example.com", username: "alice"),
        rule: rule,
        host: "server.example.com",
        username: "alice",
        port: 22,
        authentication: "Автоматически",
        identityName: nil,
        jumpHost: nil,
        proxy: nil,
        state: .stopped,
        startedAt: nil,
        lastError: nil,
        hasLog: false
    )

    #expect(item.destination == "Dynamic / SOCKS")
}

@Test("Forwarding Manager сохраняет разные схемы Local Remote Dynamic и реальные route nodes")
func forwardingManagerSourceContainsRequiredRouteBranches() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ForwardingManager.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("case .local:"))
    #expect(source.contains("case .remote:"))
    #expect(source.contains("case .dynamic:"))
    #expect(source.contains("title: \"Jump Host\""))
    #expect(source.contains("title: \"Proxy\""))
    #expect(source.contains("title: \"Dynamic destination\""))
    #expect(source.contains("Destination отмечается как неизвестное"))
}

@Test("Forwarding Manager агрегирует существующие stores и не создаёт второй tunnel manager")
func forwardingManagerUsesExistingRuntimeStores() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectRoot.appendingPathComponent(
            "Sources/SelectiveRemote/ForwardingManager.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("model.profiles"))
    #expect(source.contains("model.independentPortForwards"))
    #expect(source.contains("model.sshTunnels"))
    #expect(source.contains("model.sshTunnelLastErrors"))
    #expect(!source.contains("ForwardingSessionManager"))
    #expect(!source.contains("Traffic: 24 MB"))
}
