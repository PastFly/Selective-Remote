import Combine
import Foundation

enum NotificationKind: String, Codable, Hashable, Sendable {
    case deviceApproval, invitation, syncError, conflict, failClosed, hostIdentity, wrapperIssue
}

enum NotificationGroup: Codable, Hashable, Sendable {
    case devices, invitations, syncPersonal, syncTeam(UUID), syncTeamAggregate, hostKey
}

struct NotificationObservation: Sendable {
    let kind: NotificationKind
    let scopeID: String
    let sourceID: String

    init(kind: NotificationKind, scopeID: String, sourceID: String) {
        self.kind = kind
        self.scopeID = scopeID
        self.sourceID = sourceID
    }
}

struct NotificationItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recipient: UUID
    let group: NotificationGroup
    let kind: NotificationKind
    let scopeID: String
    let sourceID: String
    let createdAt: Date
    var lastObservedAt: Date
    var readAt: Date?
    var resolvedAt: Date?
}

@MainActor
final class NotificationProjectionStore: ObservableObject {
    private struct Envelope: Codable {
        let recipient: UUID
        let items: [NotificationItem]
    }

    let recipient: UUID
    @Published private(set) var items: [NotificationItem]

    var attentionCount: Int { items.count { $0.resolvedAt == nil } }
    var unreadCount: Int { items.count { $0.resolvedAt == nil && $0.readAt == nil } }

    init(recipient: UUID, persisted: Data? = nil) {
        self.recipient = recipient
        if let persisted, persisted.count <= 2_000_000,
           let saved = try? JSONDecoder().decode(Envelope.self, from: persisted),
           saved.recipient == recipient, saved.items.count <= 5_000 {
            items = saved.items.filter { Self.valid($0, recipient: recipient) }
        } else {
            items = []
        }
    }

    func reconcile(group: NotificationGroup, observations: [NotificationObservation],
                   complete: Bool, at: Date = .now) {
        var next = items
        var seen: Set<String> = []
        var indices: [String: Int] = [:]
        for index in next.indices where next[index].group == group {
            let item = next[index]
            indices[Self.key(kind: item.kind, scopeID: item.scopeID,
                             sourceID: item.sourceID)] = index
        }
        for observation in observations.prefix(1_000) where Self.valid(
            observation, group: group, recipient: recipient
        ) {
            let key = Self.key(kind: observation.kind, scopeID: observation.scopeID,
                               sourceID: observation.sourceID)
            guard seen.insert(key).inserted else { continue }
            if let index = indices[key] {
                next[index].lastObservedAt = max(next[index].lastObservedAt, at)
                if next[index].resolvedAt != nil {
                    next[index].resolvedAt = nil
                    next[index].readAt = nil
                }
            } else {
                guard next.count < 5_000 else { continue }
                next.append(.init(id: UUID(), recipient: recipient, group: group,
                                  kind: observation.kind, scopeID: observation.scopeID,
                                  sourceID: observation.sourceID, createdAt: at,
                                  lastObservedAt: at, readAt: nil, resolvedAt: nil))
                indices[key] = next.count - 1
            }
        }
        if complete {
            for index in next.indices where next[index].group == group &&
                next[index].resolvedAt == nil &&
                !seen.contains(Self.key(kind: next[index].kind, scopeID: next[index].scopeID,
                                        sourceID: next[index].sourceID)) {
                next[index].resolvedAt = at
            }
        }
        items = Self.pruned(next, at: at)
    }

