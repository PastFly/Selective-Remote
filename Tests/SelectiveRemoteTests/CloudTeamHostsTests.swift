import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Team Host materialization")
struct CloudTeamHostsTests {
    @Test("Team Host sorting offers a Vault option in the shared Shelf and catalog preference")
    func vaultSortOption() {
        #expect(SelectiveRemoteTeamHostSortMode.allCases.map(\.rawValue).contains("vault"))
    }

    @Test("Vault sorting orders Team Hosts by Vault then Host without changing identity")
    func vaultSortOrder() {
        let teamID = UUID()
        func host(_ title: String, vault: String, vaultID: UUID) -> SelectiveRemoteTeamHost {
            var profile = ConnectionProfile(connectionType: .ssh)
            profile.friendlyName = title
            profile.host = "synthetic.example.invalid"
            return .init(
                id: UUID(), recordID: UUID(), teamID: teamID, teamName: "Team",
                role: .owner, vaultID: vaultID, vaultName: vault,
                revision: 1, keyGeneration: 1, modifiedAt: "2026-09-24T00:00:00Z",
                address: profile.host, profile: profile, credentials: .empty
            )
        }
        let firstVault = UUID()
        let secondVault = UUID()
        let beta = host("Alpha Host", vault: "Beta Vault", vaultID: secondVault)
        let zulu = host("Zulu Host", vault: "Alpha Vault", vaultID: firstVault)
        let alpha = host("Alpha Host", vault: "Alpha Vault", vaultID: firstVault)
        let arranged = [beta, zulu, alpha].sorted(by: SelectiveRemoteTeamHostSortMode.vault.comesBefore)
        #expect(arranged.map(\.id) == [alpha.id, zulu.id, beta.id])
        #expect(arranged.map(\.vaultID) == [firstVault, firstVault, secondVault])
    }

    @MainActor
    @Test("browser and macOS host records materialize into one separate read-only projection")
    func crossClientFixture() throws {
        let payload = try Self.fixtureData()
        let document = try SelectiveRemoteVaultDocument.decode(payload)
        #expect(document.records.count == 2)

        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [Self.snapshot(payload: payload)])

        #expect(store.synchronizedVaultCount == 1)
        #expect(store.invalidVaultCount == 0)
        #expect(store.hosts.count == 2)

