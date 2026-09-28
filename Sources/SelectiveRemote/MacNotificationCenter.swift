import Combine
import CryptoKit
import Foundation

@MainActor
final class MacNotificationCenter: ObservableObject {
    static let shared = MacNotificationCenter()

    @Published private(set) var items: [NotificationItem] = []
    private let defaults: UserDefaults
    private let local: NotificationProjectionStore
    private var account: NotificationProjectionStore?
    private var accountID: UUID?
    private var accountEndpoint: String?
    private(set) var sessionRevision: UInt64 = 0

    var currentAccountID: UUID? { accountID }

    var attentionCount: Int { items.count { $0.resolvedAt == nil } }
    var unreadCount: Int { items.count { $0.resolvedAt == nil && $0.readAt == nil } }

    init(defaults: UserDefaults = .standard, installationID: UUID? = nil) {
        self.defaults = defaults
        let localID: UUID
        if let installationID {
            localID = installationID
        } else if let existing = defaults.string(forKey: "SelectiveRemote.notifications.installation.v1"),
                  let parsed = UUID(uuidString: existing) {
            localID = parsed
        } else {
            localID = UUID()
            defaults.set(localID.uuidString, forKey: "SelectiveRemote.notifications.installation.v1")
        }
        local = NotificationProjectionStore(recipient: localID,
            persisted: defaults.data(forKey: "SelectiveRemote.notifications.local.v1"))
        refreshItems()
    }

    func setAccount(_ id: UUID?) {
        let configured = defaults.string(forKey: "SelectiveRemote.cloud.endpoint.v1")
            ?? SelectiveRemoteCloudEndpoint.production
        let endpoint = id.flatMap { _ in
            try? SelectiveRemoteCloudEndpoint.normalized(configured).absoluteString
        }
        guard id != accountID || endpoint != accountEndpoint else { return }
        sessionRevision &+= 1
        accountID = endpoint == nil ? nil : id
        accountEndpoint = endpoint
        account = accountID.flatMap { id in
            endpoint.map { endpoint in
                NotificationProjectionStore(recipient: id,
                    persisted: defaults.data(forKey: Self.accountStorageKey(id, endpoint: endpoint)))
            }
        }
        refreshItems()
    }

    func applySyncSnapshot(_ snapshot: SyncScopeSnapshot, at: Date = .now) {
        guard let account else { return }
        account.applySyncSnapshot(snapshot, at: at)
        persistAccount()
        refreshItems()
    }

    func reconcileInvitations(_ pending: [(id: UUID, teamID: UUID)], at: Date = .now) {
        guard let account else { return }
        account.reconcile(group: .invitations, observations: pending.prefix(1_000).map {
            .init(kind: .invitation, scopeID: $0.teamID.uuidString, sourceID: $0.id.uuidString)
        }, complete: true, at: at)
        persistAccount()
        refreshItems()
    }

    func reconcileDevices(_ pending: [UUID], at: Date = .now) {
        guard let account else { return }
        account.reconcile(group: .devices, observations: pending.prefix(1_000).map {
            .init(kind: .deviceApproval, scopeID: account.recipient.uuidString,
                  sourceID: $0.uuidString)
        }, complete: true, at: at)
        persistAccount()
        refreshItems()
    }

    func observeHostIdentity(profileID: UUID, at: Date = .now) {
        local.observeHostIdentity(profileID: profileID, at: at)
        persistLocal()
        refreshItems()
    }

    func resolveHostIdentity(profileID: UUID, at: Date = .now) {
        local.resolveHostIdentity(profileID: profileID, at: at)
        persistLocal()
        refreshItems()
    }

    func markRead(_ id: UUID, at: Date = .now) {
        if local.items.contains(where: { $0.id == id }) {
            local.markRead(id, at: at)
            persistLocal()
        } else if let account, account.items.contains(where: { $0.id == id }) {
            account.markRead(id, at: at)
            persistAccount()
        }
        refreshItems()
    }

    private func refreshItems() {
        items = (local.items + (account?.items ?? [])).sorted {
            if ($0.resolvedAt == nil) != ($1.resolvedAt == nil) { return $0.resolvedAt == nil }
            return $0.lastObservedAt > $1.lastObservedAt
        }
    }

    private func persistLocal() {
        guard let data = try? local.serializedData() else { return }
        defaults.set(data, forKey: "SelectiveRemote.notifications.local.v1")
    }

    private func persistAccount() {
        guard let accountID, let accountEndpoint,
              let data = try? account?.serializedData() else { return }
        defaults.set(data, forKey: Self.accountStorageKey(accountID, endpoint: accountEndpoint))
    }

    private static func accountStorageKey(_ id: UUID, endpoint: String) -> String {
        let digest = SHA256.hash(data: Data(endpoint.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "SelectiveRemote.notifications.account.v1.\(digest).\(id.uuidString)"
    }
}
