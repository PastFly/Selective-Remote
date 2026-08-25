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


@Test("Adaptive workspace breakpoints cover compact, regular, and 8K widths")
func adaptiveWorkspaceBreakpoints() {
    #expect(AdaptiveWorkspaceLayout.usesSingleColumnProfileEditor(width: 720))
    #expect(!AdaptiveWorkspaceLayout.usesSingleColumnProfileEditor(width: 1_200))
    #expect(AdaptiveWorkspaceLayout.usesStackedSFTPPanes(width: 900))
    #expect(!AdaptiveWorkspaceLayout.usesStackedSFTPPanes(width: 1_400))
    #expect(AdaptiveWorkspaceLayout.usesDetailNavigation(width: 900))
    #expect(!AdaptiveWorkspaceLayout.usesDetailNavigation(width: 1_400))
    #expect(AdaptiveWorkspaceLayout.showsProfileInspector(width: 7_680))
}
