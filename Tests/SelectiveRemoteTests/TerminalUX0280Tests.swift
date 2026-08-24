import Foundation
import Testing
@testable import SelectiveRemote

@Test("Legacy snippet targets migrate to typed SSH targets")
func legacySnippetTargetsMigrate() throws {
    let profileID = UUID()
    let json = """
    {"id":"\(UUID().uuidString)","profileID":"\(profileID.uuidString)","title":"Legacy","command":"pwd","category":"Ops","groupID":"\(UUID().uuidString)","targetProfileIDs":["\(profileID.uuidString)"],"updatedAt":0}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let snippet = try decoder.decode(TerminalCommandTemplate.self, from: Data(json.utf8))
    #expect(snippet.targets == [.sshProfile(profileID)])
    #expect(!snippet.includesLocalTerminal)
}

@Test("Typed local terminal target survives persistence")
@MainActor func localTerminalTargetRoundTrip() throws {
    let snippet = TerminalCommandTemplate(
        id: UUID(),
        profileID: TerminalCommandHistoryStore.globalSnippetLibraryID,
        title: "Local",
        command: "pwd",
        category: "",
        groupID: TerminalCommandTemplate.legacyUnassignedGroupID,
        targets: [.localTerminal],
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let restored = try JSONDecoder().decode(
        TerminalCommandTemplate.self,
        from: JSONEncoder().encode(snippet)
    )
    #expect(restored.targets == [.localTerminal])
    #expect(restored.targetProfileIDs.isEmpty)
}

@Test("New snippets may remain ungrouped and preserve a local target")
@MainActor func ungroupedSnippetPersistence() throws {
    let suite = "TerminalUX0280Tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TerminalCommandHistoryStore(defaults: defaults)

    #expect(store.saveTemplate(
        id: nil,
        title: "Local",
        command: "pwd",
        category: "",
        groupID: TerminalCommandTemplate.legacyUnassignedGroupID,
        profileID: TerminalCommandHistoryStore.globalSnippetLibraryID,
        targets: [.localTerminal]
    ))
    let saved = try #require(store.templates().first)
    #expect(saved.groupID == TerminalCommandTemplate.legacyUnassignedGroupID)
    #expect(saved.category.isEmpty)
    #expect(saved.targets == [.localTerminal])
}

@Test("Snippet navigation uses group identity and both toolbars share one container")
func snippetGroupAndToolbarSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let snippets = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalSnippetsLibraryView.swift"))
    let content = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/ContentView.swift"))
    let local = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/LocalTerminalView.swift"))
    let ssh = try String(contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift"))

    #expect(snippets.contains("preferredGroupID: selectedGroupID"))
    #expect(snippets.contains("Text(\"Без группы\")"))
    #expect(!snippets.contains("groups.first(where: { $0.name == preferredGroup })"))
    #expect(content.contains("case .snippets: \"curlybraces\""))
    #expect(local.contains(".terminalToolbarContainer()"))
    #expect(ssh.contains(".terminalToolbarContainer()"))
    #expect(local.contains("Image(systemName: \"curlybraces\")"))
    #expect(ssh.contains("Image(systemName: \"curlybraces\")"))
    #expect(local.contains("Button(\"Развернуть терминал\""))
    #expect(local.contains("Button(\"Вернуть интерфейс\""))
    #expect(local.contains("Image(systemName: \"ellipsis.circle\")"))
}
