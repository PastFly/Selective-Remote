import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Team Credential materialization")
struct CloudTeamCredentialsTests {
    @MainActor
    @Test("standalone Team Credentials use a separate memory-only projection")
    func materializesStandaloneCredential() throws {
        let store = SelectiveRemoteTeamCredentialStore()
        store.replace(
            with: [try Self.snapshot(records: [Self.credentialRecord()])],
            now: Date(timeIntervalSince1970: 123)
        )

        #expect(store.synchronizedVaultCount == 1)
        #expect(store.invalidVaultCount == 0)
        let credential = try #require(store.credentials.first)
        #expect(credential.recordID == Self.credentialID)
        #expect(credential.id != credential.recordID)
        #expect(credential.title == "Deploy account")
        #expect(credential.username == "deployer")
        #expect(credential.secret == "correct horse battery staple")
        #expect(credential.teamName == "Operations")
        #expect(credential.vaultName == "Production")
        #expect(credential.role == .viewer)
        #expect(credential.revision == 7)
        #expect(credential.keyGeneration == 3)
        #expect(store.lastUpdatedAt == Date(timeIntervalSince1970: 123))

        store.clear()
        #expect(store.credentials.isEmpty)
        #expect(store.lastUpdatedAt == nil)
    }

    @MainActor
    @Test("large Team Credential collections remain complete before grouped rendering")
    func materializesLargeCredentialCollection() throws {
        let records = try (0..<125).map { index in
            try Self.credentialRecord(id: UUID(), index: index)
        }
        let store = SelectiveRemoteTeamCredentialStore()
        store.replace(with: [try Self.snapshot(records: records)])

        #expect(store.credentials.count == 125)
        #expect(store.invalidVaultCount == 0)
        #expect(Set(store.credentials.map(\.recordID)).count == 125)
    }

    @MainActor
    @Test("standalone Team Credentials persist folders and tags inside the encrypted document")
    func organizesStandaloneCredential() throws {
        let initial = try SelectiveRemoteVaultDocument(records: [Self.credentialRecord()])
        let organized = try SelectiveRemoteTeamCredentialDocumentMutation.organize(
            in: initial,
            recordID: Self.credentialID,
            folder: " Production / SSH ",
            tags: [" linux ", "prod", "LINUX"],
            role: .editor,
            deviceID: Self.deviceID,
            modifiedAt: "2026-09-15T01:00:00.000Z"
        )
        let store = SelectiveRemoteTeamCredentialStore()
        store.replace(with: [try Self.snapshot(records: organized.records)])

        let credential = try #require(store.credentials.first)
        #expect(credential.folder == "Production/SSH")
        #expect(credential.tags == ["linux", "prod"])
        #expect(credential.modifiedDate > Date(timeIntervalSince1970: 0))

        let hostStore = SelectiveRemoteTeamHostStore()
        hostStore.replace(with: [try Self.snapshot(records: organized.records)])
        #expect(hostStore.invalidVaultCount == 0)
        #expect(hostStore.hosts.isEmpty)
    }

