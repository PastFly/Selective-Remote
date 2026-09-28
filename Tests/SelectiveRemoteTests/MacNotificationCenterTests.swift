import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Mac Notification Center")
@MainActor
struct MacNotificationCenterTests {
    private let local = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let accountA = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let accountB = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let profile = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let at = Date(timeIntervalSince1970: 1_790_621_600)

    @Test("Account change hides account issues while local host identity remains visible")
    func accountIsolation() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let center = MacNotificationCenter(defaults: defaults, installationID: local)
        center.setAccount(accountA)
        let sync = SyncPresentationStore()
        sync.recordPersonalFailure(.conflict)
        center.applySyncSnapshot(sync.personal, at: at)
        center.observeHostIdentity(profileID: profile, at: at)
        #expect(center.attentionCount == 2)
        center.setAccount(accountB)
        #expect(center.items.map(\.kind) == [.hostIdentity])
        center.setAccount(accountA)
        #expect(center.attentionCount == 2)
    }

    @Test("Invitation stays active when read and resolves only on fresh pending list")
    func invitationRead() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let center = MacNotificationCenter(defaults: defaults, installationID: local)
        center.setAccount(accountA)
        center.reconcileInvitations([(id: accountB, teamID: profile)], at: at)
        let id = center.items[0].id
        center.markRead(id, at: at.addingTimeInterval(1))
        #expect(center.attentionCount == 1)
        #expect(center.unreadCount == 0)
        center.reconcileInvitations([], at: at.addingTimeInterval(2))
        #expect(center.attentionCount == 0)
    }

    @Test("Read state survives local persistence without storing host details")
    func readPersistence() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let center = MacNotificationCenter(defaults: defaults, installationID: local)
        center.observeHostIdentity(profileID: profile, at: at)
        center.markRead(center.items[0].id, at: at.addingTimeInterval(1))
        let reloaded = MacNotificationCenter(defaults: defaults, installationID: local)
        #expect(reloaded.attentionCount == 1)
        #expect(reloaded.unreadCount == 0)
        let stored = defaults.data(forKey: "SelectiveRemote.notifications.local.v1") ?? Data()
        #expect(!String(decoding: stored, as: UTF8.self).contains("fingerprint"))
    }

    @Test("Mac labels use typed kind and current language")
    func localizedLabels() {
        #expect(NotificationKind.deviceApproval.title(english: true) == "Device waiting for approval")
        #expect(NotificationKind.deviceApproval.title(english: false) == "Устройство ожидает одобрения")
        #expect(NotificationKind.hostIdentity.actionTitle(english: true) == "Review Host Key")
        #expect(NotificationKind.failClosed.detail(english: false) == "Командные Vaults остаются безопасно скрытыми.")
    }

    @Test("Cloud device decoder returns only pending IDs and never projects public keys")
    func pendingDeviceIDs() throws {
        let json = """
        {"devices":[
          {"id":"44444444-4444-4444-8444-444444444444","name":"Private Mac","platform":"macOS","app_version":"1","created_at":"2026-09-28","last_seen_at":null,"revoked_at":null,"key_registered":true,"key_approved_at":null,"public_key_algorithm":"P-256","public_key":"SECRET"},
          {"id":"33333333-3333-4333-8333-333333333333","name":"Web","platform":"web","app_version":"1","created_at":"2026-09-28","last_seen_at":null,"revoked_at":null,"key_registered":true,"key_approved_at":"2026-09-28","public_key_algorithm":"P-256","public_key":"SECRET"}
        ]}
        """
        #expect(try SelectiveRemoteCloudAPIClient.pendingDeviceIDs(from: Data(json.utf8)) == [profile])
    }
}
