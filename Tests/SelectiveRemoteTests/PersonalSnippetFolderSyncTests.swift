import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Personal Snippet folder synchronization")
@MainActor
struct PersonalSnippetFolderSyncTests {
    private func withStore(_ body: (TerminalCommandHistoryStore, UserDefaults) throws -> Void) throws {
        let name = "personal-snippet-sync-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(TerminalCommandHistoryStore(defaults: defaults), defaults)
    }

    private func snippet(_ folder: String, groupID: UUID? = nil) -> TerminalCommandTemplate {
        .init(id: UUID(), profileID: TerminalCommandHistoryStore.globalSnippetLibraryID,
              title: "Sync test", command: "printf test", category: folder,
              groupID: groupID, targets: [.localTerminal], isExplicitlyUngrouped: folder.isEmpty,
              updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("download creates a nested group immediately without restarting the store")
    func incomingGroup() throws {
        try withStore { store, defaults in
            let value = snippet("Work/Deploy")
            store.replaceSyncedTemplates([value])
            let restored = try #require(store.template(id: value.id))
            let group = try #require(store.snippetGroup(id: restored.groupID))
            #expect(group.name == "Work/Deploy")
            #expect(restored.targets == [.localTerminal])
            #expect(TerminalCommandHistoryStore(defaults: defaults).snippetGroup(id: restored.groupID)?.name == "Work/Deploy")
        }
    }

    @Test("initial import materializes categories and an explicitly ungrouped snippet stays ungrouped")
    func initialImport() throws {
        try withStore { store, _ in
            let root = snippet("")
            let grouped = snippet("A/B")
            store.importTemplates([root, grouped])
            #expect(store.template(id: root.id)?.groupID == TerminalCommandTemplate.legacyUnassignedGroupID)
            let groupID = try #require(store.template(id: grouped.id)?.groupID)
            #expect(store.snippetGroup(id: groupID)?.name == "A/B")
        }
    }

    @Test("browser move and move to root are reflected on the same running store")
    func incomingMove() throws {
        try withStore { store, _ in
            var value = snippet("Old/Folder", groupID: UUID())
            store.replaceSyncedTemplates([value])
            value.category = "New/Child"
            value.groupID = TerminalCommandTemplate.legacyUnassignedGroupID
            store.replaceSyncedTemplates([value])
            let moved = try #require(store.template(id: value.id))
            #expect(store.snippetGroup(id: moved.groupID)?.name == "New/Child")
            value.category = ""
            value.isExplicitlyUngrouped = true
            store.replaceSyncedTemplates([value])
            #expect(store.template(id: value.id)?.groupID == TerminalCommandTemplate.legacyUnassignedGroupID)
            #expect(store.template(id: value.id)?.category == "")
        }
    }

    @Test("incoming native group IDs are preserved across clients instead of re-exporting local aliases")
    func stableIdentity() throws {
        try withStore { store, _ in
            _ = store.createSnippetGroup(name: "Work/Deploy", profileID: TerminalCommandHistoryStore.globalSnippetLibraryID)
            let incomingID = UUID()
            let value = snippet("Work/Deploy", groupID: incomingID)
            store.replaceSyncedTemplates([value])
            #expect(store.template(id: value.id)?.groupID == incomingID)
            #expect(store.snippetGroups().filter { $0.name == "Work/Deploy" }.count == 1)
            #expect(store.snippetGroup(id: incomingID)?.name == "Work/Deploy")
            let revision = store.snippetRevision
            store.replaceSyncedTemplates([value])
            #expect(store.snippetRevision == revision)
        }
    }

    @Test("native exporter retains nested category and template fields without API changes")
    func exportRoundTrip() throws {
        let value = snippet("Work/Deploy", groupID: UUID())
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [], credentials: [], snippets: [value], forwarding: [], deviceID: UUID()
        )
        let restored = try SelectiveRemotePersonalVaultImporter.decode(exported.document)
        #expect(restored.snippets == [value])
    }
}
