import Foundation
import Testing
@testable import SelectiveRemote

@Test("Startup Snippet sequence preserves order and stays hidden from library")
@MainActor
func startupSnippetSequencePreservesOrder() throws {
    let suite = "SelectiveRemoteTests.StartupSequence.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let library = TerminalCommandHistoryStore(defaults: defaults)
    let sequenceStore = TerminalStartupSnippetSequenceStore(defaults: defaults)
    let libraryID = TerminalCommandHistoryStore.globalSnippetLibraryID

    #expect(library.saveTemplate(
        id: nil,
        title: "Prepare",
        command: "cd /srv/app",
        category: "Startup",
        profileID: libraryID,
        targetProfileIDs: []
    ))
    #expect(library.saveTemplate(
        id: nil,
        title: "Status",
        command: "git status --short",
        category: "Startup",
        profileID: libraryID,
        targetProfileIDs: []
    ))

    let prepare = try #require(library.templates().first(where: { $0.title == "Prepare" }))
    let status = try #require(library.templates().first(where: { $0.title == "Status" }))
    let ownerKey = TerminalStartupSnippetSequenceStore.profileOwnerKey(UUID())

    let compositeID = try #require(try sequenceStore.apply(
        ownerKey: ownerKey,
        snippetIDs: [status.id, prepare.id],
        title: "Startup Snippets",
        library: library
    ))

    #expect(sequenceStore.sequence(
        ownerKey: ownerKey,
        legacySnippetID: compositeID,
        library: library
    ) == [status.id, prepare.id])
    #expect(library.template(id: compositeID)?.command == "git status --short\ncd /srv/app")
    #expect(library.isStartupSequenceTemplate(id: compositeID))
    #expect(!library.templates().contains(where: { $0.id == compositeID }))
}

@Test("Single Startup Snippet remains backward compatible")
@MainActor
func singleStartupSnippetUsesOriginalTemplate() throws {
    let suite = "SelectiveRemoteTests.StartupSingle.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let library = TerminalCommandHistoryStore(defaults: defaults)
    let sequenceStore = TerminalStartupSnippetSequenceStore(defaults: defaults)
    #expect(library.saveTemplate(
        id: nil,
        title: "One",
        command: "uptime",
        category: "Startup",
        profileID: TerminalCommandHistoryStore.globalSnippetLibraryID,
        targetProfileIDs: []
    ))
    let snippet = try #require(library.templates().first(where: { $0.title == "One" }))
    let ownerKey = TerminalStartupSnippetSequenceStore.profileOwnerKey(UUID())

    let resolvedID = try #require(try sequenceStore.apply(
        ownerKey: ownerKey,
        snippetIDs: [snippet.id],
        title: "Startup Snippets",
        library: library
    ))

    #expect(resolvedID == snippet.id)
    #expect(!library.isStartupSequenceTemplate(id: resolvedID))
    #expect(sequenceStore.sequence(
        ownerKey: ownerKey,
        legacySnippetID: resolvedID,
        library: library
    ) == [snippet.id])
}

@Test("Clearing Startup Snippet sequence removes synthetic template")
@MainActor
func clearingStartupSnippetSequenceRemovesComposite() throws {
    let suite = "SelectiveRemoteTests.StartupClear.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let library = TerminalCommandHistoryStore(defaults: defaults)
    let sequenceStore = TerminalStartupSnippetSequenceStore(defaults: defaults)
    let libraryID = TerminalCommandHistoryStore.globalSnippetLibraryID

    for (title, command) in [("One", "echo one"), ("Two", "echo two")] {
        #expect(library.saveTemplate(
            id: nil,
            title: title,
            command: command,
            category: "Startup",
            profileID: libraryID,
            targetProfileIDs: []
        ))
    }
    let one = try #require(library.templates().first(where: { $0.title == "One" }))
    let two = try #require(library.templates().first(where: { $0.title == "Two" }))
    let ownerKey = TerminalStartupSnippetSequenceStore.groupOwnerKey("Production")
    let compositeID = try #require(try sequenceStore.apply(
        ownerKey: ownerKey,
        snippetIDs: [one.id, two.id],
        title: "Startup Snippets группы",
        library: library
    ))
    #expect(library.template(id: compositeID) != nil)

    let cleared = try sequenceStore.apply(
        ownerKey: ownerKey,
        snippetIDs: [],
        title: "Startup Snippets группы",
        library: library
    )

    #expect(cleared == nil)
    #expect(library.template(id: compositeID) == nil)
    #expect(sequenceStore.sequence(
        ownerKey: ownerKey,
        legacySnippetID: nil,
        library: library
    ).isEmpty)
}

@Test("v0.27 terminal surfaces use the native full-size Inspector")
func terminalInspectorSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let sshSource = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/EmbeddedTerminalView.swift"),
        encoding: .utf8
    )
    #expect(sshSource.contains("private var workspaceInspectorVisible: Bool {\n        showsHistory || showsSnippets"))
    #expect(sshSource.contains("The native SwiftUI inspector is the single History surface"))

    let localSource = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/LocalTerminalView.swift"),
        encoding: .utf8
    )
    #expect(localSource.contains("TerminalWorkspaceInspector("))
    #expect(localSource.contains("private var inspectorVisible: Bool"))
}

@Test("v0.27 uses contrast-safe checkbox style")
func contrastCheckboxSourceRegression() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let appSource = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/SelectiveRemoteApp.swift"),
        encoding: .utf8
    )
    #expect(appSource.contains(".toggleStyle(SelectiveRemoteCheckboxToggleStyle())"))

    let sftpSource = try String(
        contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/SFTPInspectorViews.swift"),
        encoding: .utf8
    )
    #expect(sftpSource.contains(".toggleStyle(SelectiveRemoteCheckboxToggleStyle())"))
}
