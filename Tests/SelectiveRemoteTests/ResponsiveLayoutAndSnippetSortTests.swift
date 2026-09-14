import Foundation
import Testing
@testable import SelectiveRemote

@Test("Legacy snippet groups decode their modification date without data loss")
func legacySnippetGroupModificationDateMigration() throws {
    let id = UUID()
    let profileID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let legacy: [String: Any] = [
        "id": id.uuidString,
        "profileID": profileID.uuidString,
        "name": "Legacy",
        "createdAt": createdAt.timeIntervalSinceReferenceDate
    ]
    let data = try JSONSerialization.data(withJSONObject: legacy)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let decoded = try decoder.decode(TerminalSnippetGroup.self, from: data)

    #expect(decoded.id == id)
    #expect(decoded.updatedAt == createdAt)
}

@Test("Root snippet groups sort by the newest child modification")
func rootSnippetGroupsSortByModificationDate() {
    let profileID = UUID()
    let old = Date(timeIntervalSince1970: 1_000)
    let middle = Date(timeIntervalSince1970: 2_000)
    let newest = Date(timeIntervalSince1970: 3_000)
    let first = TerminalSnippetGroup(
        id: UUID(),
        profileID: profileID,
        name: "First",
        createdAt: old
    )
    let second = TerminalSnippetGroup(
        id: UUID(),
        profileID: profileID,
        name: "Second",
        createdAt: middle
    )
    let modifiedChild = TerminalCommandTemplate(
        id: UUID(),
        profileID: profileID,
        title: "Recently edited",
        command: "uptime",
        category: first.name,
        groupID: first.id,
        updatedAt: newest
    )

    let descending = TerminalSnippetRootGroupSorter.sorted(
        [first, second],
        templates: [modifiedChild],
        byModifiedDate: true,
        ascending: false
    )
    #expect(descending.map(\.id) == [first.id, second.id])

    let ascending = TerminalSnippetRootGroupSorter.sorted(
        [first, second],
        templates: [modifiedChild],
        byModifiedDate: true,
        ascending: true
    )
    #expect(ascending.map(\.id) == [second.id, first.id])
}

@Test("Connection Center and Forwarding use compact vertical layouts")
func narrowManagerLayoutsAreAdaptive() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let center = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/SelectiveRemote/ConnectionCenter.swift"
        ),
        encoding: .utf8
    )
    let forwarding = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/SelectiveRemote/ForwardingManager.swift"
        ),
        encoding: .utf8
    )

    #expect(center.contains("AdaptiveWorkspaceLayout.usesDetailNavigation"))
    #expect(center.contains("compactInspector("))
    #expect(center.contains("compactConnectionList"))
    #expect(!center.contains("VSplitView"))
    #expect(forwarding.contains("AdaptiveWorkspaceLayout.usesDetailNavigation"))
    #expect(forwarding.contains("compactInspector("))
    #expect(forwarding.contains("compactTunnelList"))
    #expect(!forwarding.contains("VSplitView"))
}

@Test("Credential Vault uses compact navigation and wrapping metadata")
func credentialVaultLayoutIsAdaptive() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let vault = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/SelectiveRemote/CredentialVaultView.swift"
        ),
        encoding: .utf8
    )

    #expect(vault.contains("GeometryReader"))
    #expect(vault.contains("AdaptiveWorkspaceLayout.usesDetailNavigation"))
    #expect(vault.contains("compactDetailPresented"))
    #expect(vault.contains("compactInspector"))
    #expect(vault.contains("ViewThatFits(in: .horizontal)"))
    #expect(vault.contains("GridItem(.adaptive"))
    #expect(!vault.contains("inspector\n                    .frame(minWidth: 520)"))
}


@Test("Adaptive workspace breakpoints cover compact, regular, and 8K widths")
func adaptiveWorkspaceBreakpoints() {
    #expect(AdaptiveWorkspaceLayout.usesSingleColumnProfileEditor(width: 720))
    #expect(!AdaptiveWorkspaceLayout.usesSingleColumnProfileEditor(width: 1_200))
    #expect(AdaptiveWorkspaceLayout.usesStackedSFTPPanes(width: 900))
    #expect(!AdaptiveWorkspaceLayout.usesStackedSFTPPanes(width: 1_400))
    #expect(AdaptiveWorkspaceLayout.usesSingleSFTPPane(width: 900))
    #expect(!AdaptiveWorkspaceLayout.usesSingleSFTPPane(width: 1_400))
    #expect(AdaptiveWorkspaceLayout.usesDetailNavigation(width: 900))
    #expect(!AdaptiveWorkspaceLayout.usesDetailNavigation(width: 1_400))
    #expect(AdaptiveWorkspaceLayout.showsProfileInspector(width: 7_680))
}

@Test("Hosts navigator collapses and compact SFTP preserves the file list")
func hostsAndSFTPUseSpaceEfficientLayouts() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let content = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"),
        encoding: .utf8
    )
    let teamHosts = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CloudTeamHosts.swift"),
        encoding: .utf8
    )
    let sftp = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/SFTPWorkspace.swift"),
        encoding: .utf8
    )

    #expect(content.contains("personal-host.navigator-visible.v1"))
    #expect(content.contains("Свернуть список хостов"))
    #expect(content.contains("profile.tags.isEmpty ? 48 : 64"))
    #expect(content.contains("personalHostsPresentationID = UUID()"))
    #expect(content.contains("personalHostInsertionIndicator"))
    #expect(content.contains("setPersonalHostDropTarget"))
    #expect(teamHosts.contains("team-host.navigator-visible.v1"))
    #expect(teamHosts.contains("Свернуть список Team Hosts"))
    #expect(sftp.contains("AdaptiveWorkspaceLayout.usesSingleSFTPPane"))
    #expect(sftp.contains("SFTPWorkspaceCompactPane"))
    #expect(sftp.contains("Переключить файловую панель"))
    #expect(sftp.contains(".frame(minHeight: 160)"))
    #expect(!sftp.contains("VSplitView"))
}
