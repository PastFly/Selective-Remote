import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Notification sources")
@MainActor
struct NotificationSourceTests {
    let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let host = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let at = Date(timeIntervalSince1970: 1_790_621_600)

    @Test("Typed Personal sync failure appears, retry does not resolve, success does")
    func personalSync() {
        let presentation = SyncPresentationStore()
        let notifications = NotificationProjectionStore(recipient: account)
        presentation.recordPersonalFailure(.unknownFailure)
        notifications.applySyncSnapshot(presentation.personal, at: at)
        #expect(notifications.items.map(\.kind) == [.syncError])
        presentation.begin(.personal)
        notifications.applySyncSnapshot(presentation.personal, at: at.addingTimeInterval(1))
        #expect(notifications.attentionCount == 1)
        presentation.recordPersonalSuccess(revision: 3)
        notifications.applySyncSnapshot(presentation.personal, at: at.addingTimeInterval(2))
        #expect(notifications.attentionCount == 0)
    }

    @Test("Team fail-closed message uses typed issue and never saves raw error text")
    func teamFailClosed() throws {
        let presentation = SyncPresentationStore()
        let notifications = NotificationProjectionStore(recipient: account)
        presentation.recordTeamReport(.init(scannedVaults: 2, pendingWrappers: 1))
        notifications.applySyncSnapshot(presentation.team, at: at)
        #expect(notifications.items.map(\.kind) == [.wrapperIssue])
        #expect(notifications.attentionCount == 1)
        #expect(!String(decoding: try notifications.serializedData(), as: UTF8.self).contains("rawError"))
        presentation.recordTeamReport(.init(scannedVaults: 2, synchronizedVaults: 2))
        notifications.applySyncSnapshot(presentation.team, at: at.addingTimeInterval(1))
        #expect(notifications.attentionCount == 0)
    }

    @Test("Local host identity is independent of account and requires confirmed recovery")
    func hostKeyLocal() {
        let local = NotificationProjectionStore(recipient: host)
        local.observeHostIdentity(profileID: host, at: at)
        #expect(local.attentionCount == 1)
        local.markRead(local.items[0].id, at: at.addingTimeInterval(1))
        #expect(local.attentionCount == 1)
        local.resolveHostIdentity(profileID: host, at: at.addingTimeInterval(2))
        #expect(local.attentionCount == 0)
    }
}
