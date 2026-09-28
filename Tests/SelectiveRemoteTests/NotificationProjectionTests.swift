import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Notification projection")
@MainActor
struct NotificationProjectionTests {
    private let recipient = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let device = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let team = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let at = Date(timeIntervalSince1970: 1_790_621_600)

    @Test("Device remains active after reading until the source confirms resolution")
    func readIsNotResolved() {
        let store = NotificationProjectionStore(recipient: recipient)
        store.reconcile(group: .devices, observations: [
            .init(kind: .deviceApproval, scopeID: recipient.uuidString, sourceID: device.uuidString)
        ], complete: true, at: at)
        #expect(store.attentionCount == 1)
        #expect(store.unreadCount == 1)
        store.markRead(store.items[0].id, at: at.addingTimeInterval(10))
        #expect(store.attentionCount == 1)
        #expect(store.unreadCount == 0)
        store.reconcile(group: .devices, observations: [], complete: false, at: at.addingTimeInterval(20))
        #expect(store.attentionCount == 1)
        store.reconcile(group: .devices, observations: [], complete: true, at: at.addingTimeInterval(30))
        #expect(store.attentionCount == 0)
    }

    @Test("Repeating sync state deduplicates; retry never resolves, confirmed success does")
    func syncSourceDriven() {
        let store = NotificationProjectionStore(recipient: recipient)
        let signal = NotificationObservation(kind: .syncError, scopeID: recipient.uuidString,
                                             sourceID: "personal")
        store.reconcile(group: .syncPersonal, observations: [signal], complete: true, at: at)
        store.reconcile(group: .syncPersonal, observations: [signal], complete: true,
                        at: at.addingTimeInterval(60))
        #expect(store.items.count == 1)
        store.reconcile(group: .syncPersonal, observations: [], complete: false,
                        at: at.addingTimeInterval(90))
        #expect(store.attentionCount == 1)
        store.reconcile(group: .syncPersonal, observations: [], complete: true,
                        at: at.addingTimeInterval(120))
        #expect(store.attentionCount == 0)
    }

    @Test("Conflict, fail-closed and host identity are distinct active issues")
    func typedIssues() {
        let store = NotificationProjectionStore(recipient: recipient)
        store.reconcile(group: .syncTeam(team), observations: [
            .init(kind: .conflict, scopeID: team.uuidString, sourceID: team.uuidString),
            .init(kind: .failClosed, scopeID: team.uuidString, sourceID: team.uuidString)
        ], complete: true, at: at)
        store.reconcile(group: .hostKey, observations: [
            .init(kind: .hostIdentity, scopeID: recipient.uuidString, sourceID: device.uuidString)
        ], complete: true, at: at)
        #expect(store.attentionCount == 3)
        #expect(Set(store.items.map(\.kind)) == [.conflict, .failClosed, .hostIdentity])
    }

    @Test("Serialized projection excludes arbitrary secret metadata and other recipients")
    func allowlistAndIsolation() throws {
        let store = NotificationProjectionStore(recipient: recipient)
        store.reconcile(group: .hostKey, observations: [
            .init(kind: .hostIdentity, scopeID: recipient.uuidString, sourceID: device.uuidString)
        ], complete: true, at: at)
        let data = try store.serializedData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("fingerprint"))
        #expect(!text.contains("privateKey"))
        let other = NotificationProjectionStore(recipient: team, persisted: data)
        #expect(other.items.isEmpty)
        store.reconcile(group: .devices, observations: [
            .init(kind: .deviceApproval, scopeID: team.uuidString, sourceID: device.uuidString)
        ], complete: true, at: at)
        #expect(store.items.map(\.kind) == [.hostIdentity])
    }

    @Test("Resolved retention does not remove old unresolved security issues")
    func retention() {
        let store = NotificationProjectionStore(recipient: recipient)
        store.reconcile(group: .devices, observations: [
            .init(kind: .deviceApproval, scopeID: recipient.uuidString, sourceID: device.uuidString)
        ], complete: true, at: at)
        store.reconcile(group: .hostKey, observations: [
            .init(kind: .hostIdentity, scopeID: recipient.uuidString, sourceID: device.uuidString)
        ], complete: true, at: at)
        store.reconcile(group: .devices, observations: [], complete: true,
                        at: at.addingTimeInterval(60))
        store.prune(at: at.addingTimeInterval(31 * 86_400))
        #expect(store.items.map(\.kind) == [.hostIdentity])
    }
}