    @Test("Viewer cannot reorganize a standalone Team Credential")
    func viewerCannotOrganizeCredential() throws {
        let document = try SelectiveRemoteVaultDocument(records: [Self.credentialRecord()])
        #expect(throws: SelectiveRemoteTeamCredentialMutationError.readOnlyRole) {
            try SelectiveRemoteTeamCredentialDocumentMutation.organize(
                in: document,
                recordID: Self.credentialID,
                folder: "Restricted",
                tags: [],
                role: .viewer,
                deviceID: Self.deviceID,
                modifiedAt: "2026-09-15T01:00:00.000Z"
            )
        }
    }

    @MainActor
    @Test("Team Host credentials remain visible with their Host relationship")
    func materializesHostCredentialEnvelope() throws {
        let store = SelectiveRemoteTeamCredentialStore()
        store.replace(with: [try Self.snapshot(records: [Self.hostRecord(), Self.hostCredentialRecord()])])

        let credential = try #require(store.credentials.first)
        #expect(credential.sourceHostID == Self.hostID)
        #expect(credential.sourceHostTitle == "Cloud")
        #expect(credential.kind == .ssh)
        #expect(credential.folder == "Production/SSH")
        #expect(credential.tags == ["linux", "prod"])
        #expect(store.synchronizedVaultCount == 1)
        #expect(store.invalidVaultCount == 0)
    }

    @MainActor
    @Test("standalone Team Credentials do not invalidate Team Host projection")
    func standaloneCredentialsCoexistWithTeamHosts() throws {
        let snapshot = try Self.snapshot(records: [Self.credentialRecord()])
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [snapshot])

        #expect(store.hosts.isEmpty)
        #expect(store.synchronizedVaultCount == 1)
        #expect(store.invalidVaultCount == 0)
    }

    @MainActor
    @Test("one malformed Team Credential hides that Vault credential scope")
    func malformedCredentialFailsClosed() throws {
        let malformed = try SelectiveRemoteVaultRecord(
            id: Self.credentialID,
            type: .credential,
            version: try SelectiveRemoteVaultVersion([Self.deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string("Injected"),
                "username": .string("operator"),
                "secret": .string("secret"),
                "unexpected": .boolean(true)
            ])
        )
        let store = SelectiveRemoteTeamCredentialStore()
        store.replace(with: [try Self.snapshot(records: [malformed])])

        #expect(store.credentials.isEmpty)
        #expect(store.synchronizedVaultCount == 0)
        #expect(store.invalidVaultCount == 1)
    }

    @Test("Team Credential UI keeps decrypted values memory-only and explicit")
    func sourceGuardsMemoryOnlyBoundary() throws {
        let root = Self.packageRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SelectiveRemote/CloudTeamCredentials.swift"),
            encoding: .utf8
        )

        #expect(source.contains("selective-remote/team-credential/v1"))
        #expect(source.contains("let keys = SelectiveRemoteVaultBrowserMetadata.coreKeys(data)"))
        #expect(source.contains("keys == hostCredentialKeys"))
        #expect(source.contains("keys == credentialKeys"))
        #expect(source.contains("NSPasteboard.general"))
        #expect(source.contains("revealedCredentialIDs"))
        #expect(source.contains("CredentialDisclosurePolicy.visibleNanoseconds"))
        #expect(source.contains("CredentialDisclosurePolicy.clipboardNanoseconds"))
        #expect(source.contains("NSApplication.didResignActiveNotification"))
        #expect(source.contains("ru: \"Только в памяти\""))
        #expect(source.contains("credential.sourceHostTitle"))
        #expect(source.contains("credentialKindTitle"))
        #expect(source.contains("DisclosureGroup"))
        #expect(source.contains("expandedVaultKeysStorage"))
        #expect(source.contains("expandedFolderKeysStorage"))
        #expect(source.contains("credential.tags.joined"))
        #expect(source.contains("SelectiveRemoteTeamCredentialMutationService"))
        #expect(source.contains("Изменить папку и теги"))
        #expect(!source.contains("UserDefaults"))
        #expect(!source.contains("FileManager"))
        #expect(!source.contains("KeychainService"))
    }

    private static func credentialRecord() throws -> SelectiveRemoteVaultRecord {
        try credentialRecord(id: credentialID, index: nil)
    }

    private static func credentialRecord(
        id: UUID,
        index: Int?
    ) throws -> SelectiveRemoteVaultRecord {
        try SelectiveRemoteVaultRecord(
            id: id,
            type: .credential,
            version: try SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string(index.map { "Deploy account \($0)" } ?? "Deploy account"),
                "username": .string("deployer"),
                "secret": .string("correct horse battery staple")
            ])
        )
    }

    private static func hostCredentialRecord() throws -> SelectiveRemoteVaultRecord {
        try SelectiveRemoteVaultRecord(
            id: credentialID,
            type: .credential,
            version: try SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string("Deploy host"),
                "username": .string("deployer"),
                "secret": .string("host-only-secret"),
                "kind": .string(KeychainCredentialKind.ssh.rawValue),
                "sourceID": .string(hostID.uuidString.lowercased())
            ])
        )
    }

    private static func hostRecord() throws -> SelectiveRemoteVaultRecord {
        try SelectiveRemoteVaultRecord(
            id: hostID,
            type: .host,
            version: try SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-15T00:00:00.000Z",
            data: .object([
                "title": .string("Cloud"),
                "address": .string("cloud.example.invalid"),
                "folder": .string("Production/SSH"),
                "tags": .array([.string("linux"), .string("prod")]),
                "description": .string("Shared SSH entry")
            ])
        )
    }

    private static func snapshot(
        records: [SelectiveRemoteVaultRecord]
    ) throws -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        .init(
            teamID: teamID,
            teamName: "Operations",
            role: .viewer,
            vaultID: vaultID,
            vaultName: "Production",
            revision: 7,
            keyGeneration: 3,
            payload: try SelectiveRemoteVaultDocument(records: records).encoded()
        )
    }

    private static let teamID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let vaultID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let credentialID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let hostID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let deviceID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
