import Foundation
import Testing
@testable import SelectiveRemote

private final class FailingSnippetDefaults: UserDefaults {
    var blockedKey: String?
    var writeFailed = false
    override func set(_ value: Any?, forKey key: String) {
        if key == blockedKey {
            writeFailed = true
            return
        }
        super.set(value, forKey: key)
    }
    override func synchronize() -> Bool {
        !writeFailed && super.synchronize()
    }
}

@Test("A failed Snippet folder write recovers the complete transaction")
@MainActor
func interruptedSnippetFolderWriteRecovers() throws {
    let suite = "TEST-SnippetTransaction-\(UUID().uuidString)"
    let defaults = try #require(FailingSnippetDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = UUID()
    let store = TerminalCommandHistoryStore(defaults: defaults)
    let group = try #require(store.createSnippetGroup(name: "Before", profileID: profile))
    #expect(store.saveTemplate(id: nil, title: "Synthetic", command: "echo test",
                               category: group.name, groupID: group.id, profileID: profile,
                               targets: [.localTerminal]))
    let template = try #require(store.templates().first)
    defaults.blockedKey = NativeStorageMigration.newKey(for: "SelectiveRemote.terminal.commandTemplates.v1")!
    #expect(!store.renameSnippetGroup(id: group.id, name: "After", profileID: profile))
    #expect(store.snippetPersistenceFailed)
    #expect(!store.removeTemplate(id: template.id))
    defaults.blockedKey = nil
    defaults.writeFailed = false
    let restarted = TerminalCommandHistoryStore(defaults: defaults)
    #expect(!restarted.snippetPersistenceFailed)
    #expect(restarted.snippetGroup(id: group.id)?.name == "After")
    #expect(restarted.template(id: template.id)?.groupID == group.id)
    #expect(restarted.template(id: template.id)?.category == "After")
    #expect(defaults.object(forKey: "SelectiveRemote.native032.snippets.pending.v1") == nil)
}

@Test("Corrupt Snippet transaction fails closed")
@MainActor
func corruptSnippetTransactionFailsClosed() throws {
    let suite = "TEST-SnippetTransaction-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("corrupt".utf8), forKey: "SelectiveRemote.native032.snippets.pending.v1")
    let store = TerminalCommandHistoryStore(defaults: defaults)
    #expect(store.snippetPersistenceFailed)
    #expect(store.createSnippetGroup(name: "No write", profileID: UUID()) == nil)
    #expect(defaults.data(forKey: "SelectiveRemote.native032.snippets.pending.v1") == Data("corrupt".utf8))
}
