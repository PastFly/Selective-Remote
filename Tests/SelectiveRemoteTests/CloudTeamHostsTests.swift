import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Team Host materialization")
struct CloudTeamHostsTests {
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
