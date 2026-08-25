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

    #expect(center.contains("proxy.size.width < 900"))
    #expect(center.contains("VSplitView"))
    #expect(center.contains("compactConnectionList"))
    #expect(forwarding.contains("proxy.size.width < 940"))
    #expect(forwarding.contains("VSplitView"))
    #expect(forwarding.contains("compactTunnelList"))
}