    func markRead(_ id: UUID, at: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.resolvedAt == nil && $0.readAt == nil })
        else { return }
        items[index].readAt = at
    }

    func applySyncSnapshot(_ snapshot: SyncScopeSnapshot, at: Date = .now) {
        let group: NotificationGroup = snapshot.scope == .personal ? .syncPersonal : .syncTeamAggregate
        let sourceID = snapshot.scope == .personal ? "personal" : "team"
        if snapshot.lifecycle == .synced && snapshot.materialization == .confirmed {
            reconcile(group: group, observations: [], complete: true, at: at)
            return
        }
        let kind: NotificationKind?
        switch snapshot.lifecycle {
        case .conflict: kind = .conflict
        case .error: kind = .syncError
        case .security:
            if snapshot.scope == .team && snapshot.issue == .keyOrWrapperMissing {
                kind = .wrapperIssue
            } else if snapshot.scope == .team &&
                        (snapshot.issue == .rotationRequired ||
                         snapshot.materialization == .hiddenFailClosed) {
                kind = .failClosed
            } else {
                kind = .syncError
            }
        default: kind = nil
        }
        guard let kind else { return }
        reconcile(group: group, observations: [
            .init(kind: kind, scopeID: recipient.uuidString, sourceID: sourceID)
        ], complete: true, at: at)
    }

    func observeHostIdentity(profileID: UUID, at: Date = .now) {
        reconcile(group: .hostKey, observations: [
            .init(kind: .hostIdentity, scopeID: recipient.uuidString,
                  sourceID: profileID.uuidString)
        ], complete: false, at: at)
    }

    func resolveHostIdentity(profileID: UUID, at: Date = .now) {
        guard let index = items.firstIndex(where: {
            $0.group == .hostKey && $0.sourceID.lowercased() == profileID.uuidString.lowercased()
                && $0.resolvedAt == nil
        }) else { return }
        items[index].resolvedAt = at
        prune(at: at)
    }

    func prune(at: Date = .now) { items = Self.pruned(items, at: at) }

    func serializedData() throws -> Data {
        try JSONEncoder().encode(Envelope(recipient: recipient, items: items))
    }

    private static func valid(_ observation: NotificationObservation,
                              group: NotificationGroup, recipient: UUID) -> Bool {
        guard UUID(uuidString: observation.scopeID) != nil,
              UUID(uuidString: observation.sourceID) != nil ||
                ["personal", "team"].contains(observation.sourceID)
        else { return false }
        switch group {
        case .devices:
            return observation.kind == .deviceApproval &&
                observation.scopeID.lowercased() == recipient.uuidString.lowercased()
        case .invitations: return observation.kind == .invitation
        case .syncPersonal:
            return observation.scopeID.lowercased() == recipient.uuidString.lowercased() &&
                observation.sourceID == "personal" &&
                [.syncError, .conflict].contains(observation.kind)
        case .syncTeam(let team):
            return observation.scopeID.lowercased() == team.uuidString.lowercased() &&
                [.syncError, .conflict, .failClosed, .wrapperIssue].contains(observation.kind)
        case .syncTeamAggregate:
            return observation.scopeID.lowercased() == recipient.uuidString.lowercased() &&
                observation.sourceID == "team" &&
                [.syncError, .conflict, .failClosed, .wrapperIssue].contains(observation.kind)
        case .hostKey:
            return observation.kind == .hostIdentity &&
                observation.scopeID.lowercased() == recipient.uuidString.lowercased()
        }
    }

    private static func valid(_ item: NotificationItem, recipient: UUID) -> Bool {
        item.recipient == recipient && valid(.init(kind: item.kind, scopeID: item.scopeID,
                                                   sourceID: item.sourceID), group: item.group,
                                             recipient: recipient)
    }

    private static func key(kind: NotificationKind, scopeID: String, sourceID: String) -> String {
        "\(kind.rawValue):\(scopeID.lowercased()):\(sourceID.lowercased())"
    }

    private static func pruned(_ values: [NotificationItem], at: Date) -> [NotificationItem] {
        let active = values.filter { $0.resolvedAt == nil }
        let resolved = values.filter {
            guard let date = $0.resolvedAt else { return false }
            return date >= at.addingTimeInterval(-30 * 86_400)
        }.sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
        return active + resolved.prefix(100)
    }
}
