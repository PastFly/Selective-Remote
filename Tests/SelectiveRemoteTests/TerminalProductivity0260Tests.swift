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


@Test("SSH automation fields preserve legacy defaults through Codable")
func sshAutomationCodableDefaults() throws {
    let legacyJSON = #"{"connectionType":"ssh","friendlyName":"Legacy","host":"example.test","username":"admin"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: legacyJSON)
    #expect(decoded.sshStartupSnippetID == nil)
    #expect(decoded.sshStartupSnippetMode == .disabled)
    #expect(decoded.sshStartupSnippetAfterReconnect == false)
    #expect(decoded.terminalVariables.isEmpty)
    #expect(decoded.sshGroupInheritance == SSHGroupInheritance())

    var profile = ConnectionProfile(connectionType: .ssh)
    profile.sshStartupSnippetMode = .automatic
    profile.terminalVariables = [TerminalVariable(name: "PROJECT_PATH", value: "/opt/app")]
    profile.sshGroupInheritance.keepAlive = true
    let roundTrip = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
    #expect(roundTrip.sshStartupSnippetMode == .automatic)
    #expect(roundTrip.terminalVariables.first?.name == "PROJECT_PATH")
    #expect(roundTrip.sshGroupInheritance.keepAlive)
}

@Test("Terminal variables reject secrets and profile overrides group")
func terminalVariableSafetyAndPrecedence() {
    #expect(TerminalVariable.normalizedName("project_path") == "PROJECT_PATH")
    #expect(TerminalVariable.normalizedName("api_token") == nil)
    #expect(TerminalVariable.normalizedName("HOST") == nil)
    let merged = TerminalVariableResolver.mergedVariables(
        group: [TerminalVariable(name: "PROJECT_PATH", value: "/group")],
        profile: [TerminalVariable(name: "PROJECT_PATH", value: "/profile")]
    )
    #expect(merged.count == 1)
    #expect(merged.first?.value == "/profile")
}

@Test("Group configuration persists and inherited SSH settings stay granular")
@MainActor
func groupSSHInheritance() {
    let suite = "SelectiveRemoteTests.Group.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SSHGroupConfigurationStore(defaults: defaults)
    store.update(groupName: "Production") { config in
        config.username = "deploy"
        config.port = 2222
        config.keepAliveSeconds = 45
        config.variables = [TerminalVariable(name: "PROJECT_PATH", value: "/srv/app")]
    }
    #expect(store.configuration(for: "production")?.username == "deploy")
    #expect(store.configuration(for: "Production")?.port == 2222)
}

@Test("Terminal history payload carries non-secret variables")
@MainActor
func historyPayloadCarriesVariables() throws {
    let suite = "SelectiveRemoteTests.HistoryVariables.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let id = UUID()
    let json = try #require(store.webPayload(
        for: id,
        variables: ["PROJECT_PATH": "/opt/app", "HOST": "example.test"]
    ))
    let data = try #require(json.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let variables = try #require(object["variables"] as? [String: String])
    #expect(variables["PROJECT_PATH"] == "/opt/app")
    #expect(variables["HOST"] == "example.test")
}

@Test("Terminal JS substitutes known template variables before prompting")
func knownTemplateVariablesSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal-host.js"),
        encoding: .utf8
    )
    #expect(source.contains("let templateVariables = {}"))
    #expect(source.contains("hasOwnProperty.call(templateVariables, name)"))
    #expect(source.contains("payload.variables"))
}


@Test("Named Workspace store persists and updates the same name")
@MainActor
func namedWorkspaceStorePersists() throws {
    let suite = "SelectiveRemoteTests.NamedWorkspace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let scope = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: scope,
        primarySession: TerminalSessionModel(),
        primaryConnection: .custom(host: "one.example", username: "root"),
        defaults: defaults
    )
    let snapshot = workspace.workspaceSnapshot()
    let store = TerminalNamedWorkspaceStore(defaults: defaults)
    let first = try #require(store.save(name: "Production", scopeID: scope, snapshot: snapshot))
    #expect(store.workspaces(for: scope).count == 1)

    workspace.renameTab(workspace.selectedTabID, to: "Primary")
    let updated = try #require(store.save(name: "production", scopeID: scope, snapshot: workspace.workspaceSnapshot()))
    #expect(updated.id == first.id)
    #expect(store.workspaces(for: scope).count == 1)

    let reloaded = TerminalNamedWorkspaceStore(defaults: defaults)
    #expect(reloaded.workspaces(for: scope).first?.snapshot.tabs.first?.title == "Primary")
}

@Test("Named Workspace restores layout, connections and full pane appearance without connecting")
@MainActor
func namedWorkspaceRestoresSafely() throws {
    let suite = "SelectiveRemoteTests.NamedWorkspaceRestore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let scope = UUID()
    let firstProfile = UUID()
    let secondProfile = UUID()
    let workspace = TerminalWorkspaceModel(
        profileID: scope,
        primarySession: TerminalSessionModel(),
        primaryConnection: .savedProfile(firstProfile),
        defaults: defaults
    )
    workspace.renameTab(workspace.selectedTabID, to: "API")
    let firstID = workspace.selectedTabID
    let second = try #require(workspace.addTab(
        connection: .savedProfile(secondProfile),
        title: "Database"
    ))
    workspace.setLayout(.splitHorizontal)
    workspace.selectedTabID = firstID
    workspace.selectSecondary(second.id)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.applyPreset(.dracula)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.fontSize = 18
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.syntaxFollowTheme = false

    let snapshot = workspace.workspaceSnapshot()
    workspace.renameTab(firstID, to: "Changed")
    workspace.setLayout(.single)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.applyPreset(.hackerGreen)
    workspace.tabs.first(where: { $0.id == firstID })?.appearance.fontSize = 12

    #expect(workspace.restoreWorkspaceSnapshot(snapshot))
    #expect(!workspace.hasRunningSession)
    #expect(workspace.tabs.count == 2)
    #expect(workspace.layout == .splitHorizontal)
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.title == "API")
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.connection == .savedProfile(firstProfile))
    #expect(workspace.tabs.first(where: { $0.id == second.id })?.connection == .savedProfile(secondProfile))
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.appearance.selectedPreset == .dracula)
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.appearance.fontSize == 18)
    #expect(workspace.tabs.first(where: { $0.id == firstID })?.appearance.syntaxFollowTheme == false)
}

@Test("Named Workspaces are exposed in SSH and Local Terminal and never auto-connect on restore")
func namedWorkspaceSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let ssh = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift"),
        encoding: .utf8
    )
    let local = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/LocalTerminalView.swift"),
        encoding: .utf8
    )
    let workspace = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalWorkspace.swift"),
        encoding: .utf8
    )
    #expect(ssh.contains("TerminalNamedWorkspaceView"))
    #expect(local.contains("TerminalNamedWorkspaceView"))
    #expect(workspace.contains("guard !hasRunningSession else { return false }"))
    #expect(workspace.contains("restoreWorkspaceSnapshot"))
}
