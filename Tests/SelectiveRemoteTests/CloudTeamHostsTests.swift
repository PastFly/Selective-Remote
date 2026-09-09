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

    private static func snapshot(
        payload: Data
    ) -> SelectiveRemoteTeamVaultMaterializedSnapshot {
        .init(
            teamID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            teamName: "Platform",
            role: .viewer,
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
