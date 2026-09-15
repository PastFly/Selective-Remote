import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Team Snippet materialization")
struct CloudTeamSnippetsTests {
    @MainActor
    @Test("Team Snippet Targets are personal persistent assignments")
    func targetAssignmentsPersistLocally() throws {
        let suiteName = "CloudTeamSnippetTargetsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "targets"
        let first = UUID()
        let second = UUID()

        let store = SelectiveRemoteTeamSnippetTargetStore(defaults: defaults, defaultsKey: key)
        store.setTargets([second, first, second], for: Self.snippetID)

        #expect(Set(store.targets(for: Self.snippetID)) == Set([first, second]))
        let restored = SelectiveRemoteTeamSnippetTargetStore(defaults: defaults, defaultsKey: key)
        #expect(Set(restored.targets(for: Self.snippetID)) == Set([first, second]))
        restored.setTargets([], for: Self.snippetID)
        #expect(restored.targets(for: Self.snippetID).isEmpty)
    }

    @Test("Team Snippet UI exposes explicit run, target assignment, and context menu")
    func teamSnippetActionsAreAvailable() throws {
        let root = Self.packageRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CloudTeamSnippets.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".contextMenu { snippetActions(snippet) }"))
        #expect(source.contains("ru: \"Настроить хосты…\""))
        #expect(source.contains("model.runTerminalSnippet(executable)"))
        #expect(source.contains("ru: \"Выбор хранится только на этом Mac"))
        #expect(source.contains("TimelineView(.periodic(from: .now, by: 60))"))
        #expect(source.contains("ru: \"Изменён "))
        #expect(!source.contains("Text(snippet.modifiedDate, style: .relative)"))
    }

    @Test("App startup and Cloud session changes refresh Team Snippets immediately")
    func applicationLifecycleTriggersImmediateRefresh() throws {
        let root = Self.packageRoot()
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/SelectiveRemoteApp.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CloudSettingsView.swift"),
            encoding: .utf8
        )

        #expect(app.contains("await teamVaultAutoSync.start()\n                _ = try? await teamVaultAutoSync.synchronizeConfiguredAccountNow()"))
        #expect(app.contains("for: .selectiveRemoteTeamVaultSyncNow"))
        #expect(settings.components(separatedBy: "name: .selectiveRemoteTeamVaultSyncNow").count - 1 == 4)
    }

    @MainActor
    @Test("Team Snippets materialize into a separate memory-only projection")
    func materializesTeamSnippets() throws {
        let store = SelectiveRemoteTeamSnippetStore()
        let snapshot = try Self.snapshot(records: [Self.snippetRecord()])

        store.replace(with: [snapshot], now: Date(timeIntervalSince1970: 123))

        #expect(store.synchronizedVaultCount == 1)
        #expect(store.invalidVaultCount == 0)
        #expect(store.vaults.count == 1)
        let snippet = try #require(store.snippets.first)
        #expect(snippet.recordID == Self.snippetID)
        #expect(snippet.id != snippet.recordID)
        #expect(snippet.title == "Deploy status")
        #expect(snippet.body == "systemctl --user status selective-remote\n")
        #expect(snippet.teamName == "Operations")
        #expect(snippet.vaultName == "Runbooks")
        #expect(snippet.role == .editor)
        #expect(store.lastUpdatedAt == Date(timeIntervalSince1970: 123))

        store.clear()
        #expect(store.snippets.isEmpty)
        #expect(store.vaults.isEmpty)
        #expect(store.lastUpdatedAt == nil)
    }

    @MainActor
    @Test("one malformed Snippet hides that complete Team Vault snippet scope")
    func malformedSnippetFailsClosed() throws {
        let invalid = try SelectiveRemoteVaultRecord(
            id: Self.snippetID,
            type: .snippet,
            version: try SelectiveRemoteVaultVersion([Self.deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string("Injected"),
                "body": .string("echo safe"),
                "unexpected": .boolean(true)
            ])
        )
        let store = SelectiveRemoteTeamSnippetStore()
        store.replace(with: [try Self.snapshot(records: [invalid])])

        #expect(store.snippets.isEmpty)
        #expect(store.vaults.isEmpty)
        #expect(store.synchronizedVaultCount == 0)
        #expect(store.invalidVaultCount == 1)
    }

    @MainActor
    @Test("non-Snippet records are never projected into the Team Snippet library")
    func ignoresOtherRecordTypes() throws {
        let host = try SelectiveRemoteVaultRecord(
            id: Self.hostID,
            type: .host,
            version: try SelectiveRemoteVaultVersion([Self.deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string("Bastion"),
                "address": .string("ssh://bastion.example.invalid:22")
            ])
        )
        let store = SelectiveRemoteTeamSnippetStore()
        store.replace(with: [try Self.snapshot(records: [host])])

        #expect(store.snippets.isEmpty)
        #expect(store.vaults.count == 1)
        #expect(store.synchronizedVaultCount == 1)
    }

    @Test("Team Snippet runtime identifiers are stable and scope-bound")
    func identifiersAreScopeBound() throws {
        let first = SelectiveRemoteTeamSnippetMaterializer.scopedID(
            teamID: Self.teamID,
            vaultID: Self.vaultID,
            recordID: Self.snippetID
        )
        let repeated = SelectiveRemoteTeamSnippetMaterializer.scopedID(
            teamID: Self.teamID,
            vaultID: Self.vaultID,
            recordID: Self.snippetID
        )
        let otherVault = SelectiveRemoteTeamSnippetMaterializer.scopedID(
            teamID: Self.teamID,
            vaultID: Self.otherVaultID,
            recordID: Self.snippetID
        )

        #expect(first == repeated)
        #expect(first != otherVault)
    }

    private static func snippetRecord() throws -> SelectiveRemoteVaultRecord {
        try SelectiveRemoteVaultRecord(
            id: snippetID,
            type: .snippet,
            version: try SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string("Deploy status"),
                "body": .string("systemctl --user status selective-remote\n")
            ])
        )
    }

    private static func snapshot(
        records: [SelectiveRemoteVaultRecord]
    ) throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        .init(
            teamID: teamID,
            teamName: "Operations",
            role: .editor,
            vaultID: vaultID,
            vaultName: "Runbooks",
            revision: 7,
            keyGeneration: 3,
            payload: try SelectiveRemoteVaultDocument(records: records).encoded()
        )
    }

    private static let teamID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let vaultID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let otherVaultID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let snippetID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let hostID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private static let deviceID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
