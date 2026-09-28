import Foundation
import Testing
@testable import SelectiveRemote

@Suite("Sync presentation")
@MainActor
struct SyncPresentationTests {
    @Test("Aggregate preserves the most urgent scope")
    func aggregatePriority() {
        let store = SyncPresentationStore()
        store.recordPersonalSuccess(revision: 3)
        store.recordTeamReport(.init(scannedVaults: 2, failures: 1))
        #expect(store.aggregate == .error)
        store.recordTeamReport(.init(scannedVaults: 2, conflicts: 1))
        #expect(store.aggregate == .conflict)
        store.recordTeamReport(.init(scannedVaults: 2, pendingWrappers: 1))
        #expect(store.aggregate == .security)
    }

    @Test("A report with no session cannot claim synchronization")
    func zeroReportUnknown() {
        let store = SyncPresentationStore()
        store.recordTeamReport(.init())
        #expect(store.team.lifecycle == .unknown)
        #expect(store.team.appliedRevision == nil)
        #expect(store.team.pendingLocalChanges == nil)
        #expect(store.team.materialization == .unknown)
    }

    @Test("Account switch discards live state and old global history")
    func accountSwitchInvalidates() {
        let store = SyncPresentationStore()
        store.setAccount(endpoint: "https://one.example", deviceID: "one")
        store.recordPersonalSuccess(revision: 7)
        store.setAccount(endpoint: "https://two.example", deviceID: "two")
        #expect(store.personal.lifecycle == .unknown)
        #expect(store.personal.appliedRevision == nil)
        #expect(store.personal.lastConfirmedAt == nil)
    }

    @Test("Retry routes to the exact existing scope notification once")
    func scopedRetry() {
        let store = SyncPresentationStore()
        let personal = SyncNotificationCounter()
        let team = SyncNotificationCounter()
        let p = NotificationCenter.default.addObserver(forName: .selectiveRemotePersonalVaultSyncNow, object: nil, queue: nil) { _ in personal.increment() }
        let t = NotificationCenter.default.addObserver(forName: .selectiveRemoteTeamVaultSyncNow, object: nil, queue: nil) { _ in team.increment() }
        defer { NotificationCenter.default.removeObserver(p); NotificationCenter.default.removeObserver(t) }
        store.retry(.personal)
        store.retry(.personal)
        #expect(personal.value == 1)
        #expect(team.value == 0)
        store.retry(.team)
        #expect(team.value == 1)
    }

    @Test("Complete Team cycle confirms aggregate without inventing a revision")
    func materializationEvidence() {
        let store = SyncPresentationStore()
        store.recordTeamReport(.init(scannedVaults: 1, synchronizedVaults: 1))
        #expect(store.team.lifecycle == .synced)
        #expect(store.team.materialization == .confirmed)
        #expect(store.team.lastConfirmedAt != nil)
        #expect(store.team.appliedRevision == nil)
        #expect(store.team.checkedVaultCount == 1)
        store.recordTeamReport(.init(scannedVaults: 1, pendingWrappers: 1))
        #expect(store.team.lifecycle == .security)
        #expect(store.team.materialization == .hiddenFailClosed)
    }

    @Test("Incomplete Team cycle stays unknown")
    func incompleteTeamCycle() {
        let store = SyncPresentationStore()
        store.recordTeamReport(.init(scannedVaults: 2, synchronizedVaults: 1))
        #expect(store.team.lifecycle == .unknown)
        #expect(store.team.materialization == .unknown)
        #expect(store.team.pendingLocalChanges == nil)
    }

    @Test("Lifecycle has distinct Russian and English labels")
    func localizedLabels() {
        #expect(SyncLifecycle.security.title(english: true) == "Action required")
        #expect(SyncLifecycle.security.title(english: false) == "Требуется действие")
        #expect(SyncLifecycle.unknown.title(english: true) == "Status unknown")
        #expect(SyncLifecycle.unknown.title(english: false) == "Состояние неизвестно")
    }
}

private final class SyncNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