        let browser = try #require(store.hosts.first {
            $0.recordID.uuidString.lowercased() == "33333333-3333-4333-8333-333333333333"
        })
        #expect(browser.profile.connectionType == .ssh)
        #expect(browser.profile.host == "bastion.example.invalid")
        #expect(browser.profile.username == "deployer")
        #expect(browser.profile.sshPort == 2_222)
        #expect(browser.id != browser.recordID)

        let mac = try #require(store.hosts.first {
            $0.recordID.uuidString.lowercased() == "77777777-7777-4777-8777-777777777777"
        })
        #expect(mac.profile.connectionType == .rdp)
        #expect(mac.profile.host == "rdp.example.invalid")
        #expect(mac.profile.username == "operator")
        #expect(mac.profile.clipboardMode == .disabled)
        #expect(mac.profile.audioMode == .muted)
        #expect(mac.profile.redirectedFolders.isEmpty)
        #expect(mac.id != mac.recordID)
    }

    @MainActor
    @Test("rich Team hosts discard Personal references and unsafe device settings")
    func sanitizesMacOSProfile() throws {
        let profileID = try #require(
            UUID(uuidString: "88888888-8888-4888-8888-888888888888")
        )
        let deviceID = try #require(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let unicodeTitle = String(repeating: "Я", count: 120)
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.id = profileID
        profile.friendlyName = unicodeTitle
        profile.host = "ops.example.invalid"
        profile.username = "operator"
        profile.group = "Production / Linux"
        profile.tags = ["critical", "eu-west"]
        profile.profileDescription = "Shared bastion"
        profile.sshPort = 2_222
        profile.sshIdentityID = UUID()
        profile.sshJumpHostProfileID = UUID()
        profile.sshProxyMode = .socks5
        profile.sshProxyHost = "localhost"
        profile.sshAgentForwarding = true
        profile.redirectMicrophone = true
        profile.redirectCamera = true
        profile.redirectPrinters = true
        profile.redirectedFolders = ["/Users/example/Secrets"]
        profile.clipboardMode = .bidirectional
        profile.audioMode = .local
        profile.autoReconnect = true
        profile.reconnectAfterWake = true
        profile.adminSession = true
        profile.certificatePolicy = .ignore

        let personalProfiles = [profile]
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: personalProfiles,
            credentials: [],
            snippets: [],
            forwarding: [],
            deviceID: deviceID
        )
        let store = SelectiveRemoteTeamHostStore()
        let snapshot = Self.snapshot(payload: try exported.document.encoded())
        store.replace(with: [snapshot])

        let host = try #require(store.hosts.first)
        let firstRuntimeID = host.id
        #expect(host.recordID == profileID)
        #expect(host.id != profileID)
        #expect(host.profile.friendlyName == unicodeTitle)
        #expect(host.profile.group == "Production / Linux")
        #expect(host.profile.tags == ["critical", "eu-west"])
        #expect(host.profile.profileDescription == "Shared bastion")
        #expect(host.profile.sshIdentityID == nil)
        #expect(host.profile.sshJumpHostProfileID == nil)
        #expect(host.profile.sshProxyMode == .none)
        #expect(host.profile.sshProxyHost.isEmpty)
        #expect(host.profile.sshAgentForwarding == false)
        #expect(host.profile.redirectMicrophone == false)
        #expect(host.profile.redirectCamera == false)
        #expect(host.profile.redirectPrinters == false)
        #expect(host.profile.redirectedFolders.isEmpty)
        #expect(host.profile.clipboardMode == .disabled)
        #expect(host.profile.audioMode == .muted)
        #expect(host.profile.autoReconnect == false)
        #expect(host.profile.reconnectAfterWake == false)
        #expect(host.profile.adminSession == false)
        #expect(host.profile.certificatePolicy == .trustOnFirstUse)
        #expect(host.profile.createdAt == Date(timeIntervalSince1970: 0))
        #expect(personalProfiles.count == 1)
        #expect(personalProfiles[0].sshIdentityID != nil)

        store.replace(with: [snapshot])
        #expect(store.hosts.first?.id == firstRuntimeID)
    }

    @MainActor
    @Test("one malformed host hides its complete Team Vault scope")
    func malformedVaultFailsClosed() throws {
        let valid = try SelectiveRemoteVaultDocument.decode(Self.fixtureData())
        let invalidID = try #require(
            UUID(uuidString: "99999999-9999-4999-8999-999999999999")
        )
        let deviceID = try #require(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let invalid = try SelectiveRemoteVaultRecord(
            id: invalidID,
            type: .host,
            version: SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("Injected"),
                "address": .string("injected.example.invalid"),
                "unexpected": .boolean(true)
            ])
        )
        let document = try SelectiveRemoteVaultDocument(
            records: valid.records + [invalid],
            tombstones: valid.tombstones
        )
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [Self.snapshot(payload: try document.encoded())])

        #expect(store.hosts.isEmpty)
        #expect(store.synchronizedVaultCount == 0)
        #expect(store.invalidVaultCount == 1)
    }

    @MainActor
    @Test("Host warning identifies record shape without revealing Vault values")
    func materializationShapeDiagnostic() throws {
        let valid = try SelectiveRemoteVaultDocument.decode(Self.fixtureData())
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let malformed = try SelectiveRemoteVaultRecord(
            id: UUID(), type: .host,
            version: SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("PRIVATE-TITLE-MARKER"),
                "address": .string("PRIVATE-ADDRESS-MARKER"),
                "port": .number(22),
                "secretCustomField": .string("PRIVATE-SECRET-MARKER")
            ])
        )
        let standaloneCredential = try SelectiveRemoteVaultRecord(
            id: UUID(), type: .credential,
            version: SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("PRIVATE-CREDENTIAL-TITLE"),
                "username": .string("test-user"),
                "secret": .string("PRIVATE-CREDENTIAL-SECRET")
            ])
        )
        let snippet = try SelectiveRemoteVaultRecord(
            id: UUID(), type: .snippet,
            version: SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("PRIVATE-SNIPPET-TITLE"),
                "body": .string("PRIVATE-SNIPPET-BODY")
            ])
        )
        let document = try SelectiveRemoteVaultDocument(
            records: valid.records + [malformed, standaloneCredential, snippet],
            tombstones: valid.tombstones
        )
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [Self.snapshot(payload: try document.encoded())])
        let issue = try #require(store.materializationIssues.first)
        let diagnostic = try #require(issue.safeDiagnostic)
        #expect(diagnostic.contains("Host"))
        #expect(diagnostic.contains("port"))
        #expect(diagnostic.contains("unknown fields: 1"))
        #expect(!diagnostic.contains("PRIVATE-"))
        #expect(!diagnostic.contains("secretCustomField"))
        #expect(diagnostic.contains("Snippet projection: readable"))
        #expect(diagnostic.contains("Credential projection: readable"))
        #expect(store.hosts.isEmpty)
    }

    @MainActor
    @Test("A standalone Credential shape cannot hide valid Team Hosts")
    func standaloneCredentialProjectionIsolation() throws {
        let document = try SelectiveRemoteVaultDocument.decode(Self.fixtureData())
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let legacyCredential = try SelectiveRemoteVaultRecord(
            id: UUID(), type: .credential,
            version: SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("Standalone"),
                "username": .string("user"),
                "secret": .string("synthetic-only"),
                "folder": .string("Legacy")
            ])
        )
        let mixed = try SelectiveRemoteVaultDocument(
            records: document.records + [legacyCredential], tombstones: document.tombstones
        )
        let snapshot = Self.snapshot(payload: try mixed.encoded())
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [snapshot])
        #expect(store.hosts.count == 2)
        #expect(store.invalidVaultCount == 0)
        #expect(throws: SelectiveRemoteTeamCredentialMaterializationError.self) {
            _ = try SelectiveRemoteTeamCredentialMaterializer.materialize(snapshot)
        }
    }

    @MainActor
    @Test("Browser favorite metadata cannot hide Host, linked Credential, or Snippet")
    func browserFavoriteMetadataCompatibility() throws {
        let original = try SelectiveRemoteVaultDocument.decode(Self.fixtureData())
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let host = try #require(original.records.first { $0.type == .host })
        guard case let .object(hostData) = host.data else {
            Issue.record("Expected synthetic Host object")
            return
        }
        var favoriteHostData = hostData
        favoriteHostData["favorite"] = .boolean(true)
        let favoriteHost = try SelectiveRemoteVaultRecord(
            id: host.id, type: .host, version: host.version,
            modifiedAt: host.modifiedAt, data: .object(favoriteHostData)
        )
        let credential = try SelectiveRemoteVaultRecord(
            id: UUID(), type: .credential,
            version: try SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("Synthetic SSH credential"),
                "username": .string("synthetic"),
                "secret": .string("synthetic-only"),
                "kind": .string("ssh"),
                "sourceID": .string(host.id.uuidString.lowercased()),
                "favorite": .boolean(true)
            ])
        )
        let snippet = try SelectiveRemoteVaultRecord(
            id: UUID(), type: .snippet,
            version: try SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("Synthetic command"),
                "body": .string("printf ok"),
                "favorite": .boolean(false)
            ])
        )
        let standaloneCredential = try SelectiveRemoteVaultRecord(
            id: UUID(), type: .credential,
            version: try SelectiveRemoteVaultVersion([deviceID: 1]),
            modifiedAt: "2026-09-10T00:02:00.000Z",
            data: .object([
                "title": .string("Synthetic standalone credential"),
                "username": .string("synthetic"),
                "secret": .string("synthetic-only"),
                "favorite": .boolean(true)
            ])
        )
        let document = try SelectiveRemoteVaultDocument(
            records: original.records.map { $0.id == host.id ? favoriteHost : $0 }
                + [credential, standaloneCredential, snippet], tombstones: original.tombstones
        )
        let snapshot = Self.snapshot(payload: try document.encoded())
        let diagnostic = SelectiveRemoteTeamHostShapeDiagnostic.describe(snapshot)
        #expect(diagnostic.split(separator: "\n").contains { line in
            line.contains("Credential") && line.contains("favorite")
                && line.contains("unknown fields: 0")
        })
        let hosts = try SelectiveRemoteTeamHostMaterializer.materialize(snapshot)
        #expect(hosts.count == 2)
        #expect(hosts.first { $0.recordID == host.id }?.credentials.password == "synthetic-only")
        #expect(try SelectiveRemoteTeamCredentialMaterializer.materialize(snapshot).count == 2)
        #expect(try SelectiveRemoteTeamSnippetMaterializer.materialize(snapshot).count == 1)

        let profile = try #require(hosts.first { $0.recordID == host.id }?.profile)
        let organized = try SelectiveRemoteTeamHostDocumentMutation.organize(
            in: document, recordID: host.id, profile: profile, role: .editor,
            deviceID: deviceID, modifiedAt: "2026-09-10T00:03:00.000Z"
        )
        let organizedHost = try #require(organized.records.first { $0.id == host.id })
        guard case let .object(organizedHostData) = organizedHost.data else {
            Issue.record("Expected organized Host object")
            return
        }
        #expect(organizedHostData["favorite"] == .boolean(true))

        let updatedHost = try SelectiveRemoteTeamHostDocumentMutation.update(
            in: document, recordID: host.id, profile: profile,
            credentials: .init(password: "synthetic-only", gatewayPassword: nil),
            role: .editor, deviceID: deviceID,
            modifiedAt: "2026-09-10T00:03:00.000Z"
        )
        let updatedHostRecord = try #require(updatedHost.records.first { $0.id == host.id })
        guard case let .object(updatedHostData) = updatedHostRecord.data else {
            Issue.record("Expected updated Host object")
            return
        }
        #expect(updatedHostData["favorite"] == .boolean(true))
        let updatedCredential = try #require(updatedHost.records.first { $0.type == .credential })
        guard case let .object(updatedCredentialData) = updatedCredential.data else {
            Issue.record("Expected updated linked Credential object")
            return
        }
        #expect(updatedCredentialData["favorite"] == .boolean(true))

        let organizedCredential = try SelectiveRemoteTeamCredentialDocumentMutation.organize(
            in: document, recordID: standaloneCredential.id, folder: "Synthetic",
            tags: [], role: .editor, deviceID: deviceID,
            modifiedAt: "2026-09-10T00:03:00.000Z"
        )
        let standaloneRecord = try #require(organizedCredential.records.first { $0.id == standaloneCredential.id })
        guard case let .object(standaloneData) = standaloneRecord.data else {
            Issue.record("Expected organized standalone Credential object")
            return
        }
        #expect(standaloneData["favorite"] == .boolean(true))

        let updatedSnippet = try SelectiveRemoteTeamSnippetDocumentMutation.update(
            in: document, recordID: snippet.id, title: "Synthetic command",
            body: "printf updated", role: .editor, deviceID: deviceID,
            modifiedAt: "2026-09-10T00:03:00.000Z"
        )
        let snippetRecord = try #require(updatedSnippet.records.first { $0.id == snippet.id })
        guard case let .object(snippetData) = snippetRecord.data else {
            Issue.record("Expected updated Snippet object")
            return
        }
        #expect(snippetData["favorite"] == .boolean(false))

        var invalidData = favoriteHostData
        invalidData["favorite"] = .string("yes")
        let invalidHost = try SelectiveRemoteVaultRecord(
            id: host.id, type: .host, version: host.version,
            modifiedAt: host.modifiedAt, data: .object(invalidData)
        )
        let invalidDocument = try SelectiveRemoteVaultDocument(
            records: original.records.map { $0.id == host.id ? invalidHost : $0 },
            tombstones: original.tombstones
        )
        #expect(throws: SelectiveRemoteTeamHostMaterializationError.invalidHostRecord) {
            try SelectiveRemoteTeamHostMaterializer.materialize(Self.snapshot(payload: invalidDocument.encoded()))
        }

        guard case let .object(credentialData) = credential.data else {
            Issue.record("Expected linked Credential object")
            return
        }
        var unknownCredentialData = credentialData
        unknownCredentialData["unexpected"] = .boolean(true)
        let unknownCredential = try SelectiveRemoteVaultRecord(
            id: credential.id, type: .credential, version: credential.version,
            modifiedAt: credential.modifiedAt, data: .object(unknownCredentialData)
        )
        let unknownDocument = try SelectiveRemoteVaultDocument(
            records: document.records.map { $0.id == credential.id ? unknownCredential : $0 },
            tombstones: document.tombstones
        )
        #expect(throws: SelectiveRemoteTeamHostMaterializationError.invalidHostRecord) {
            try SelectiveRemoteTeamHostMaterializer.materialize(Self.snapshot(payload: unknownDocument.encoded()))
        }
    }

    @MainActor
    @Test("Team Host warning reports zero, one and multiple hidden scopes without exposing payloads")
    func materializationWarningStates() throws {
        let store = SelectiveRemoteTeamHostStore()
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.replace(with: [], now: observedAt)
        #expect(store.materializationIssues.isEmpty)
        #expect(SelectiveRemoteTeamHostWarningCopy.status(count: 0, english: false) == nil)

        let first = Self.snapshot(payload: Data("not a vault document".utf8))
        let second = SelectiveRemoteTeamVaultMaterializedSnapshot(
            teamID: first.teamID,
            teamName: "Platform",
            role: .viewer,
            vaultID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            vaultName: "Projects",
            revision: 1,
            keyGeneration: 1,
            payload: Data("also invalid".utf8)
        )
        store.replace(with: [first], now: observedAt)
        #expect(store.hosts.isEmpty)
        #expect(store.materializationIssues.count == 1)
        #expect(store.materializationIssues[0].category == .invalidSnapshot)
        #expect(store.materializationIssues[0].teamName == "Platform")
        #expect(store.materializationIssues[0].vaultName == "Operations")
        #expect(store.materializationIssues[0].lastAttempt == observedAt)
        #expect(SelectiveRemoteTeamHostWarningCopy.status(count: 1, english: false) == "Требует внимания · 1")
        #expect(SelectiveRemoteTeamHostWarningCopy.status(count: 1, english: true) == "Needs attention · 1")

        store.replace(with: [first, second], now: observedAt)
        #expect(store.invalidVaultCount == 2)
        #expect(store.materializationIssues.count == 2)
        #expect(SelectiveRemoteTeamHostWarningCopy.status(count: 2, english: false) == "Требует внимания · 2")
        #expect(SelectiveRemoteTeamHostWarningCopy.status(count: 2, english: true) == "Needs attention · 2")
        store.clear()
        #expect(store.materializationIssues.isEmpty)
    }

    @MainActor
    @Test("Team Host warning is privacy-safe and does not offer device recovery for materialization errors")
    func materializationWarningPrivacyAndActions() {
        let invalid = Self.snapshot(payload: Data("SECRET-CIPHERTEXT-TEST".utf8))
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [invalid])
        let issue = store.materializationIssues[0]
        #expect(issue.category == .invalidSnapshot)
        #expect(!issue.category.allowsDeviceRecovery)
        #expect(!issue.category.allowsTeamManagementRecovery)
        let details = SelectiveRemoteTeamHostWarningCopy.details(english: true)
        #expect(details.contains("Hosts from one team could not be displayed"))
        #expect(!details.contains("SECRET-CIPHERTEXT-TEST"))
        #expect(!details.contains("invalidSnapshot"))
        #expect(!details.contains(invalid.vaultID.uuidString))
    }

    @Test("Team Host warning keeps recovery local and content-sized without weakening fail-closed projection")
    func materializationWarningInteractionContract() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SelectiveRemote/CloudTeamHosts.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("if let warning = SelectiveRemoteTeamHostWarningCopy.status("))
        #expect(source.contains("warningDetailsPresented = true"))
        #expect(source.contains(".focused($warningButtonFocused)"))
        #expect(source.contains("warningButtonFocused = true"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains("synchronizeConfiguredAccountNow()"))
        #expect(!source.contains("onShowDiagnostics()"))
        #expect(!source.contains(".frame(minWidth: 520, minHeight: 340)"))
        #expect(source.contains(".onChange(of: store.materializationIssues.count)"))
        #expect(source.contains("if count == 0 { dismiss() }"))
        #expect(source.contains("nextHosts += try SelectiveRemoteTeamHostMaterializer.materialize(snapshot)"))
        #expect(source.contains("} catch {\n                invalid += 1"))
    }

    @Test("Team Host warning names multiple hidden projections without claiming corrupted data")
    func materializationWarningMultipleCopy() {
        #expect(SelectiveRemoteTeamHostWarningCopy.summary(count: 2, english: false)
                == "Не удалось показать хосты из 2 Team Vaults")
        #expect(SelectiveRemoteTeamHostWarningCopy.summary(count: 2, english: true)
                == "Hosts from 2 Team Vaults could not be displayed")
        #expect(SelectiveRemoteTeamHostWarningCopy.explanation(count: 2, english: false)
                .contains("временно скрыты"))
        #expect(SelectiveRemoteTeamHostWarningCopy.explanation(count: 2, english: true)
                .contains("temporarily hidden"))
    }



    @Test("Team Host write capability matches the complete role matrix")
    func writeCapabilityRoleMatrix() {
        #expect(SelectiveRemoteTeamHostDocumentMutation.isWritable(role: .owner))
        #expect(SelectiveRemoteTeamHostDocumentMutation.isWritable(role: .admin))
        #expect(SelectiveRemoteTeamHostDocumentMutation.isWritable(role: .editor))
        #expect(!SelectiveRemoteTeamHostDocumentMutation.isWritable(role: .viewer))
    }

    @Test("Owner, Admin, and Editor can create, update, and delete a Team Host")
    func writableRolesMutateHostCausally() throws {
        let deviceID = try #require(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let recordID = try #require(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        )
        for role in [
            SelectiveRemoteCloudTeamRole.owner,
            .admin,
            .editor
        ] {
            var profile = ConnectionProfile(connectionType: .ssh)
            profile.id = recordID
            profile.friendlyName = "Build Host"
            profile.host = "build.example.invalid"
            profile.username = "builder"

            let created = try SelectiveRemoteTeamHostDocumentMutation.create(
                profile: profile,
                role: role,
                deviceID: deviceID,
                modifiedAt: "2026-09-10T01:00:00.000Z"
            )
            let createdRecord = try #require(created.records.first)
            #expect(createdRecord.type == .host)
            #expect(createdRecord.version.counters[deviceID] == 1)

            profile.friendlyName = "Production Host"
            let updated = try SelectiveRemoteTeamHostDocumentMutation.update(
                in: created,
                recordID: recordID,
                profile: profile,
                role: role,
                deviceID: deviceID,
                modifiedAt: "2026-09-10T01:01:00.000Z"
            )
            #expect(updated.records.first?.version.counters[deviceID] == 2)

            let deleted = try SelectiveRemoteTeamHostDocumentMutation.delete(
                from: updated,
                recordID: recordID,
                role: role,
                deviceID: deviceID,
                deletedAt: "2026-09-10T01:02:00.000Z"
            )
            #expect(deleted.records.isEmpty)
            #expect(deleted.tombstones.first?.id == recordID)
            #expect(deleted.tombstones.first?.version.counters[deviceID] == 3)
        }
    }

    @Test("Viewer mutations fail before changing the Team Vault document")
    func viewerIsStrictlyReadOnly() throws {
        let deviceID = try #require(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        var profile = ConnectionProfile(connectionType: .rdp)
        profile.id = try #require(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        )
        profile.friendlyName = "Denied"
        profile.host = "denied.example.invalid"

        #expect(throws: SelectiveRemoteTeamHostMutationError.readOnlyRole) {
            _ = try SelectiveRemoteTeamHostDocumentMutation.create(
                profile: profile,
                role: .viewer,
                deviceID: deviceID,
                modifiedAt: "2026-09-10T02:00:00.000Z"
            )
        }
    }

    @Test("Host mutations preserve unrelated Team Vault records")
    func preservesUnrelatedRecords() throws {
        let deviceID = try #require(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let original = try SelectiveRemoteVaultDocument.decode(Self.fixtureData())
        let preserved = try #require(original.records.first)
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.id = try #require(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        )
        profile.friendlyName = "New Host"
        profile.host = "new.example.invalid"

        let mutated = try SelectiveRemoteTeamHostDocumentMutation.create(
            in: original,
            profile: profile,
            role: .editor,
            deviceID: deviceID,
            modifiedAt: "2026-09-10T03:00:00.000Z"
        )
        #expect(mutated.records.first(where: { $0.id == preserved.id }) == preserved)
        #expect(mutated.records.count == original.records.count + 1)
    }

    @MainActor
    @Test("Team Host organization changes folder/order without rewriting credentials")
    func organizationMutationPreservesCredentials() throws {
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let recordID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.id = recordID
        profile.friendlyName = "Bastion"
        profile.host = "bastion.example.invalid"
        let created = try SelectiveRemoteTeamHostDocumentMutation.create(
            profile: profile,
            credentials: .init(password: "encrypted-secret", gatewayPassword: nil),
            role: .editor,
            deviceID: deviceID,
            modifiedAt: "2026-09-11T11:00:00.000Z"
        )
        let credentialBefore = try #require(created.records.first { $0.type == .credential })
        profile.group = "Infrastructure/Production"
        profile.sortIndex = 4
        profile.folderOrderPath = [1, 2]
        let organized = try SelectiveRemoteTeamHostDocumentMutation.organize(
            in: created,
            recordID: recordID,
            profile: profile,
            role: .editor,
            deviceID: deviceID,
            modifiedAt: "2026-09-11T11:01:00.000Z"
        )
        #expect(organized.records.first { $0.type == .credential } == credentialBefore)
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [Self.snapshot(payload: try organized.encoded(), role: .editor)])
        #expect(store.hosts.first?.profile.group == "Infrastructure/Production")
        #expect(store.hosts.first?.profile.sortIndex == 4)
        #expect(store.hosts.first?.profile.folderOrderPath == [1, 2])
    }

    @MainActor
    @Test("Team Host drop between folders in one Vault persists without changing credentials")
    func teamHostDropBetweenFolders() throws {
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let sourceID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let targetID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        var source = ConnectionProfile(connectionType: .ssh)
        source.id = sourceID
        source.host = "source.example.invalid"
        source.group = "Source"
        var target = ConnectionProfile(connectionType: .ssh)
        target.id = targetID
        target.host = "target.example.invalid"
        target.group = "Target"
        let initial = try SelectiveRemoteTeamHostDocumentMutation.create(
            profile: source,
            credentials: .init(password: "synthetic-only", gatewayPassword: nil),
            role: .editor, deviceID: deviceID,
            modifiedAt: "2026-09-11T11:00:00.000Z"
        )
        let document = try SelectiveRemoteTeamHostDocumentMutation.create(
            in: initial, profile: target, role: .editor, deviceID: deviceID,
            modifiedAt: "2026-09-11T11:00:00.000Z"
        )
        let credentialBefore = try #require(document.records.first { $0.type == .credential })
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [Self.snapshot(payload: try document.encoded(), role: .editor)])
        let materializedSource = try #require(store.hosts.first { $0.recordID == sourceID })
        let plan = try #require(SelectiveRemoteTeamHostMovePlan.make(
            hosts: store.hosts,
            sourceID: materializedSource.id,
            targetTeamID: materializedSource.teamID,
            toFolder: "Target"
        ))
        #expect(plan.selectedRecordID == sourceID)
        var organized = document
        for update in plan.updates {
            organized = try SelectiveRemoteTeamHostDocumentMutation.organize(
                in: organized, recordID: update.recordID, profile: update.profile,
                role: .editor, deviceID: deviceID,
                modifiedAt: "2026-09-11T11:01:00.000Z"
            )
        }
        #expect(organized.records.first { $0.type == .credential } == credentialBefore)
        store.replaceVault(with: Self.snapshot(payload: try organized.encoded(), role: .editor))
        #expect(store.hosts.first { $0.recordID == sourceID }?.profile.group == "Target")
    }

    @MainActor
    @Test("Team Host drop identifies a folder belonging only to another Vault")
    func teamHostDropRejectsOtherVaultFolder() throws {
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [Self.snapshot(payload: try Self.fixtureData(), role: .editor)])
        let source = try #require(store.hosts.first)
        var otherProfile = source.profile
        otherProfile.id = UUID()
        otherProfile.group = "OtherVaultFolder"
        let other = SelectiveRemoteTeamHost(
            id: otherProfile.id, recordID: UUID(), teamID: source.teamID,
            teamName: source.teamName, role: .editor,
            vaultID: UUID(), vaultName: "Other Vault", revision: 1,
            keyGeneration: 1, modifiedAt: "2026-09-11T11:00:00.000Z",
            address: "other.example.invalid", profile: otherProfile,
            credentials: .empty
        )
        #expect(SelectiveRemoteTeamHostMovePlan.make(
            hosts: store.hosts + [other], sourceID: source.id,
            targetTeamID: source.teamID, toFolder: "OtherVaultFolder"
        ) == nil)
        #expect(SelectiveRemoteTeamHostMovePlan.crossesVault(
            hosts: store.hosts + [other], sourceID: source.id,
            targetTeamID: source.teamID, toFolder: "OtherVaultFolder"
        ))
    }

    @MainActor
    @Test("Team Host credentials are encrypted records, materialize for connection, and delete causally")
    func sharedCredentialLifecycle() throws {
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let recordID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        var profile = ConnectionProfile(connectionType: .rdp)
        profile.id = recordID
        profile.friendlyName = "Shared Desktop"
        profile.host = "desktop.example.invalid"
        profile.username = "operator"
        profile.gatewayHost = "gateway.example.invalid"
        profile.gatewayUsername = "gateway-user"

        let created = try SelectiveRemoteTeamHostDocumentMutation.create(
            profile: profile,
            credentials: .init(password: "host-secret", gatewayPassword: "gateway-secret"),
            role: .owner,
            deviceID: deviceID,
            modifiedAt: "2026-09-10T04:00:00.000Z"
        )
        #expect(created.records.filter { $0.type == .credential }.count == 2)

        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [Self.snapshot(payload: try created.encoded(), role: .owner)])
        let host = try #require(store.hosts.first)
        #expect(host.credentials.password == "host-secret")
        #expect(host.credentials.gatewayPassword == "gateway-secret")

        let updated = try SelectiveRemoteTeamHostDocumentMutation.update(
            in: created,
            recordID: recordID,
            profile: profile,
            credentials: .init(password: "rotated", gatewayPassword: nil),
            role: .admin,
            deviceID: deviceID,
            modifiedAt: "2026-09-10T04:01:00.000Z"
        )
        #expect(updated.records.filter { $0.type == .credential }.count == 1)
        #expect(updated.tombstones.count == 1)

        let deleted = try SelectiveRemoteTeamHostDocumentMutation.delete(
            from: updated,
            recordID: recordID,
            role: .editor,
            deviceID: deviceID,
            deletedAt: "2026-09-10T04:02:00.000Z"
        )
        #expect(deleted.records.isEmpty)
        #expect(deleted.tombstones.count == 3)
    }


    @MainActor
    @Test("store exposes valid Vault contexts and replaces one Vault without touching another")
    func storeReplacesOneVault() throws {
        let first = Self.snapshot(payload: try Self.fixtureData(), role: .editor)
        let second = SelectiveRemoteTeamVaultMaterializedSnapshot(
            teamID: try #require(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")),
            teamName: "Security",
            role: .viewer,
            vaultID: try #require(UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")),
            vaultName: "Audit",
            revision: 1,
            keyGeneration: 1,
            payload: try SelectiveRemoteVaultDocument().encoded()
        )
        let store = SelectiveRemoteTeamHostStore()
        store.replace(with: [first, second])
        #expect(store.vaults.count == 2)
        #expect(store.vaults.first(where: { $0.vaultID == first.vaultID })?.role == .editor)

        let updated = SelectiveRemoteTeamVaultMaterializedSnapshot(
            teamID: first.teamID,
            teamName: first.teamName,
            role: first.role,
            vaultID: first.vaultID,
            vaultName: first.vaultName,
            revision: first.revision + 1,
            keyGeneration: first.keyGeneration,
            payload: try SelectiveRemoteVaultDocument().encoded()
        )
        store.replaceVault(with: updated)
        #expect(store.vaults.count == 2)
        #expect(store.hosts.isEmpty)
        #expect(store.synchronizedVaultCount == 2)
    }

    @MainActor
    @Test("personal settings remain local and apply without mutating the shared Host")
    func personalSettingsOverlay() throws {
        let suiteName = "SelectiveRemoteTests.TeamHostPersonalSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var shared = ConnectionProfile(connectionType: .rdp)
        shared.id = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        shared.friendlyName = "Shared Desktop"
        shared.host = "desktop.example.invalid"
        shared.username = "shared-user"
        shared.clipboardMode = .disabled
        shared.audioMode = .muted

        let host = SelectiveRemoteTeamHost(
            id: try #require(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")),
            recordID: shared.id,
            teamID: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            teamName: "Platform",
            role: .viewer,
            vaultID: try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222")),
            vaultName: "Operations",
            revision: 7,
            keyGeneration: 3,
            modifiedAt: "2026-09-10T08:00:00.000Z",
            address: shared.host,
            profile: shared,
            credentials: .empty
        )

        let store = SelectiveRemoteTeamHostPersonalSettingsStore(
            defaults: defaults,
            storageKey: "settings"
        )
        var personal = store.settings(for: host, endpoint: "https://cloud.example.test")
        personal.preferredUsername = "alice"
        personal.clipboardMode = .bidirectional
        personal.audioMode = .local
        personal.rdpWindowMode = .fixedWindow
        personal.windowWidth = 1
        personal.windowHeight = 99_999
        personal.selectedDisplayIDs = ["display-a", "display-b"]
        personal.primaryDisplayID = "display-b"
        personal.displayLayoutMode = .automatic
        store.save(personal, for: host, endpoint: "https://cloud.example.test")

        let applied = store.appliedProfile(for: host, endpoint: "https://cloud.example.test")
        #expect(applied.username == "alice")
        #expect(applied.clipboardMode == .bidirectional)
        #expect(applied.audioMode == .local)
        #expect(applied.windowWidth == 640)
        #expect(applied.windowHeight == 16_384)
        #expect(applied.selectedDisplayIDs == ["display-a", "display-b"])
        #expect(applied.primaryDisplayID == "display-b")
        #expect(applied.displayLayoutMode == .automatic)
        #expect(host.profile.username == "shared-user")
        #expect(host.profile.clipboardMode == .disabled)
        #expect(host.profile.audioMode == .muted)
        #expect(host.profile.selectedDisplayIDs.isEmpty)

        let restored = SelectiveRemoteTeamHostPersonalSettingsStore(
            defaults: defaults,
            storageKey: "settings"
        )
        #expect(restored.settings(for: host, endpoint: "https://cloud.example.test").preferredUsername == "alice")
        restored.reset(for: host, endpoint: "https://cloud.example.test")
        #expect(!restored.hasSettings(for: host, endpoint: "https://cloud.example.test"))
        #expect(restored.settings(for: host, endpoint: "https://cloud.example.test").preferredUsername == "shared-user")
    }

    private static func snapshot(
        payload: Data,
        role: SelectiveRemoteCloudTeamRole = .viewer
    ) -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        .init(
            teamID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            teamName: "Platform",
            role: role,
            vaultID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            vaultName: "Operations",
            revision: 7,
            keyGeneration: 3,
            payload: payload
        )
    }

    private static func fixtureData() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "team-host-record-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }
}
