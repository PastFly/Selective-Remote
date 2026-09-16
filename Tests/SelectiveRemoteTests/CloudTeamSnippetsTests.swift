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

    @Test("Team Snippet UI exposes explicit edit, delete, run, and target actions")
    func teamSnippetActionsAreAvailable() throws {
        let root = Self.packageRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CloudTeamSnippets.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".contextMenu { snippetActions(snippet) }"))
        #expect(source.contains("ru: \"Изменить\", en: \"Edit\""))
        #expect(source.contains("snippetPendingDeletion = snippet"))
        #expect(source.contains("SelectiveRemoteTeamSnippetEditorView(request: request)"))
        #expect(source.contains("ru: \"Настроить хосты…\""))
        #expect(source.contains("model.runTerminalSnippet(executable)"))
        #expect(source.contains("ru: \"Выбор хранится только на этом Mac"))
        #expect(source.contains("TimelineView(.periodic(from: .now, by: 60))"))
        #expect(source.contains("ru: \"Изменён "))
        #expect(!source.contains("Text(snippet.modifiedDate, style: .relative)"))
        #expect(source.contains("SelectiveRemote.team-snippet.display-mode.v1"))
        #expect(source.contains("SelectiveRemote.team-snippet.sort-mode.v1"))
        #expect(source.contains("SelectiveRemote.team-snippet.collapsed-folders.v1"))
        #expect(source.contains("SelectiveRemoteTeamSnippetFolderNode"))
        #expect(source.contains("folderExpansionBinding(for: node.path)"))
        #expect(source.contains("teamSnippetListFolder(child)"))
        #expect(source.contains("teamSnippetGridFolder(child)"))
        #expect(source.contains("SelectiveRemoteTeamSnippetFolderEditor"))
        #expect(source.contains("DisclosureGroup("))
        #expect(source.contains("LazyVGrid("))
        #expect(source.contains("ru: \"Все папки\", en: \"All Folders\""))
    }

    @Test("Snippet header keeps two fixed action slots in Personal and Team scopes")
    func snippetHeaderHasStableActions() throws {
        let root = Self.packageRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/TerminalSnippetsLibraryView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("@State private var teamCreateRequest = 0"))
        #expect(source.contains("@State private var teamCreateFolderRequest = 0"))
        #expect(source.contains(".frame(width: 112)"))
        #expect(source.contains(".frame(width: 122)"))
        #expect(source.contains("teamCreateRequest += 1"))
        #expect(source.contains("teamCreateFolderRequest += 1"))
        #expect(source.contains("name: .selectiveRemoteTeamVaultSyncNow"))
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
        #expect(snippet.folder.isEmpty)
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
    @Test("Team Snippet folders materialize without breaking legacy records")
    func materializesFolderMetadata() throws {
        let record = try SelectiveRemoteVaultRecord(
            id: Self.snippetID,
            type: .snippet,
            version: try SelectiveRemoteVaultVersion([Self.deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string("Deploy status"),
                "body": .string("systemctl status app"),
                "folder": .string("Production/Deploy")
            ])
        )
        let store = SelectiveRemoteTeamSnippetStore()
        store.replace(with: [try Self.snapshot(records: [record])])

        #expect(store.snippets.first?.folder == "Production/Deploy")
        #expect(store.invalidVaultCount == 0)
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

    @Test("Owner, Admin, and Editor can create, update, and delete Team Snippets")
    func writableRolesMutateSnippetsCausally() throws {
        for role in [
            SelectiveRemoteCloudTeamRole.owner,
            .admin,
            .editor
        ] {
            let created = try SelectiveRemoteTeamSnippetDocumentMutation.create(
                recordID: Self.snippetID,
                title: "Deploy status",
                body: "systemctl status app",
                folder: "Production/Deploy",
                role: role,
                deviceID: Self.deviceID,
                modifiedAt: "2026-09-16T12:00:00.000Z"
            )
            let createdRecord = try #require(created.records.first)
            #expect(createdRecord.type == .snippet)
            #expect(createdRecord.version.counters[Self.deviceID] == 1)
            if case let .object(data) = createdRecord.data {
                #expect(data["folder"] == .string("Production/Deploy"))
            }

            let updated = try SelectiveRemoteTeamSnippetDocumentMutation.update(
                in: created,
                recordID: Self.snippetID,
                title: "Restart service",
                body: "systemctl restart app",
                folder: "Production/Maintenance",
                role: role,
                deviceID: Self.deviceID,
                modifiedAt: "2026-09-16T12:01:00.000Z"
            )
            let updatedRecord = try #require(updated.records.first)
            #expect(updatedRecord.version.counters[Self.deviceID] == 2)
            if case let .object(data) = updatedRecord.data {
                #expect(data["folder"] == .string("Production/Maintenance"))
            }

            let deleted = try SelectiveRemoteTeamSnippetDocumentMutation.delete(
                from: updated,
                recordID: Self.snippetID,
                role: role,
                deviceID: Self.deviceID,
                deletedAt: "2026-09-16T12:02:00.000Z"
            )
            #expect(deleted.records.isEmpty)
            #expect(deleted.tombstones.first?.id == Self.snippetID)
            #expect(deleted.tombstones.first?.version.counters[Self.deviceID] == 3)
        }
    }

    @Test("Viewer cannot mutate Team Snippets")
    func viewerIsReadOnly() throws {
        #expect(!SelectiveRemoteTeamSnippetDocumentMutation.isWritable(role: .viewer))
        #expect(throws: SelectiveRemoteTeamSnippetMutationError.readOnlyRole) {
            _ = try SelectiveRemoteTeamSnippetDocumentMutation.create(
                recordID: Self.snippetID,
                title: "Denied",
                body: "echo denied",
                role: .viewer,
                deviceID: Self.deviceID,
                modifiedAt: "2026-09-16T12:00:00.000Z"
            )
        }
    }

    @Test("Team Snippet mutations preserve unrelated Vault records")
    func mutationsPreserveOtherRecords() throws {
        let original = try SelectiveRemoteVaultDocument(records: [Self.snippetRecord()])
        let secondID = try #require(
            UUID(uuidString: "77777777-7777-4777-8777-777777777777")
        )
        let mutated = try SelectiveRemoteTeamSnippetDocumentMutation.create(
            in: original,
            recordID: secondID,
            title: "Second",
            body: "echo second",
            role: .editor,
            deviceID: Self.deviceID,
            modifiedAt: "2026-09-16T12:00:00.000Z"
        )

        #expect(mutated.records.count == 2)
        #expect(mutated.records.first(where: { $0.id == Self.snippetID }) == original.records.first)
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
